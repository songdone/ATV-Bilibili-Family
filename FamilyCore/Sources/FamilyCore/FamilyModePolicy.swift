import Foundation

/// Device-local mode state. Clearing preferences cannot disable an established
/// child policy. Missing/corrupt security state is restrictive, never adult mode.
public final class FamilyModePolicy: @unchecked Sendable {
    private struct Record: Codable { let version: Int; let childActive: Bool }
    private let store: any SecureStore
    private let authorizer: any LedgerAdminAuthorizing
    private let lock = NSLock()
    private let markerKey = "family-mode.initialized.v1"
    private let recordKey = "family-mode.record.v1"
    private let marker = Data("family-mode-v1".utf8)
    private var failed = false

    public init(store: any SecureStore, authorizer: any LedgerAdminAuthorizing,
                legacyChildActive: Bool = false) throws {
        self.store = store
        self.authorizer = authorizer
        let previousMarker = try store.read(key: markerKey)
        let previousRecord = try store.read(key: recordKey)
        if previousMarker == nil && previousRecord == nil {
            try store.write(marker, key: markerKey)
            let data = try JSONEncoder().encode(Record(version: 1, childActive: legacyChildActive))
            try store.write(data, key: recordKey)
        }
        _ = try read()
    }

    public func isChildActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return true }
        do { return try read().childActive }
        catch { failed = true; return true }
    }

    /// Only a fresh temporary-override capability may change either mode.
    /// Callers suspend all players before invoking this method.
    public func setChildActive(_ active: Bool, credential: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw LedgerError.securityStoreUnavailable }
        try authorizer.authorize(operation: .temporaryOverride, credential: credential)
        do {
            _ = try read()
            let data = try JSONEncoder().encode(Record(version: 1, childActive: active))
            try store.write(data, key: recordKey)
            guard try read().childActive == active else { throw LedgerError.securityStoreUnavailable }
        } catch {
            failed = true
            throw error
        }
    }

    private func read() throws -> Record {
        guard try store.read(key: markerKey) == marker,
              let data = try store.read(key: recordKey),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else {
            throw LedgerError.securityStoreUnavailable
        }
        return record
    }
}
