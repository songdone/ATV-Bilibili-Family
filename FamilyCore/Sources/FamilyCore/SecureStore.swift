import Foundation
import Security

/// Synchronous by design: ParentalAuth never suspends between reading and writing
/// security state. Implementations must be thread-safe and treat a successful
/// write as durable. Use one live ParentalAuth per store namespace.
public protocol SecureStore: Sendable {
    func read(key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
}

/// An explicit, parent-authorized reset may remove a stale checkpoint when the
/// live database no longer exists (for example after reinstalling the app).
/// Test and read-only stores do not have to support deletion.
public protocol ResettableSecureStore: SecureStore {
    func delete(key: String) throws
}

public enum SecureStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case unexpectedItem
}

/// Device-local, non-synchronizing Keychain storage. No biometric/access-control
/// prompts are used, so this also works on tvOS. Items are accessible only while
/// the device is unlocked and cannot migrate to a different device via backup.
public final class KeychainSecureStore: ResettableSecureStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "ATV-Bilibili-Family.ParentalAuth.v1") {
        self.service = service
    }

    public func read(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw SecureStoreError.keychain(result) }
        guard let data = item as? Data else { throw SecureStoreError.unexpectedItem }
        return data
    }

    public func write(_ data: Data, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let query = baseQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecureStoreError.keychain(update) }
        var item = query
        for (key, value) in attributes { item[key] = value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecureStoreError.keychain(added) }
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let result = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw SecureStoreError.keychain(result)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
    }
}
