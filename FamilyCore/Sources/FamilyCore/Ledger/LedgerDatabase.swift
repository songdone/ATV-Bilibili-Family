import Foundation
import CSQLite
import Darwin

/// Small synchronous SQLite wrapper. Owned exclusively by UsageLedger's actor.
final class LedgerDatabase {
    private var handle: OpaquePointer?
    private var lockDescriptor: Int32 = -1
    init(path: String) throws {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        // Resolve aliases before choosing a sidecar lock; locking the SQLite
        // file itself conflicts with the platform's own SQLite/WAL locks.
        if FileManager.default.fileExists(atPath: canonicalPath) {
            let attributes = try FileManager.default.attributesOfItem(atPath: canonicalPath)
            guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw LedgerError.invalidInput("hard-linked databases are unsupported")
            }
        }
        lockDescriptor = Darwin.open(canonicalPath + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw LedgerError.database("cannot open ledger lock") }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockDescriptor); lockDescriptor = -1
            throw LedgerError.ledgerAlreadyOpen
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(canonicalPath, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            close()
            throw LedgerError.database(message)
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            guard try scalar("PRAGMA quick_check") == "ok" else { throw LedgerError.corruptDatabase }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        if let handle { sqlite3_close_v2(handle) }; handle = nil
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1
        }
    }
    var totalChanges: Int32 { handle.map { sqlite3_total_changes($0) } ?? 0 }
    func execute(_ sql: String, _ bindings: [String] = []) throws {
        try statement(sql, bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
        }
    }
    func scalar(_ sql: String, _ bindings: [String] = []) throws -> String? {
        try statement(sql, bindings) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }
    func rows(_ sql: String) throws -> [[String?]] {
        try statement(sql, []) { statement in
            var rows: [[String?]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw failure() }
                rows.append((0..<sqlite3_column_count(statement)).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) }
                })
            }
        }
    }
    private func statement<T>(_ sql: String, _ bindings: [String],
                              body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw LedgerError.closed }
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK,
              let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(pointer, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw failure()
            }
        }
        return try body(pointer)
    }
    private func failure() -> LedgerError {
        guard let handle else { return .closed }
        let code = sqlite3_errcode(handle)
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .corruptDatabase }
        return .database(String(cString: sqlite3_errmsg(handle)))
    }
}
