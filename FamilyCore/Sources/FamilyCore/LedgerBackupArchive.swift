import CryptoKit
import Foundation
import Security

public struct LedgerBackupSnapshot: Codable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let checkpoint: LedgerCheckpoint
    public let database: Data
    public let databaseSHA256: String

    public init(checkpoint: LedgerCheckpoint, database: Data) {
        formatVersion = 1
        createdAt = Date()
        self.checkpoint = checkpoint
        self.database = database
        databaseSHA256 = SHA256.hash(data: database).map { String(format: "%02x", $0) }.joined()
    }
}

/// Encrypts a checkpointed, closed SQLite database, never a live DB/WAL/SHM trio.
/// Key loss, corruption and unsupported formats are errors; restore never creates
/// a replacement key or changes the active database.
public final class LedgerBackupArchive: @unchecked Sendable {
    private let store: any SecureStore
    private static let lock = NSLock()
    private static let maximumBytes = 64 * 1024 * 1024
    private let keyName = "family-backup-key.v2"

    public init(store: any SecureStore) { self.store = store }

    public func seal(_ snapshot: LedgerBackupSnapshot) throws -> Data {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try validate(snapshot)
        let key = try encryptionKey(create: true)
        let payload = try JSONEncoder().encode(snapshot)
        guard let sealed = try AES.GCM.seal(payload, using: key).combined else {
            throw LedgerError.securityStoreUnavailable
        }
        return sealed
    }

    public func open(_ sealed: Data) throws -> LedgerBackupSnapshot {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard sealed.count <= Self.maximumBytes * 2 else { throw LedgerError.corruptDatabase }
        let key = try encryptionKey(create: false)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let payload = try AES.GCM.open(box, using: key)
            let snapshot = try JSONDecoder().decode(LedgerBackupSnapshot.self, from: payload)
            try validate(snapshot)
            return snapshot
        } catch {
            throw LedgerError.corruptDatabase
        }
    }

    private func validate(_ snapshot: LedgerBackupSnapshot) throws {
        guard snapshot.formatVersion == 1, snapshot.database.count >= 100,
              snapshot.database.count <= Self.maximumBytes,
              snapshot.database.starts(with: Data("SQLite format 3\0".utf8)),
              snapshot.checkpoint.revision >= 0,
              snapshot.databaseSHA256 == SHA256.hash(data: snapshot.database)
                .map({ String(format: "%02x", $0) }).joined() else {
            throw LedgerError.corruptDatabase
        }
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let bytes = try store.read(key: keyName) {
            guard bytes.count == 32 else { throw LedgerError.securityStoreUnavailable }
            return SymmetricKey(data: bytes)
        }
        guard create else { throw LedgerError.securityStoreUnavailable }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw LedgerError.securityStoreUnavailable }
        try store.write(bytes, key: keyName)
        guard try store.read(key: keyName) == bytes else { throw LedgerError.securityStoreUnavailable }
        return SymmetricKey(data: bytes)
    }
}
