import FamilyCore
import Foundation

/// Synchronous reads for player/socket callbacks, backed by the device Keychain.
/// Before initialization, or after a security-store failure, remain restrictive.
enum FamilyModeState {
    static let legacyDefaultsKey = "family.childModeActive.v1"
    private static let lock = NSLock()
    private static var policy: FamilyModePolicy?

    static var childActive: Bool {
        lock.lock()
        let current = policy
        lock.unlock()
        return current?.isChildActive() ?? true
    }

    static func configure(_ value: FamilyModePolicy?) {
        lock.lock()
        policy = value
        lock.unlock()
    }
}
