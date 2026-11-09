import Darwin
import FamilyCore
import Foundation

/// Same-device encrypted snapshots. Export requires a closed SQLite connection.
/// Restore validates a separate candidate, then retains the previous directory
/// intact and installs the candidate; no live DB/WAL/SHM files are deleted.
enum FamilyBackupManager {
    private static let prefix = "FamilyBackup-"

    private final class CandidateCheckpoints: LedgerCheckpointStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: LedgerCheckpoint
        init(_ value: LedgerCheckpoint) { self.value = value }
        func load() throws -> LedgerCheckpoint? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws {
            lock.lock(); defer { lock.unlock() }
            guard value == expected else { throw LedgerError.checkpointMismatch }
            value = new
        }
    }

    static func export(databaseDirectory: URL, checkpoint: LedgerCheckpoint,
                       store: any SecureStore) throws -> URL {
        let writerLock = try lockClosedDatabase(at: databaseDirectory)
        defer { unlockDatabase(writerLock) }
        let bytes = try Data(contentsOf: databaseDirectory.appendingPathComponent("usage.sqlite"))
        let sealed = try LedgerBackupArchive(store: store).seal(
            LedgerBackupSnapshot(checkpoint: checkpoint, database: bytes))
        let directory = try backupDirectory(for: databaseDirectory)
        let target = directory.appendingPathComponent(prefix + UUID().uuidString + ".fambak")
        // Foundation forbids combining .atomic and .withoutOverwriting. Publish
        // a completed same-directory staging file instead, without replacing data.
        let staging = directory.appendingPathComponent(".FamilyBackup-" + UUID().uuidString + ".pending")
        try sealed.write(to: staging, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }

    static func restore(databaseDirectory: URL, store: any SecureStore,
                        checkpoints: any LedgerCheckpointStore,
                        authorizer: any LedgerAdminAuthorizing,
                        credential: Data) async throws {
        try authorizer.authorize(operation: .reanchorClock, credential: credential)
        // Keep the original lock descriptor alive even when its directory is moved.
        // A nonempty WAL alone cannot detect a live, already-checkpointed writer.
        let originalLock = try lockClosedDatabase(at: databaseDirectory, allowMissingDirectory: true)
        defer { unlockDatabase(originalLock) }
        let trusted = try checkpoints.load()
        guard let trusted else { throw LedgerError.checkpointMismatch }
        let directory = try backupDirectory(for: databaseDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "fambak" && $0.lastPathComponent.hasPrefix(prefix) }
        let sorted = try files.map { url in
            (url, try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        guard let newest = sorted.first?.0 else { throw LedgerError.missingDatabase }
        let backup = try LedgerBackupArchive(store: store).open(Data(contentsOf: newest))
        guard backup.checkpoint.databaseID == trusted.databaseID else { throw LedgerError.checkpointMismatch }
        let parent = databaseDirectory.deletingLastPathComponent()
        let candidateDirectory = parent.appendingPathComponent("FamilyRestoreCandidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: false)
        let candidateURL = candidateDirectory.appendingPathComponent("usage.sqlite")
        try backup.database.write(to: candidateURL, options: .withoutOverwriting)
        let candidateStore = CandidateCheckpoints(backup.checkpoint)
        let candidate = try UsageLedger(databaseURL: candidateURL, checkpointStore: candidateStore,
                                        adminAuthorizer: authorizer)
        let recovered: LedgerCheckpoint
        do {
            recovered = try await candidate.prepareRestoredBackup(minimumRevision: trusted.revision,
                                                                   credential: credential)
            await candidate.close()
            try requireClosedDatabase(at: candidateDirectory)
        } catch {
            await candidate.close()
            throw error
        }
        // Lock the closed candidate too: its sidecar becomes the installed sidecar
        // after the swap and must exclude reopen until the secure CAS completes.
        let candidateLock = try lockClosedDatabase(at: candidateDirectory)
        defer { unlockDatabase(candidateLock) }
        // All expensive work was on a separate candidate. Revalidate just before
        // touching the installed directory. Existing data remains in quarantine.
        try authorizer.authorize(operation: .reanchorClock, credential: credential)
        guard try checkpoints.load() == trusted else { throw LedgerError.checkpointMismatch }
        let previous = parent.appendingPathComponent("FamilyBeforeRestore-" + UUID().uuidString)
        let hadPrevious = FileManager.default.fileExists(atPath: databaseDirectory.path)
        if hadPrevious { try FileManager.default.moveItem(at: databaseDirectory, to: previous) }
        do {
            try FileManager.default.moveItem(at: candidateDirectory, to: databaseDirectory)
        } catch {
            if hadPrevious { try FileManager.default.moveItem(at: previous, to: databaseDirectory) }
            throw error
        }
        // SQLite and Keychain cannot share a transaction. A failure here leaves a
        // checkpoint mismatch and playback locked, with the old data still intact.
        try checkpoints.compareAndSwap(expected: trusted, new: recovered)
    }

    /// Use the exact sidecar convention used by LedgerDatabase, never flock the
    /// SQLite inode (which interferes with SQLite's own locking on Apple systems).
    private static func lockClosedDatabase(at directory: URL,
                                          allowMissingDirectory: Bool = false) throws -> Int32 {
        if !FileManager.default.fileExists(atPath: directory.path), allowMissingDirectory { return -1 }
        let database = directory.appendingPathComponent("usage.sqlite")
            .standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(database.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW,
                                     S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LedgerError.database("cannot open backup ledger lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw LedgerError.ledgerAlreadyOpen
        }
        do { try requireClosedDatabase(at: directory) }
        catch { unlockDatabase(descriptor); throw error }
        return descriptor
    }

    private static func unlockDatabase(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func requireClosedDatabase(at directory: URL) throws {
        let wal = directory.appendingPathComponent("usage.sqlite-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: wal.path)
            guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
                throw LedgerError.database("backup requires a checkpointed, closed database")
            }
        }
    }

    /// Newest complete backup, if any. Export/restore use the same selection
    /// rule; the parent UI uses this only for status text, never to open data.
    static func latestBackupDate(databaseDirectory: URL) -> Date? {
        guard let directory = try? backupDirectory(for: databaseDirectory),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.pathExtension == "fambak" && $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    private static func backupDirectory(for databaseDirectory: URL) throws -> URL {
        // A separate directory reduces accidental deletion with the live ledger;
        // tvOS may still purge it, so this is not an off-device disaster backup.
        let result = databaseDirectory.deletingLastPathComponent()
            .appendingPathComponent(databaseDirectory.lastPathComponent + "-Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}
