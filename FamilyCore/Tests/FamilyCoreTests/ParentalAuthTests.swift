import Foundation
import XCTest
@testable import FamilyCore

/// Every test explicitly injects memory-only storage. No test creates, reads or
/// writes KeychainSecureStore or the user's real Keychain.
final class ParentalAuthTests: XCTestCase {
    func testPINMustBeExactlySixASCIIDigits() async throws {
        let store = PINMemoryStore()
        let auth = ParentalAuth(store: store, clock: PINTestClock())
        let invalid = ["", "12345", "1234567", "abcdef", "12345a", " 12345", "12345 ",
                       "12345\n", "１２３４５６", "١٢٣٤٥٦", "12345é", "12345\0", "12345🙂"]
        for pin in invalid {
            XCTAssertFalse(ParentalAuth.isValidPIN(pin), "Unexpected valid PIN: \(pin)")
            await expectError(.invalidPINFormat) { try await auth.setup(pin: pin) }
        }
        XCTAssertTrue(ParentalAuth.isValidPIN("000000"))
        XCTAssertTrue(ParentalAuth.isValidPIN("012345"))
        XCTAssertTrue(store.snapshot().isEmpty)
        let status = try await auth.status()
        XCTAssertEqual(status, .notConfigured)
        try await auth.setup(pin: "012345")
        let authorization = try await auth.authenticate(pin: "012345", context: .manageProfiles)
        try await auth.validate(authorization, for: .manageProfiles)
        await expectError(.alreadyConfigured) { try await auth.setup(pin: "999999") }
    }

    func testRandomSaltAndSlowDerivedKeyArePersistedWithoutPlaintext() async throws {
        let firstStore = PINMemoryStore()
        let secondStore = PINMemoryStore()
        let first = ParentalAuth(store: firstStore, clock: PINTestClock())
        let second = ParentalAuth(store: secondStore, clock: PINTestClock())
        try await first.setup(pin: "193847")
        try await second.setup(pin: "193847")
        let firstData = try XCTUnwrap(firstStore.recordData())
        let secondData = try XCTUnwrap(secondStore.recordData())
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(a["algorithm"] as? String, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(a["rounds"] as? Int, 600_000)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(a["salt"] as? String))?.count, 32)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(a["derivedKey"] as? String))?.count, 32)
        XCTAssertNotEqual(a["salt"] as? String, b["salt"] as? String)
        XCTAssertNotEqual(a["derivedKey"] as? String, b["derivedKey"] as? String)
        XCTAssertEqual(Set(a.keys), ["version", "algorithm", "rounds", "salt", "derivedKey", "failedAttempts", "locked"])
        XCTAssertEqual(firstStore.snapshot().count, 2)
        for data in firstStore.snapshot().values {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("193847"))
        }
    }

    func testUnconfiguredAuthenticationFails() async {
        let auth = ParentalAuth(store: PINMemoryStore(), clock: PINTestClock())
        await expectError(.notConfigured) {
            try await auth.authenticate(pin: "123456", context: .support)
        }
    }

    func testFailureCountPersistsAcrossReconstructionAndCorrectPINResetsIt() async throws {
        let store = PINMemoryStore()
        let clock = PINTestClock()
        let first = ParentalAuth(store: store, clock: clock)
        try await first.setup(pin: "123456")
        for remaining in [4, 3] {
            await expectError(.incorrectPIN(attemptsRemaining: remaining)) {
                try await first.authenticate(pin: "000000", context: .support)
            }
        }
        let rebuilt = ParentalAuth(store: store, clock: clock)
        let state = try await rebuilt.status()
        XCTAssertEqual(state, .configured(failedAttempts: 2))
        let authorization = try await rebuilt.authenticate(pin: "123456", context: .support)
        try await rebuilt.validate(authorization, for: .support)
        let reset = try await rebuilt.status()
        XCTAssertEqual(reset, .configured(failedAttempts: 0))
        let again = ParentalAuth(store: store, clock: clock)
        let persistedReset = try await again.status()
        XCTAssertEqual(persistedReset, .configured(failedAttempts: 0))
    }

    func testFifthFailureLocksAndCorrectPINCannotBypassLock() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        let state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 300))
        await expectError(.locked(retryAfter: 300)) {
            try await fixture.auth.authenticate(pin: "123456", context: .support)
        }
        fixture.clock.advance(299)
        await expectError(.locked(retryAfter: 1)) {
            try await fixture.auth.authenticate(pin: "123456", context: .support)
        }
        fixture.clock.advance(1)
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .support)
        try await fixture.auth.validate(authorization, for: .support)
        let rebuilt = ParentalAuth(store: fixture.store, clock: fixture.clock)
        let clear = try await rebuilt.status()
        XCTAssertEqual(clear, .configured(failedAttempts: 0))
    }

    func testLockRestartsConservativelyAfterActorAndProcessReconstruction() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        fixture.clock.advance(290)
        let state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 10))
        // Simulates a different process/boot epoch and long downtime. Neither
        // the old uptime nor elapsed wall time is accepted as served lock time.
        let rebootClock = PINTestClock(monotonic: 1)
        let rebuilt = ParentalAuth(store: fixture.store, clock: rebootClock)
        let restartState = try await rebuilt.status()
        XCTAssertEqual(restartState, .locked(remaining: 300))
        rebootClock.advance(299)
        await expectError(.locked(retryAfter: 1)) {
            try await rebuilt.authenticate(pin: "123456", context: .recovery)
        }
        rebootClock.advance(1)
        _ = try await rebuilt.authenticate(pin: "123456", context: .recovery)
    }

    func testWallClockForwardAndBackwardDoNotUnlockPIN() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        fixture.clock.adjustWall(-100_000_000)
        var state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 300))
        fixture.clock.adjustWall(200_000_000)
        state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 300))
        fixture.clock.advance(300)
        state = try await fixture.auth.status()
        XCTAssertEqual(state, .configured(failedAttempts: 0))
    }

    func testBackwardsMonotonicObservationRestartsFullLock() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        fixture.clock.advance(200)
        var state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 100))
        fixture.clock.setMonotonic(900)
        state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 300))
        fixture.clock.advance(299)
        state = try await fixture.auth.status()
        XCTAssertEqual(state, .locked(remaining: 1))
        fixture.clock.advance(1)
        state = try await fixture.auth.status()
        XCTAssertEqual(state, .configured(failedAttempts: 0))
    }

    func testMalformedAuthenticationAttemptsAreCountedAndLock() async throws {
        let fixture = try await configured()
        for index in 1...4 {
            await expectError(.invalidPINFormat) {
                try await fixture.auth.authenticate(pin: "１２３４５６", context: .support)
            }
            let status = try await fixture.auth.status()
            XCTAssertEqual(status, .configured(failedAttempts: index))
        }
        await expectError(.locked(retryAfter: 300)) {
            try await fixture.auth.authenticate(pin: "", context: .support)
        }
    }

    func testEveryAuthorizationIsContextBound() async throws {
        let fixture = try await configured()
        for context in ParentalAuthContext.allCases {
            let authorization = try await fixture.auth.authenticate(pin: "123456", context: context)
            XCTAssertEqual(authorization.context, context)
            XCTAssertEqual(authorization.credential.count, 32)
            try await fixture.auth.validate(authorization, for: context)
            for wrong in ParentalAuthContext.allCases where wrong != context {
                await expectError(.wrongContext) {
                    try await fixture.auth.validate(authorization, for: wrong)
                }
            }
        }
    }

    func testCapabilitiesRemainValidUntilExactSixtySecondBoundary() async throws {
        let fixture = try await configured()
        let first = try await fixture.auth.authenticate(pin: "123456", context: .support)
        let second = try await fixture.auth.authenticate(pin: "123456", context: .recovery)
        XCTAssertNotEqual(first.credential, second.credential)
        fixture.clock.adjustWall(-100_000_000)
        fixture.clock.advance(59.999)
        try await fixture.auth.validate(first, for: .support)
        try await fixture.auth.validate(second, for: .recovery)
        fixture.clock.setMonotonic(1_060)
        await expectError(.authorizationExpired) { try await fixture.auth.validate(first, for: .support) }
        await expectError(.authorizationExpired) { try await fixture.auth.validate(second, for: .recovery) }
    }

    func testCapabilityRejectsAnotherAuthInstanceAndRandomOrTamperedData() async throws {
        let fixture = try await configured()
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .manageProfiles)
        let rebuilt = ParentalAuth(store: fixture.store, clock: fixture.clock)
        await expectError(.invalidAuthorization) { try await rebuilt.validate(authorization, for: .manageProfiles) }
        XCTAssertThrowsError(try rebuilt.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: authorization.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
        for forged in [Data(), Data(repeating: 0, count: 32), Data(repeating: 1, count: 64)] {
            XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: forged)) {
                XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
            }
        }
        var tampered = authorization.credential
        tampered[0] ^= 1
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: tampered)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testLedgerAdapterEnforcesExactOperationMapping() async throws {
        let fixture = try await configured()
        let mapping: [(LedgerAdminOperation, ParentalAuthContext)] = [
            (.configureFamily, .configureRules), (.upsertProfile, .manageProfiles),
            (.selectViewers, .manageSession), (.reanchorClock, .recovery)
        ]
        for (operation, context) in mapping {
            let authorization = try await fixture.auth.authenticate(pin: "123456", context: context)
            XCTAssertNoThrow(try fixture.auth.ledgerAuthorizer.authorize(operation: operation, credential: authorization.credential))
            for (other, _) in mapping where other != operation {
                XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: other, credential: authorization.credential)) {
                    XCTAssertEqual($0 as? ParentalAuthError, .wrongContext)
                }
            }
        }
        let narrow = try await fixture.auth.authenticate(pin: "123456", context: .switchProfile)
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .selectViewers, credential: narrow.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .wrongContext)
        }
        let broad = try await fixture.auth.authenticate(pin: "123456", context: .manageSession)
        fixture.clock.advance(60)
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .selectViewers, credential: broad.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .authorizationExpired)
        }
    }

    func testExplicitRevocationAndFailedAuthenticationRevokeCapabilities() async throws {
        let fixture = try await configured()
        let first = try await fixture.auth.authenticate(pin: "123456", context: .support)
        await fixture.auth.revokeAuthorizations()
        await expectError(.invalidAuthorization) { try await fixture.auth.validate(first, for: .support) }
        let second = try await fixture.auth.authenticate(pin: "123456", context: .manageSession)
        await expectError(.incorrectPIN(attemptsRemaining: 4)) {
            try await fixture.auth.authenticate(pin: "000000", context: .support)
        }
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .selectViewers, credential: second.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testBackwardsClockRevokesAuthorizationRatherThanExtendingIt() async throws {
        let fixture = try await configured()
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .support)
        fixture.clock.setMonotonic(999)
        await expectError(.invalidAuthorization) { try await fixture.auth.validate(authorization, for: .support) }
        fixture.clock.setMonotonic(1_001)
        await expectError(.invalidAuthorization) { try await fixture.auth.validate(authorization, for: .support) }
    }

    func testRecoveryScopedRotationChangesPINAndRevokesCapabilities() async throws {
        let fixture = try await configured()
        let wrong = try await fixture.auth.authenticate(pin: "123456", context: .configureRules)
        await expectError(.wrongContext) { try await fixture.auth.changePIN(to: "654321", authorization: wrong) }
        let recovery = try await fixture.auth.authenticate(pin: "123456", context: .recovery)
        await expectError(.invalidPINFormat) { try await fixture.auth.changePIN(to: "123", authorization: recovery) }
        let oldRecord = fixture.store.recordData()
        try await fixture.auth.changePIN(to: "654321", authorization: recovery)
        XCTAssertNotEqual(oldRecord, fixture.store.recordData())
        await expectError(.invalidAuthorization) { try await fixture.auth.validate(recovery, for: .recovery) }
        await expectError(.incorrectPIN(attemptsRemaining: 4)) {
            try await fixture.auth.authenticate(pin: "123456", context: .support)
        }
        _ = try await fixture.auth.authenticate(pin: "654321", context: .support)
        XCTAssertEqual(fixture.store.snapshot().count, 2)
    }

    func testReadFailureNeverLooksUnconfiguredAndPoisonsInstance() async throws {
        let store = PINMemoryStore()
        let auth = ParentalAuth(store: store, clock: PINTestClock())
        store.setReadFailure(true)
        await expectError(.storageUnavailable) { try await auth.status() }
        store.setReadFailure(false)
        await expectError(.storageUnavailable) { try await auth.setup(pin: "123456") }
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testInterruptedSetupRetainsMarkerAndCannotBeReset() async throws {
        let store = PINMemoryStore()
        store.failWrite(number: 2)
        let auth = ParentalAuth(store: store, clock: PINTestClock())
        await expectError(.storageUnavailable) { try await auth.setup(pin: "123456") }
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertNil(store.recordData())
        store.failWrite(number: nil)
        let rebuilt = ParentalAuth(store: store, clock: PINTestClock())
        await expectError(.corruptedState) { try await rebuilt.status() }
        await expectError(.corruptedState) { try await rebuilt.setup(pin: "654321") }
    }

    func testMissingCredentialsOrMarkerAndCorruptedRecordFailClosed() async throws {
        let fixture = try await configured()
        for damage in ["record", "marker", "corrupt", "weakKDF"] {
            let store = PINMemoryStore(initial: fixture.store.snapshot())
            switch damage {
            case "record": store.removeRecord()
            case "marker": store.removeMarker()
            case "corrupt": store.replaceRecord(Data("not JSON".utf8))
            default:
                let data = try XCTUnwrap(store.recordData())
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                object["rounds"] = 1
                store.replaceRecord(try JSONSerialization.data(withJSONObject: object))
            }
            let auth = ParentalAuth(store: store, clock: fixture.clock)
            await expectError(.corruptedState) { try await auth.status() }
            await expectError(.corruptedState) { try await auth.setup(pin: "654321") }
        }
        fixture.store.removeAll()
        await expectError(.corruptedState) { try await fixture.auth.status() }
    }

    func testFailureCountWriteFaultCannotAuthorizeAndOldCapabilitiesAreRevoked() async throws {
        let fixture = try await configured()
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .manageProfiles)
        fixture.store.setWriteFailure(true)
        await expectError(.storageUnavailable) {
            try await fixture.auth.authenticate(pin: "000000", context: .support)
        }
        fixture.store.setWriteFailure(false)
        await expectError(.storageUnavailable) {
            try await fixture.auth.authenticate(pin: "123456", context: .manageProfiles)
        }
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: authorization.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testCorrectPINCannotIssueCapabilityWhenStoreWriteFails() async throws {
        let fixture = try await configured()
        fixture.store.setWriteFailure(true)
        await expectError(.storageUnavailable) {
            try await fixture.auth.authenticate(pin: "123456", context: .support)
        }
    }

    func testPersistedLockSurvivesFailedDurableClear() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        fixture.clock.advance(300)
        fixture.store.setWriteFailure(true)
        await expectError(.storageUnavailable) {
            try await fixture.auth.authenticate(pin: "123456", context: .support)
        }
        fixture.store.setWriteFailure(false)
        let rebuilt = ParentalAuth(store: fixture.store, clock: fixture.clock)
        let status = try await rebuilt.status()
        XCTAssertEqual(status, .locked(remaining: 300))
    }

    func testAdapterFailsClosedAndRevokesOnStoreReadFault() async throws {
        let fixture = try await configured()
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .manageProfiles)
        fixture.store.setReadFailure(true)
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: authorization.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .storageUnavailable)
        }
        fixture.store.setReadFailure(false)
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: authorization.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
    }

    func testAdapterRejectsMissingOrChangedPersistentRecord() async throws {
        let fixture = try await configured()
        let authorization = try await fixture.auth.authenticate(pin: "123456", context: .manageProfiles)
        fixture.store.replaceRecord(Data("changed record".utf8))
        XCTAssertThrowsError(try fixture.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: authorization.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .invalidAuthorization)
        }
        let second = try await configured()
        let capability = try await second.auth.authenticate(pin: "123456", context: .manageProfiles)
        second.store.removeRecord()
        XCTAssertThrowsError(try second.auth.ledgerAuthorizer.authorize(operation: .upsertProfile, credential: capability.credential)) {
            XCTAssertEqual($0 as? ParentalAuthError, .corruptedState)
        }
    }

    func testInvalidClockNeverClearsLockOrIssuesAuthorization() async throws {
        let fixture = try await configured()
        try await lock(fixture.auth)
        fixture.clock.setMonotonic(.nan)
        await expectError(.invalidClock) { try await fixture.auth.status() }
        fixture.clock.setMonotonic(2_000)
        let locked = try await fixture.auth.status()
        XCTAssertEqual(locked, .locked(remaining: 300))
        let second = try await configured()
        second.clock.setMonotonic(.infinity)
        await expectError(.invalidClock) {
            try await second.auth.authenticate(pin: "123456", context: .support)
        }
    }

    func testConcurrentAttemptsAreSerializedWithoutLosingCounts() async throws {
        let fixture = try await configured()
        let errors = await withTaskGroup(of: ParentalAuthError?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await fixture.auth.authenticate(pin: "000000", context: .support)
                        return nil
                    } catch { return error as? ParentalAuthError }
                }
            }
            var result: [ParentalAuthError?] = []
            for await error in group { result.append(error) }
            return result
        }
        XCTAssertEqual(errors.compactMap { $0 }.count, 12)
        for remaining in 1...4 {
            XCTAssertEqual(errors.filter { $0 == .incorrectPIN(attemptsRemaining: remaining) }.count, 1)
        }
        XCTAssertEqual(errors.filter { $0 == .locked(retryAfter: 300) }.count, 8)
        let rebuilt = ParentalAuth(store: fixture.store, clock: fixture.clock)
        let status = try await rebuilt.status()
        XCTAssertEqual(status, .locked(remaining: 300))
    }

    private func configured() async throws -> (auth: ParentalAuth, store: PINMemoryStore, clock: PINTestClock) {
        let store = PINMemoryStore()
        let clock = PINTestClock()
        let auth = ParentalAuth(store: store, clock: clock)
        try await auth.setup(pin: "123456")
        return (auth, store, clock)
    }

    private func lock(_ auth: ParentalAuth) async throws {
        for remaining in stride(from: 4, through: 1, by: -1) {
            await expectError(.incorrectPIN(attemptsRemaining: remaining)) {
                try await auth.authenticate(pin: "000000", context: .support)
            }
        }
        await expectError(.locked(retryAfter: 300)) {
            try await auth.authenticate(pin: "000000", context: .support)
        }
    }

    private func expectError<T>(
        _ expected: ParentalAuthError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ParentalAuthError, expected, file: file, line: line)
        }
    }
}

private final class PINMemoryStore: SecureStore, @unchecked Sendable {
    private enum Fault: Error { case simulatedIOFailure }
    private let lock = NSLock()
    private var values: [String: Data]
    private var readsFail = false
    private var writesFail = false
    private var writes = 0
    private var failedWriteNumber: Int?

    init(initial: [String: Data] = [:]) { values = initial }

    func read(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if readsFail { throw Fault.simulatedIOFailure }
        return values[key]
    }

    func write(_ data: Data, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        if writesFail || writes == failedWriteNumber { throw Fault.simulatedIOFailure }
        values[key] = data
    }

    func snapshot() -> [String: Data] { withLock { values } }
    func recordData() -> Data? { withLock { values.first { $0.key.contains(".record.") }?.value } }
    func setReadFailure(_ value: Bool) { withLock { readsFail = value } }
    func setWriteFailure(_ value: Bool) { withLock { writesFail = value } }
    func failWrite(number: Int?) { withLock { failedWriteNumber = number } }
    func removeAll() { withLock { values.removeAll() } }
    func removeRecord() { removeMatching(".record.") }
    func removeMarker() { removeMatching(".setup-marker.") }

    func replaceRecord(_ data: Data) {
        withLock {
            if let key = values.keys.first(where: { $0.contains(".record.") }) { values[key] = data }
        }
    }

    private func removeMatching(_ text: String) {
        withLock {
            if let key = values.keys.first(where: { $0.contains(text) }) { values.removeValue(forKey: key) }
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PINTestClock: ParentalAuthClock, @unchecked Sendable {
    private let lock = NSLock()
    private var monotonic: TimeInterval
    // Intentionally independent: changing civil time must have no effect on auth.
    private var wall: TimeInterval = 1_700_000_000

    init(monotonic: TimeInterval = 1_000) { self.monotonic = monotonic }
    func monotonicTime() -> TimeInterval { withLock { monotonic } }
    func advance(_ seconds: TimeInterval) { withLock { monotonic += seconds; wall += seconds } }
    func setMonotonic(_ value: TimeInterval) { withLock { monotonic = value } }
    func adjustWall(_ seconds: TimeInterval) { withLock { wall += seconds } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
