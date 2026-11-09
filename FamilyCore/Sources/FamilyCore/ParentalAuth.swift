import CommonCrypto
import Darwin
import Foundation
import Security

public enum ParentalAuthContext: String, Codable, CaseIterable, Sendable {
    case switchProfile
    case manageProfiles
    case configureRules
    case manageSession
    case support
    case recovery
    case temporaryOverride
}

/// A short-lived bearer capability, not a global authenticated flag. No public
/// initializer exists. Treat credential as a secret: do not log or persist it.
/// Only the issuing ParentalAuth (and its ledgerAuthorizer) can validate it.
public struct ParentalAuthorization: Sendable {
    public let context: ParentalAuthContext
    public let credential: Data

    fileprivate init(context: ParentalAuthContext, credential: Data) {
        self.context = context
        self.credential = credential
    }
}

/// A long-lived in-memory parent session. Held only by the parental center while
/// it is foreground; never persisted, logged or exported. Every ordinary action
/// exchanges it for a fresh 60-second operation capability of the same context.
public struct ParentalSession: Sendable {
    public let credential: Data
    public let expiresAtMonotonicSeconds: TimeInterval

    /// Internal placeholder so UI pages can render before a real session exists;
    /// it validates nothing and every registry lookup rejects it.
    public static let placeholder = ParentalSession(credential: Data(), expiresAtMonotonicSeconds: 0)

    fileprivate init(credential: Data, expiresAtMonotonicSeconds: TimeInterval) {
        self.credential = credential
        self.expiresAtMonotonicSeconds = expiresAtMonotonicSeconds
    }
}

public enum ParentalAuthStatus: Equatable, Sendable {
    case notConfigured
    case configured(failedAttempts: Int)
    case locked(remaining: TimeInterval)
}

public enum ParentalAuthError: Error, Equatable, Sendable {
    case invalidPINFormat
    case alreadyConfigured
    case notConfigured
    case incorrectPIN(attemptsRemaining: Int)
    case locked(retryAfter: TimeInterval)
    case storageUnavailable
    case corruptedState
    case cryptographicFailure
    case invalidClock
    case invalidAuthorization
    case wrongContext
    case authorizationExpired
}

/// Values must be monotonic seconds, not Date/timeIntervalSince1970. Test clocks
/// and stores must also be thread-safe because the ledger adapter is synchronous.
public protocol ParentalAuthClock: Sendable {
    func monotonicTime() -> TimeInterval
}

public struct SystemParentalAuthClock: ParentalAuthClock {
    public init() {}
    public func monotonicTime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return .nan }
        // Continuous uptime includes device sleep, so a 60-second capability
        // cannot retain its remaining lifetime across a long suspend/resume.
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

/// Serial PIN authentication with durable failure/lockout state.
///
/// Security policy: six ASCII digits, 32 random salt bytes, PBKDF2-HMAC-SHA256
/// (600,000 rounds, 32-byte output), five failures, five-minute lockout, and
/// context-scoped 60-second capabilities. There is deliberately no PIN-removal
/// or unauthenticated reset API.
///
/// A persisted lock has NO wall-clock deadline. This actor must observe a full
/// monotonic lock interval before clearing it durably. Recreating the actor or
/// process conservatively starts the full interval again on its first operation;
/// wall-clock changes cannot shorten it. A backwards monotonic test clock also
/// restarts observation. Use exactly one live actor per SecureStore namespace;
/// independent actors/processes are not a supported concurrent-writer model.
///
/// Setup writes an irreversible marker FIRST. Interrupted setup, missing
/// credentials after setup, malformed data, and I/O errors fail closed, never
/// appearing as an unset PIN. An I/O/corruption failure poisons this instance and
/// revokes its capabilities; recreate it only after resolving the store problem.
/// Loss of both Keychain items (e.g. device erase) cannot be detected locally.
public actor ParentalAuth {
    public static let maximumFailedAttempts = 5
    public static let lockoutDuration: TimeInterval = 300
    public static let authorizationLifetime: TimeInterval = 60
    /// Idle window of the in-memory parent session, separate from the
    /// 60-second operation capability. Remote presses refresh it.
    public static let sessionIdleLifetime: TimeInterval = 600

    public nonisolated let ledgerAuthorizer: ParentalAuthLedgerAuthorizer

    private let store: any SecureStore
    private let clock: any ParentalAuthClock
    private let registry: ParentalAuthorizationRegistry
    private var failure: ParentalAuthError?
    private var hasSeenSetup = false
    private var lockStartedAt: TimeInterval?
    private var lastLockObservation: TimeInterval?

    public init(
        store: any SecureStore = KeychainSecureStore(),
        clock: any ParentalAuthClock = SystemParentalAuthClock()
    ) {
        self.store = store
        self.clock = clock
        let registry = ParentalAuthorizationRegistry(store: store, clock: clock)
        self.registry = registry
        self.ledgerAuthorizer = ParentalAuthLedgerAuthorizer(registry: registry)
    }

    deinit { registry.revokeAll() }

    public func status() throws -> ParentalAuthStatus {
        guard var record = try loadRecord() else { return .notConfigured }
        if let remaining = try remainingLock(record: &record) {
            return .locked(remaining: remaining)
        }
        return .configured(failedAttempts: record.failedAttempts)
    }

    /// First-time setup does not itself issue a parental capability.
    public func setup(pin: String) throws {
        guard try loadRecord() == nil else { throw ParentalAuthError.alreadyConfigured }
        guard Self.isValidPIN(pin) else { throw ParentalAuthError.invalidPINFormat }
        let record = try PINRecord(pin: pin)
        try write(AuthStorage.marker, key: AuthStorage.markerKey)
        hasSeenSetup = true
        try persist(record)
    }

    /// Malformed authentication attempts also count toward lockout. A correct
    /// PIN is not checked during a lock, and failure counts are persisted before
    /// returning an error. Issuance requires a successful durable state write.
    public func authenticate(
        pin: String,
        context: ParentalAuthContext
    ) throws -> ParentalAuthorization {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        let validFormat = Self.isValidPIN(pin)
        let matches = validFormat ? try record.matches(pin: pin) : false
        guard matches else {
            registry.revokeAll()
            record.failedAttempts += 1
            record.locked = record.failedAttempts >= Self.maximumFailedAttempts
            try persist(record)
            if record.locked {
                // Persist first: even an invalid clock cannot erase this lock.
                let now = try monotonicNow()
                lockStartedAt = now
                lastLockObservation = now
                throw ParentalAuthError.locked(retryAfter: Self.lockoutDuration)
            }
            if !validFormat { throw ParentalAuthError.invalidPINFormat }
            throw ParentalAuthError.incorrectPIN(
                attemptsRemaining: Self.maximumFailedAttempts - record.failedAttempts
            )
        }
        record.failedAttempts = 0
        let snapshot = try persist(record)
        return try registry.issue(context: context, snapshot: snapshot)
    }

    public func validate(
        _ authorization: ParentalAuthorization,
        for context: ParentalAuthContext
    ) throws {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        try registry.validate(credential: authorization.credential, for: context)
    }

    /// PIN rotation requires a fresh, recovery-scoped capability. All previously
    /// issued capabilities, including this one, are revoked after rotation.
    public func changePIN(to pin: String, authorization: ParentalAuthorization) throws {
        try validate(authorization, for: .recovery)
        guard Self.isValidPIN(pin) else { throw ParentalAuthError.invalidPINFormat }
        let record = try PINRecord(pin: pin)
        registry.revokeAll()
        try persist(record)
    }

    public func revokeAuthorizations() { registry.revokeAll() }

    /// Issued only right after a successful PIN authentication. One session per
    /// registry: beginSession supersedes the previous session without revoking
    /// its already-issued operation capabilities; use endSession for that.
    /// The session is in-memory only; it never extends the 60-second operation
    /// capabilities and cannot unlock a locked record.
    public func beginSession(pin: String) throws -> ParentalSession {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        guard Self.isValidPIN(pin), try record.matches(pin: pin) else {
            registry.revokeAll()
            record.failedAttempts += 1
            record.locked = record.failedAttempts >= Self.maximumFailedAttempts
            try persist(record)
            if record.locked {
                let now = try monotonicNow()
                lockStartedAt = now
                lastLockObservation = now
                throw ParentalAuthError.locked(retryAfter: Self.lockoutDuration)
            }
            throw ParentalAuthError.incorrectPIN(
                attemptsRemaining: Self.maximumFailedAttempts - record.failedAttempts
            )
        }
        record.failedAttempts = 0
        let snapshot = try persist(record)
        return try registry.beginSession(snapshot: snapshot)
    }

    /// Validates the session and refreshes its idle window. Returns the remaining
    /// seconds so the parental center can show or renew its 10-minute timer.
    /// Idle expiry discards only the session; operation capabilities keep their
    /// independent 60-second deadline, and fresh PIN capabilities are unaffected.
    public func validateSession(_ session: ParentalSession) throws -> TimeInterval {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        return try registry.validateSession(session.credential)
    }

    /// Passive check for UI timers: reports whether the session is still valid
    /// and its remaining idle budget WITHOUT refreshing the activity timestamp.
    /// Only real user interaction (via operationAuthorization/validateSession)
    /// keeps the 10-minute idle window alive.
    public func peekSession(_ session: ParentalSession) throws -> TimeInterval {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        return try registry.peekSession(session.credential)
    }

    /// Ordinary settings actions: exchanges the valid session for a fresh
    /// 60-second operation capability bound to the requested context. High-risk
    /// operations must NOT use this path; they require a fresh PIN authentication
    /// so the lockout counter still guards them.
    public func operationAuthorization(
        _ session: ParentalSession,
        context: ParentalAuthContext
    ) throws -> ParentalAuthorization {
        guard var record = try loadRecord() else { throw ParentalAuthError.notConfigured }
        if let remaining = try remainingLock(record: &record) {
            throw ParentalAuthError.locked(retryAfter: remaining)
        }
        return try registry.operationAuthorization(session.credential, context: context)
    }

    /// Throwing-free convenience for UI call sites that already checked the
    /// session; returns nil when the session or record is no longer valid.
    public func sessionOperationToken(
        _ session: ParentalSession,
        context: ParentalAuthContext
    ) -> ParentalAuthorization? {
        try? operationAuthorization(session, context: context)
    }

    /// Explicit lock (leaving the center, backgrounding) discards the session and
    /// all operation capabilities issued from it, even if it was already replaced.
    /// Other sessions and independent fresh PIN capabilities are unaffected.
    public func endSession(_ session: ParentalSession) {
        registry.endSession(session.credential)
    }

    public nonisolated static func isValidPIN(_ pin: String) -> Bool {
        pin.utf8.count == 6 && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private func loadRecord() throws -> PINRecord? {
        if let failure { throw failure }
        let marker: Data?
        let data: Data?
        do {
            marker = try store.read(key: AuthStorage.markerKey)
            data = try store.read(key: AuthStorage.recordKey)
        } catch {
            throw poison(.storageUnavailable)
        }
        if marker == nil && data == nil {
            guard !hasSeenSetup else { throw poison(.corruptedState) }
            return nil
        }
        hasSeenSetup = true
        guard marker == AuthStorage.marker, let data,
              let record = try? JSONDecoder().decode(PINRecord.self, from: data),
              record.isValid else {
            throw poison(.corruptedState)
        }
        return record
    }

    @discardableResult
    private func persist(_ record: PINRecord) throws -> Data {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(record)
        } catch { throw poison(.corruptedState) }
        try write(data, key: AuthStorage.recordKey)
        return data
    }

    private func write(_ data: Data, key: String) throws {
        if let failure { throw failure }
        do { try store.write(data, key: key) }
        catch { throw poison(.storageUnavailable) }
    }

    private func poison(_ error: ParentalAuthError) -> ParentalAuthError {
        failure = error
        registry.revokeAll()
        return error
    }

    private func monotonicNow() throws -> TimeInterval {
        let now = clock.monotonicTime()
        guard now.isFinite, now >= 0 else {
            registry.revokeAll()
            lockStartedAt = nil
            lastLockObservation = nil
            throw ParentalAuthError.invalidClock
        }
        return now
    }

    private func remainingLock(record: inout PINRecord) throws -> TimeInterval? {
        guard record.locked else {
            lockStartedAt = nil
            lastLockObservation = nil
            return nil
        }
        registry.revokeAll()
        let now = try monotonicNow()
        if lockStartedAt == nil || now < (lastLockObservation ?? now) {
            lockStartedAt = now
        }
        lastLockObservation = now
        let elapsed = now - (lockStartedAt ?? now)
        guard elapsed >= Self.lockoutDuration else {
            return Self.lockoutDuration - elapsed
        }
        record.locked = false
        record.failedAttempts = 0
        // Do not clear local observation unless the durable clear succeeds.
        try persist(record)
        lockStartedAt = nil
        lastLockObservation = nil
        return nil
    }
}

private enum AuthStorage {
    static let markerKey = "parental-auth.setup-marker.v1"
    static let recordKey = "parental-auth.record.v1"
    static let marker = Data("parental-auth-setup-started-v1".utf8)
}

private struct PINRecord: Codable {
    let version: Int
    let algorithm: String
    let rounds: UInt32
    let salt: Data
    let derivedKey: Data
    var failedAttempts: Int
    var locked: Bool

    init(pin: String) throws {
        version = 1
        algorithm = "PBKDF2-HMAC-SHA256"
        rounds = 600_000
        salt = try secureRandomBytes(count: 32)
        derivedKey = try Self.derive(pin: pin, salt: salt, rounds: rounds)
        failedAttempts = 0
        locked = false
    }

    var isValid: Bool {
        version == 1 && algorithm == "PBKDF2-HMAC-SHA256" && rounds == 600_000
            && salt.count == 32 && derivedKey.count == 32
            && (0...ParentalAuth.maximumFailedAttempts).contains(failedAttempts)
            && locked == (failedAttempts == ParentalAuth.maximumFailedAttempts)
    }

    func matches(pin: String) throws -> Bool {
        var candidate = try Self.derive(pin: pin, salt: salt, rounds: rounds)
        defer { candidate.resetBytes(in: 0..<candidate.count) }
        // Length is fixed and validated before entering this platform-provided
        // constant-time comparison; never use Data == for PIN-derived secrets.
        return candidate.withUnsafeBytes { candidateBytes in
            derivedKey.withUnsafeBytes { expectedBytes in
                timingsafe_bcmp(candidateBytes.baseAddress!, expectedBytes.baseAddress!, 32) == 0
            }
        }
    }

    private static func derive(pin: String, salt: Data, rounds: UInt32) throws -> Data {
        var password = Array(pin.utf8)
        defer {
            password.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { _ = memset_s(base, bytes.count, 0, bytes.count) }
            }
        }
        var result = Data(count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ParentalAuthError.cryptographicFailure }
        return result
    }
}

private func secureRandomBytes(count: Int) throws -> Data {
    var result = Data(count: count)
    let status = result.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw ParentalAuthError.cryptographicFailure }
    return result
}

/// Shared only by one actor and its synchronous ledger adapter. No public entry
/// point can register credentials. The lock also serializes expiry/revocation.
final class ParentalAuthorizationRegistry: @unchecked Sendable {
    private struct Entry {
        let context: ParentalAuthContext
        let issuedAt: TimeInterval
        let snapshot: Data
        /// nil for fresh PIN authentication; otherwise the issuing session.
        let sessionCredential: Data?
    }

    private struct SessionEntry {
        let snapshot: Data
        var startedAt: TimeInterval
        var lastActivity: TimeInterval
    }

    private let lock = NSLock()
    private let store: any SecureStore
    private let clock: any ParentalAuthClock
    private var entries: [Data: Entry] = [:]
    private var session: (credential: Data, entry: SessionEntry)?
    private var lastObservation: TimeInterval?

    fileprivate init(store: any SecureStore, clock: any ParentalAuthClock) {
        self.store = store
        self.clock = clock
    }

    fileprivate func issue(context: ParentalAuthContext, snapshot: Data) throws -> ParentalAuthorization {
        lock.lock()
        defer { lock.unlock() }
        let now = try observeTime()
        entries = entries.filter { now - $0.value.issuedAt < ParentalAuth.authorizationLifetime }
        let credential = try secureRandomBytes(count: 32)
        entries[credential] = Entry(context: context, issuedAt: now, snapshot: snapshot, sessionCredential: nil)
        return ParentalAuthorization(context: context, credential: credential)
    }

    fileprivate func beginSession(snapshot: Data) throws -> ParentalSession {
        lock.lock()
        defer { lock.unlock() }
        let now = try observeTime()
        // One session at a time; replacement leaves issued capabilities on their
        // existing deadlines until the caller explicitly ends their source session.
        session = nil
        let credential = try secureRandomBytes(count: 32)
        session = (credential, SessionEntry(snapshot: snapshot, startedAt: now, lastActivity: now))
        return ParentalSession(credential: credential, expiresAtMonotonicSeconds: now + ParentalAuth.sessionIdleLifetime)
    }

    func validateSession(_ credential: Data) throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let held = session, held.credential == credential else {
            throw ParentalAuthError.invalidAuthorization
        }
        let now = try observeTime()
        guard now - held.entry.lastActivity < ParentalAuth.sessionIdleLifetime else {
            session = nil
            throw ParentalAuthError.authorizationExpired
        }
        guard sessionSnapshotMatches(held.entry.snapshot) else {
            session = nil
            throw ParentalAuthError.invalidAuthorization
        }
        session?.entry.lastActivity = now
        return ParentalAuth.sessionIdleLifetime - (now - held.entry.lastActivity)
    }

    /// Like validateSession but does NOT refresh lastActivity: UI polling uses
    /// this so passive timers cannot keep an idle session alive forever.
    func peekSession(_ credential: Data) throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let held = session, held.credential == credential else {
            throw ParentalAuthError.invalidAuthorization
        }
        let now = try observeTime()
        guard now - held.entry.lastActivity < ParentalAuth.sessionIdleLifetime else {
            session = nil
            throw ParentalAuthError.authorizationExpired
        }
        guard sessionSnapshotMatches(held.entry.snapshot) else {
            session = nil
            throw ParentalAuthError.invalidAuthorization
        }
        return ParentalAuth.sessionIdleLifetime - (now - held.entry.lastActivity)
    }

    func operationAuthorization(_ credential: Data, context: ParentalAuthContext) throws -> ParentalAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard let held = session, held.credential == credential else {
            throw ParentalAuthError.invalidAuthorization
        }
        let now = try observeTime()
        guard now - held.entry.lastActivity < ParentalAuth.sessionIdleLifetime else {
            session = nil
            throw ParentalAuthError.authorizationExpired
        }
        guard sessionSnapshotMatches(held.entry.snapshot) else {
            session = nil
            throw ParentalAuthError.invalidAuthorization
        }
        session?.entry.lastActivity = now
        // Register under the lock already held; issue() would take it again.
        let operationCredential = try secureRandomBytes(count: 32)
        entries[operationCredential] = Entry(context: context, issuedAt: now, snapshot: held.entry.snapshot,
                                             sessionCredential: held.credential)
        return ParentalAuthorization(context: context, credential: operationCredential)
    }

    func endSession(_ credential: Data) {
        lock.lock()
        defer { lock.unlock() }
        // A delayed end for a replaced session must revoke its capabilities
        // without discarding the new session or independent PIN capabilities.
        entries = entries.filter { $0.value.sessionCredential != credential }
        if session?.credential == credential { session = nil }
    }

    /// The session is only valid while the underlying PIN record is unchanged;
    /// a failed write, rotation or corrupted record invalidates it immediately.
    private func sessionSnapshotMatches(_ snapshot: Data) -> Bool {
        let marker: Data?
        let current: Data?
        do {
            marker = try store.read(key: AuthStorage.markerKey)
            current = try store.read(key: AuthStorage.recordKey)
        } catch { return false }
        guard marker == AuthStorage.marker, current == snapshot else { return false }
        return true
    }

    func validate(credential: Data, for context: ParentalAuthContext) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = try observeTime()
        guard credential.count == 32, let entry = entries[credential] else {
            throw ParentalAuthError.invalidAuthorization
        }
        guard now - entry.issuedAt < ParentalAuth.authorizationLifetime else {
            entries.removeValue(forKey: credential)
            throw ParentalAuthError.authorizationExpired
        }
        guard entry.context == context else { throw ParentalAuthError.wrongContext }
        // Even the synchronous adapter fails closed if the persistent backing
        // store becomes unreadable, disappears or changes after issuance.
        let marker: Data?
        let snapshot: Data?
        do {
            marker = try store.read(key: AuthStorage.markerKey)
            snapshot = try store.read(key: AuthStorage.recordKey)
        } catch {
            entries.removeAll()
            throw ParentalAuthError.storageUnavailable
        }
        guard marker == AuthStorage.marker, snapshot != nil else {
            entries.removeAll()
            throw ParentalAuthError.corruptedState
        }
        guard snapshot == entry.snapshot else {
            entries.removeAll()
            throw ParentalAuthError.invalidAuthorization
        }
    }

    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        session = nil
    }

    private func observeTime() throws -> TimeInterval {
        let now = clock.monotonicTime()
        guard now.isFinite, now >= 0 else {
            entries.removeAll()
            throw ParentalAuthError.invalidClock
        }
        if let lastObservation, now < lastObservation {
            entries.removeAll()
        }
        lastObservation = now
        return now
    }
}
