import Foundation

/// Keep this store outside the purgeable tvOS database directory. One live ledger
/// owns the database; its file lock supplies cross-instance writer exclusion.
public final class SecureLedgerCheckpointStore: LedgerCheckpointStore, @unchecked Sendable {
    private let store: any SecureStore
    private let key: String
    // All adapters in the application share the CAS lock, including adapters
    // constructed with different SecureStore wrappers for the same namespace.
    // Cross-process writers to distinct copies of a database are unsupported.
    private static let lock = NSLock()

    public init(store: any SecureStore, key: String = "family-ledger-checkpoint-v1") {
        self.store = store
        self.key = key
    }

    public func load() throws -> LedgerCheckpoint? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readCheckpoint()
    }

    public func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard try readCheckpoint() == expected else {
            throw LedgerError.checkpointMismatch
        }
        let data = try JSONEncoder().encode(new)
        try store.write(data, key: key)
        guard try readCheckpoint() == new else {
            throw LedgerError.securityStoreUnavailable
        }
    }

    /// Removes only the checkpoint. Callers must have already verified that the
    /// live database is absent and that a parent explicitly authorized a reset.
    public func clear() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let resettable = store as? any ResettableSecureStore else {
            throw LedgerError.securityStoreUnavailable
        }
        try resettable.delete(key: key)
    }

    private func readCheckpoint() throws -> LedgerCheckpoint? {
        guard let data = try store.read(key: key) else { return nil }
        do {
            return try JSONDecoder().decode(LedgerCheckpoint.self, from: data)
        } catch {
            throw LedgerError.checkpointMismatch
        }
    }
}
