import Foundation
import XCTest
@testable import FamilyCore

/// The parent session must feel effortless without weakening any original
/// security property: no persistence, no lockout bypass, no stale-snapshot use.
final class ParentalSessionTests: XCTestCase {
    private final class Clock: ParentalAuthClock, @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_000
        func monotonicTime() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return seconds }
        func advance(_ delta: TimeInterval) { lock.lock(); defer { lock.unlock() }; seconds += delta }
    }

    private final class Store: SecureStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: Data]()
        func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    }

    private func make(clock: Clock) async throws -> ParentalAuth {
        let auth = ParentalAuth(store: Store(), clock: clock)
        try await auth.setup(pin: "246810")
        return auth
    }

    func testSessionSupportsOperationCapabilitiesAndIdleRefresh() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        var remaining = try await auth.validateSession(session)
        XCTAssertEqual(remaining, ParentalAuth.sessionIdleLifetime, accuracy: 2)
        let first = try await auth.operationAuthorization(session, context: .configureRules)
        try await auth.validate(first, for: .configureRules)
        clock.advance(500)
        remaining = try await auth.validateSession(session)
        XCTAssertEqual(remaining, ParentalAuth.sessionIdleLifetime - 500, accuracy: 2)
        let second = try await auth.operationAuthorization(session, context: .manageProfiles)
        try await auth.validate(second, for: .manageProfiles)
    }

    /// UI polling must not keep an idle session alive: peek reports the true
    /// remaining budget without touching lastActivity.
    func testPeekSessionDoesNotRefreshIdleWindow() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let startedAt = clock.monotonicTime()
        let session = try await auth.beginSession(pin: "246810")
        // One poll per simulated minute for 9 minutes: peek must not extend.
        for minute in 1...9 {
            clock.advance(60)
            let remaining = try await auth.peekSession(session)
            let elapsed = clock.monotonicTime() - startedAt
            XCTAssertEqual(remaining, ParentalAuth.sessionIdleLifetime - elapsed, accuracy: 2,
                           "minute \(minute)")
        }
        clock.advance(60)
        await expectError(ParentalAuthError.authorizationExpired) { try await auth.peekSession(session) }
    }

    func testSessionExpiresAfterIdleWindow() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        clock.advance(ParentalAuth.sessionIdleLifetime + 1)
        await expectError(ParentalAuthError.authorizationExpired) { try await auth.validateSession(session) }
        // The expired session is discarded on first observation; later calls must
        // see it as unknown rather than re-reporting an extendable expiry.
        await expectError(ParentalAuthError.invalidAuthorization) {
            _ = try await auth.operationAuthorization(session, context: .manageProfiles)
        }
    }

    func testOperationContextIsStillEnforcedForSessionIssuedTokens() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        let token = try await auth.operationAuthorization(session, context: .manageProfiles)
        await expectError(ParentalAuthError.wrongContext) { try await auth.validate(token, for: .configureRules) }
    }

    func testEndSessionImmediatelyStopsCapabilities() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        try await auth.endSession(session)
        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validateSession(session) }
        await expectError(ParentalAuthError.invalidAuthorization) {
            _ = try await auth.operationAuthorization(session, context: .manageSession)
        }
    }

    func testEndSessionRevokesIssuedRecoveryCapabilityForActorAndLedger() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        let token = try await auth.operationAuthorization(session, context: .recovery)
        try await auth.validate(token, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: token.credential))

        await auth.endSession(session)

        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validate(token, for: .recovery) }
        XCTAssertThrowsError(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: token.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testEndSessionRevokesEveryOwnedContextButPreservesFreshPINCapability() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        // Match the PIN screen: authenticate first, then establish a session.
        let fresh = try await auth.authenticate(pin: "246810", context: .recovery)
        let session = try await auth.beginSession(pin: "246810")
        var tokens = [ParentalAuthorization]()
        for context in ParentalAuthContext.allCases {
            tokens.append(try await auth.operationAuthorization(session, context: context))
        }
        clock.advance(59)

        await auth.endSession(session)
        await auth.endSession(session) // Ending twice must remain scoped and harmless.

        for token in tokens {
            await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validate(token, for: token.context) }
        }
        try await auth.validate(fresh, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: fresh.credential))
        clock.advance(1)
        await expectError(ParentalAuthError.authorizationExpired) { try await auth.validate(fresh, for: .recovery) }
    }

    func testEndReplacedSessionRevokesOnlyItsCapabilities() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let first = try await auth.beginSession(pin: "246810")
        let firstToken = try await auth.operationAuthorization(first, context: .recovery)
        let second = try await auth.beginSession(pin: "246810")
        let secondToken = try await auth.operationAuthorization(second, context: .recovery)
        let fresh = try await auth.authenticate(pin: "246810", context: .recovery)

        // Replacement invalidates the old session, not its existing 60-second tokens.
        await expectError(ParentalAuthError.invalidAuthorization) { _ = try await auth.validateSession(first) }
        await auth.endSession(.placeholder)
        try await auth.validate(firstToken, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: firstToken.credential))

        await auth.endSession(first)
        await auth.endSession(first)

        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validate(firstToken, for: .recovery) }
        XCTAssertThrowsError(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: firstToken.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
        _ = try await auth.validateSession(second)
        try await auth.validate(secondToken, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: secondToken.credential))
        try await auth.validate(fresh, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: fresh.credential))
    }

    func testEndCurrentSessionDoesNotRevokeReplacedSessionCapabilities() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let first = try await auth.beginSession(pin: "246810")
        let firstToken = try await auth.operationAuthorization(first, context: .recovery)
        let second = try await auth.beginSession(pin: "246810")
        let secondToken = try await auth.operationAuthorization(second, context: .recovery)

        await auth.endSession(second)

        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validate(secondToken, for: .recovery) }
        try await auth.validate(firstToken, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: firstToken.credential))
        // The old source can still be ended after the active session was cleared.
        await auth.endSession(first)
        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validate(firstToken, for: .recovery) }
        XCTAssertThrowsError(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: firstToken.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testSessionActivityDoesNotExtendIssuedCapabilityLifetime() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        let actorToken = try await auth.operationAuthorization(session, context: .recovery)
        let ledgerToken = try await auth.operationAuthorization(session, context: .recovery)
        clock.advance(59)
        _ = try await auth.validateSession(session)
        try await auth.validate(actorToken, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: ledgerToken.credential))

        clock.advance(1)

        await expectError(ParentalAuthError.authorizationExpired) { try await auth.validate(actorToken, for: .recovery) }
        XCTAssertThrowsError(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: ledgerToken.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .authorizationExpired)
        }
        _ = try await auth.validateSession(session)
    }

    func testIdleSessionExpiryPreservesFreshPINCapability() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        clock.advance(ParentalAuth.sessionIdleLifetime - 1)
        let fresh = try await auth.authenticate(pin: "246810", context: .recovery)
        clock.advance(1)

        // A fresh PIN token neither refreshes the old session nor belongs to it.
        await expectError(ParentalAuthError.authorizationExpired) { _ = try await auth.peekSession(session) }
        await expectError(ParentalAuthError.invalidAuthorization) { _ = try await auth.validateSession(session) }
        await auth.endSession(session)

        try await auth.validate(fresh, for: .recovery)
        XCTAssertNoThrow(try auth.ledgerAuthorizer.authorize(operation: .reanchorClock, credential: fresh.credential))
    }

    func testNewAuthenticationSupersedesPreviousSession() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let first = try await auth.beginSession(pin: "246810")
        _ = try await auth.beginSession(pin: "246810")
        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validateSession(first) }
    }

    func testWrongPINCountsTowardLockoutAndDoesNotStartSession() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        // Four wrong attempts leave one remaining; each reports the true count.
        for remaining in stride(from: ParentalAuth.maximumFailedAttempts - 1, through: 1, by: -1) {
            await expectError(ParentalAuthError.incorrectPIN(attemptsRemaining: remaining)) {
                _ = try await auth.beginSession(pin: "000000")
            }
        }
        // The fifth wrong attempt locks the record and reports a lockout.
        await expectError(ParentalAuthError.locked(retryAfter: ParentalAuth.lockoutDuration)) {
            _ = try await auth.beginSession(pin: "000000")
        }
        // While locked, even the correct PIN cannot start a session.
        await expectError(ParentalAuthError.locked(retryAfter: ParentalAuth.lockoutDuration)) {
            _ = try await auth.beginSession(pin: "246810")
        }
    }

    func testSessionFailsClosedWhenRecordChangesAfterRotation() async throws {
        let clock = Clock(); let auth = try await make(clock: clock)
        let session = try await auth.beginSession(pin: "246810")
        let recovery = try await auth.authenticate(pin: "246810", context: .recovery)
        try await auth.changePIN(to: "135790", authorization: recovery)
        await expectError(ParentalAuthError.invalidAuthorization) { try await auth.validateSession(session) }
        await expectError(ParentalAuthError.invalidAuthorization) {
            _ = try await auth.operationAuthorization(session, context: .configureRules)
        }
    }
}

private extension ParentalSessionTests {
    func expectError(_ expected: Error, _ body: () async throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ParentalAuthError, expected as? ParentalAuthError, file: file, line: line) }
    }
}
