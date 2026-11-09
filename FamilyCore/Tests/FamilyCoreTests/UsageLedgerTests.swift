import XCTest
import Foundation
import CSQLite
@testable import FamilyCore

private final class TestLedgerClock: LedgerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sample = LedgerClockSample(wallMilliseconds: 1_799_150_400_000,
        monotonicMilliseconds: 10_000, continuityID: "test-process",
        monotonicSource: "mach-continuous-v1", bootSessionID: "test-boot")
    func now() -> LedgerClockSample { lock.lock(); defer { lock.unlock() }; return sample }
    func set(_ value: LedgerClockSample) { lock.lock(); defer { lock.unlock() }; sample = value }
    func advance(_ milliseconds: Int64, wallDelta: Int64? = nil, continuityID: String? = nil,
                 monotonicSource: String? = nil, bootSessionID: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        sample = LedgerClockSample(wallMilliseconds: sample.wallMilliseconds + (wallDelta ?? milliseconds),
            monotonicMilliseconds: sample.monotonicMilliseconds + milliseconds,
            continuityID: continuityID ?? sample.continuityID,
            monotonicSource: monotonicSource ?? sample.monotonicSource,
            bootSessionID: bootSessionID ?? sample.bootSessionID)
    }
    func setWall(_ milliseconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        sample = LedgerClockSample(wallMilliseconds: milliseconds,
            monotonicMilliseconds: sample.monotonicMilliseconds, continuityID: sample.continuityID,
            monotonicSource: sample.monotonicSource, bootSessionID: sample.bootSessionID)
    }
}

private final class TestLedgerCheckpoint: LedgerCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LedgerCheckpoint?
    var failWrite = false
    func load() throws -> LedgerCheckpoint? { lock.lock(); defer { lock.unlock() }; return value }
    func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failWrite, value == expected else { throw LedgerError.securityStoreUnavailable }
        value = new
    }
}
private struct TestLedgerAdmin: LedgerAdminAuthorizing {
    func authorize(operation: LedgerAdminOperation, credential: Data) throws {
        guard credential == Data("test-only-capability".utf8) else { throw LedgerError.unauthorized }
    }
}

final class UsageLedgerTests: XCTestCase {
    private let credential = Data("test-only-capability".utf8)
    private let minute: Int64 = 60_000
    private var directories: [URL] = []
    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("family-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        directories.append(directory)
        return directory.appendingPathComponent("usage.sqlite")
    }
    private func profile(_ name: String, limit: Int64 = 5_400_000) -> ViewerProfile {
        ViewerProfile(displayName: name,
            curriculum: CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
                academicYear: "2026-2027", semester: "上", subjects: ["数学"],
                subjectTextbookVersions: ["数学": "通用知识版"], learnedChapters: ["数学": ["整数"]],
                chapterProgress: ["数学": ["整数": 50]]), dailyLimitMilliseconds: limit)
    }
    private func setup(config: FamilyConfiguration = FamilyConfiguration(),
                       profiles: [ViewerProfile]? = nil) async throws
        -> (UsageLedger, TestLedgerClock, TestLedgerCheckpoint, URL, [ViewerProfile]) {
        let url = try location(); let clock = TestLedgerClock(); let store = TestLedgerCheckpoint()
        let ledger = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await ledger.configureFamily(config, credential: credential)
        let profiles = profiles ?? [profile("A"), profile("B")]
        for profile in profiles { try await ledger.upsertProfile(profile, credential: credential) }
        try await ledger.selectViewers([profiles[0].id], credential: credential)
        return (ledger, clock, store, url, profiles)
    }
    private func play(_ ledger: UsageLedger, _ clock: TestLedgerClock, _ duration: Int64) async throws {
        var remaining = duration
        while remaining > 0 {
            let lease = try await ledger.reservePlayback(eventID: UUID().uuidString, requestedMilliseconds: remaining)
            try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
            clock.advance(lease.reservedMilliseconds)
            let receipt = try await ledger.settlePlayback(leaseID: lease.id)
            XCTAssertEqual(receipt.actualMilliseconds, lease.reservedMilliseconds)
            remaining -= lease.reservedMilliseconds
        }
    }
    private func expect(_ error: LedgerError, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(error)", file: file, line: line) }
        catch let actual as LedgerError { XCTAssertEqual(actual, error, file: file, line: line) }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }
    private func sql(_ url: URL, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw LedgerError.database("test open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LedgerError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw LedgerError.database(String(cString: sqlite3_errmsg(db))) }
        return result == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
    }

    // MARK: Calendar accounting recovery (logical time is not a civil date)

    private func calendarMilliseconds(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1_000)
    }

    private func calendarSetup(config: FamilyConfiguration = FamilyConfiguration()) async throws
        -> (UsageLedger, TestLedgerClock, TestLedgerCheckpoint, URL, ViewerProfile) {
        let clock = TestLedgerClock(), store = TestLedgerCheckpoint(), url = try location()
        clock.setWall(calendarMilliseconds("2026-11-05T19:12:30Z")) // Nov 6, Shanghai
        let ledger = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await ledger.configureFamily(config, credential: credential)
        let child = profile("Calendar child")
        try await ledger.upsertProfile(child, credential: credential)
        return (ledger, clock, store, url, child)
    }

    /// Reproduce build 11: calendar anchor recovered, accounting date still two days behind.
    private func makeBuild11Payload(_ url: URL, clock: TestLedgerClock) throws {
        try editPersistedState(url) { state in
            for key in ["calendarAccountingAligned", "familyReportBaseline", "personalReportBaseline",
                        "familyFrozenCarry", "personalFrozenCarry"] { state.removeValue(forKey: key) }
            let sample = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clock.now()))
            state["clockAnchor"] = sample; state["lastClock"] = sample
        }
    }

    func testCalendarRecoveryCarriesBudgetNotHistoryAndResetsAtActualMidnightExactlyOnce() async throws {
        let (ledger, clock, _, url, child) = try await calendarSetup()
        try await play(ledger, clock, 700)
        let abandoned = try await ledger.reservePlayback(eventID: "old-active", requestedMilliseconds: 500)
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        let blocked = try await ledger.snapshot()
        XCTAssertFalse(blocked.clockIsTrusted)
        let history = try sql(url, "SELECT actual_ms || ':' || frozen_ms FROM family_daily_usage WHERE day=20261106")
        XCTAssertEqual(history, "700:500")
        try await ledger.reanchorClock(credential: credential)
        let confirmed = try await ledger.snapshot()
        XCTAssertEqual(confirmed.day, 20261108)
        XCTAssertEqual(confirmed.familyActualMilliseconds, 700)
        XCTAssertEqual(confirmed.personalActualMilliseconds[child.id], 700)
        XCTAssertEqual(confirmed.familyFrozenMilliseconds, 500)
        XCTAssertEqual(confirmed.frozenReservations, blocked.frozenReservations)
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: abandoned.id) }
        let todayBefore = try await ledger.report(lastDays: 1)
        XCTAssertEqual(todayBefore.generatedDay, 20261108)
        XCTAssertEqual(todayBefore.days.map(\.day), [20261108])
        XCTAssertEqual(todayBefore.days.first?.familyActualMilliseconds, 0)
        try await play(ledger, clock, 300)
        let today = try await ledger.report(lastDays: 1)
        XCTAssertEqual(today.days.first?.familyActualMilliseconds, 300)
        XCTAssertEqual(today.days.first?.personalMilliseconds[child.id.uuidString], 300)
        XCTAssertEqual(try sql(url, "SELECT actual_ms || ':' || frozen_ms FROM family_daily_usage WHERE day=20261106"), history)
        XCTAssertEqual(try sql(url, "SELECT SUM(actual_ms) FROM family_daily_usage"), "1000")
        let grantID = UUID()
        _ = try await ledger.grantTemporaryBonus(1_000, credential: credential, id: grantID)
        clock.advance(calendarMilliseconds("2026-11-08T16:00:00Z") - clock.now().wallMilliseconds)
        let midnight = try await ledger.snapshot()
        XCTAssertEqual(midnight.day, 20261109)
        XCTAssertEqual(midnight.familyActualMilliseconds, 0)
        XCTAssertEqual(midnight.familyFrozenMilliseconds, 0)
        XCTAssertEqual(midnight.parentalBonusMilliseconds, 0)
        XCTAssertEqual(midnight.continuousActualMilliseconds, 1_000)
        XCTAssertEqual(midnight.continuousFrozenMilliseconds, 500)
        try await play(ledger, clock, 200)
        _ = try await ledger.grantTemporaryBonus(1_000, credential: credential, id: grantID)
        let repeated = try await ledger.snapshot()
        XCTAssertEqual(repeated.familyActualMilliseconds, 200)
        XCTAssertEqual(repeated.parentalBonusMilliseconds, 0)
        XCTAssertEqual(try sql(url, "SELECT SUM(actual_ms) FROM family_daily_usage"), "1200")
        await ledger.close()
    }

    func testCalendarRecoveryBuild11AutomaticallyMigratesAndSurvivesRestartWithoutPIN() async throws {
        let (ledger, clock, store, url, child) = try await calendarSetup()
        try await play(ledger, clock, 700)
        let abandoned = try await ledger.reservePlayback(eventID: "build11-active", requestedMilliseconds: 500)
        await ledger.close()
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try makeBuild11Payload(url, clock: clock)
        var reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let migrated = try await reopened.snapshot()
        XCTAssertTrue(migrated.clockIsTrusted)
        XCTAssertEqual(migrated.day, 20261108)
        XCTAssertEqual(migrated.familyActualMilliseconds, 700)
        XCTAssertEqual(migrated.familyFrozenMilliseconds, 500)
        XCTAssertEqual(migrated.personalFrozenMilliseconds[child.id], 500)
        XCTAssertEqual(migrated.frozenReservations.first?.day, 20261106)
        await expect(.leaseExpired) { _ = try await reopened.settlePlayback(leaseID: abandoned.id) }
        try await play(reopened, clock, 300)
        await reopened.close()
        clock.advance(1_000, continuityID: "build11-next-process")
        reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let report = try await reopened.report(lastDays: 1)
        XCTAssertEqual(report.generatedDay, 20261108)
        XCTAssertEqual(report.days.first?.familyActualMilliseconds, 300)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=20261106"), "700")
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM parental_audit_logs WHERE operation='reanchorClock'"), "0")
        await reopened.close()
        clock.advance(3 * 86_400_000, continuityID: "days-later-same-boot")
        reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let later = try await reopened.snapshot()
        XCTAssertTrue(later.clockIsTrusted)
        XCTAssertEqual(later.day, 20261111)
        XCTAssertEqual(later.familyActualMilliseconds, 0)
        XCTAssertEqual(later.familyFrozenMilliseconds, 0)
        await reopened.close()
    }

    func testCalendarRecoveryBuild11FirstMaintenanceAfterTrustedDowntimeRollsForward() async throws {
        let (ledger, clock, store, url, _) = try await calendarSetup()
        try await play(ledger, clock, 700)
        await ledger.close()
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try makeBuild11Payload(url, clock: clock)
        clock.advance(2 * 86_400_000, continuityID: "upgrade-days-later")
        let reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertTrue(state.clockIsTrusted)
        XCTAssertEqual(state.day, 20261110)
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=20261106"), "700")
        XCTAssertEqual(try sql(url, "SELECT SUM(actual_ms) FROM family_daily_usage"), "700")
        await reopened.close()
    }

    func testCalendarRecoveryGrantsUseActualMidnightAndNeverExtendExistingDeadline() async throws {
        let (ledger, clock, _, _, _) = try await calendarSetup()
        let old = try await ledger.grantDayExemption(credential: credential)
        clock.setWall(calendarMilliseconds("2026-11-08T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        let skip = try await ledger.grantQuizSkip(credential: credential)
        XCTAssertEqual(skip.expiresAtLogicalWall - (try XCTUnwrap(skip.issuedAtLogicalWall)), 1_000)
        let before = try await ledger.snapshot()
        let effectiveOld = try XCTUnwrap(before.grants.first { $0.id == old.id })
        XCTAssertLessThanOrEqual(effectiveOld.expiresAtLogicalWall, old.expiresAtLogicalWall)
        XCTAssertEqual(effectiveOld.expiresAtLogicalWall, skip.expiresAtLogicalWall)
        clock.advance(1_000)
        let expired = try await ledger.snapshot()
        XCTAssertFalse(expired.dayExemptionActive)
        XCTAssertFalse(expired.quizSkipActive)
        XCTAssertTrue(expired.grants.isEmpty)
        let history = try await ledger.grantHistory()
        XCTAssertEqual(history.first, old)
        let replay = try await ledger.grantDayExemption(credential: credential, id: old.id)
        XCTAssertEqual(replay, old)
        let afterReplay = try await ledger.snapshot()
        XCTAssertFalse(afterReplay.dayExemptionActive)
        await ledger.close()
    }

    func testCalendarRecoveryQuizPassAndRewardCountsResetOnlyAtActualMidnight() async throws {
        let config = FamilyConfiguration(quizRules: QuizRules(questionsPerRound: 1, rewardMinutes: 1,
            personalDailyRewards: 1, familyDailyRewards: 1, quizBeforeFirstWatch: true, quizAfterRest: false))
        let (ledger, clock, _, url, child) = try await calendarSetup(config: config)
        let original = try await ledger.startQuizRound(childID: child.id, questions: [question("q")])
        let originalResult = try await ledger.submitQuizRound(original, answers: ["q": "a"])
        XCTAssertEqual(originalResult.rewardMinutes, 60_000)
        clock.setWall(calendarMilliseconds("2026-11-08T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        let cappedRound = try await ledger.startQuizRound(childID: child.id, questions: [question("q")])
        let capped = try await ledger.submitQuizRound(cappedRound, answers: ["q": "a"])
        XCTAssertEqual(capped.rewardMinutes, 0)
        XCTAssertEqual(capped.rewardDeniedReason, "personal-daily-cap")
        let lease = try await ledger.reservePlayback(eventID: "calendar-quiz-midnight", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        let renewal = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(renewal.receipt.day, 20261108)
        XCTAssertEqual(renewal.receipt.actualMilliseconds, 1_000)
        XCTAssertNil(renewal.nextLease)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "new-day-gate", requestedMilliseconds: 1) }
        let next = try await ledger.startQuizRound(childID: child.id, questions: [question("q")])
        let reward = try await ledger.submitQuizRound(next, answers: ["q": "a"])
        XCTAssertEqual(reward.rewardMinutes, 60_000)
        _ = try await ledger.submitQuizRound(next, answers: ["q": "a"])
        _ = try await ledger.submitQuizRound(original, answers: ["q": "a"])
        let after = try await ledger.snapshot()
        XCTAssertEqual(after.familyQuizRewardMilliseconds, 60_000)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM quiz_rewards"), "2")
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=20261108"), "1000")
        await ledger.close()
    }

    func testCalendarRecoveryQuarantineMigratesAndConfirmationCannotSkipIsolationDay() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 10_000,
            continuousLimitMilliseconds: 8_000, restMilliseconds: 1_000)
        let (ledger, clock, store, url, _) = try await calendarSetup(config: config)
        try await play(ledger, clock, 1_000)
        _ = try await ledger.prepareRestoredBackup(minimumRevision: 1_000, credential: credential)
        await ledger.close()
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try makeBuild11Payload(url, clock: clock)
        let restored = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let blocked = try await restored.snapshot()
        XCTAssertFalse(blocked.clockIsTrusted)
        XCTAssertTrue(blocked.recoveryQuarantineActive)
        try await restored.reanchorClock(credential: credential)
        let confirmed = try await restored.snapshot()
        XCTAssertEqual(confirmed.day, 20261108)
        XCTAssertTrue(confirmed.recoveryQuarantineActive)
        XCTAssertEqual(confirmed.familyActualMilliseconds, 1_000)
        XCTAssertEqual(confirmed.familyRecoveryFrozenMilliseconds, 9_000)
        clock.advance(1_000)
        try await restored.grantDayExemption(credential: credential)
        await expect(.budgetExhausted) { _ = try await restored.reservePlayback(eventID: "quarantine", requestedMilliseconds: 1) }
        // A second wall confirmation a day ahead is not a proven midnight.
        clock.setWall(calendarMilliseconds("2026-11-09T07:15:00Z"))
        try await restored.reanchorClock(credential: credential)
        let forward = try await restored.snapshot()
        XCTAssertEqual(forward.day, 20261109)
        XCTAssertTrue(forward.recoveryQuarantineActive)
        await expect(.budgetExhausted) { _ = try await restored.reservePlayback(eventID: "cannot-jump-isolation", requestedMilliseconds: 1) }
        clock.advance(calendarMilliseconds("2026-11-09T16:00:00Z") - clock.now().wallMilliseconds)
        let next = try await restored.snapshot()
        XCTAssertEqual(next.day, 20261110)
        XCTAssertFalse(next.recoveryQuarantineActive)
        XCTAssertEqual(next.familyActualMilliseconds, 0)
        let lease = try await restored.reservePlayback(eventID: "proven-midnight", requestedMilliseconds: 1)
        XCTAssertEqual(lease.reservedMilliseconds, 1)
        await restored.close()
    }

    func testCalendarRecoveryBackwardConfirmationCannotRefillAtAnAlreadyAccountedMidnight() async throws {
        let (ledger, clock, _, url, _) = try await calendarSetup()
        try await play(ledger, clock, 700)
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try await ledger.reanchorClock(credential: credential)
        try await play(ledger, clock, 300)
        clock.setWall(calendarMilliseconds("2026-11-07T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        clock.advance(1_000) // actual Nov 8, but that day's budget already exists
        let caughtUp = try await ledger.snapshot()
        XCTAssertEqual(caughtUp.day, 20261108)
        XCTAssertEqual(caughtUp.familyActualMilliseconds, 1_000)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=20261108"), "300")
        clock.advance(86_400_000)
        let next = try await ledger.snapshot()
        XCTAssertEqual(next.day, 20261109)
        XCTAssertEqual(next.familyActualMilliseconds, 0)
        await ledger.close()
    }

    func testCalendarRecoveryUntrustedReportStaysAtLastTrustedCalendarDate() async throws {
        let (ledger, clock, _, _, _) = try await calendarSetup()
        try await play(ledger, clock, 700)
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try await ledger.reanchorClock(credential: credential)
        try await play(ledger, clock, 300)
        clock.setWall(calendarMilliseconds("2026-12-08T07:15:00Z"))
        let report = try await ledger.report(lastDays: 1)
        XCTAssertEqual(report.generatedDay, 20261108)
        XCTAssertEqual(report.days.map(\.day), [20261108])
        XCTAssertEqual(report.days.first?.familyActualMilliseconds, 300)
        let state = try await ledger.snapshot()
        XCTAssertFalse(state.clockIsTrusted)
        await ledger.close()
    }

    func testCalendarRecoveryLateMidnightLeaseFreezesOnItsOriginalDayWithoutDuplicatingCarry() async throws {
        let (ledger, clock, _, url, _) = try await calendarSetup()
        try await play(ledger, clock, 700)
        clock.setWall(calendarMilliseconds("2026-11-08T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "recovered-late-midnight", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_001)
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: lease.id) }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.day, 20261109)
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertEqual(state.familyCarriedActualMilliseconds, 0)
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        XCTAssertEqual(state.continuousActualMilliseconds, 700)
        XCTAssertEqual(state.continuousFrozenMilliseconds, 1_000)
        XCTAssertEqual(state.frozenReservations.first?.day, 20261108)
        XCTAssertEqual(try sql(url, "SELECT actual_ms || ':' || frozen_ms FROM family_daily_usage WHERE day=20261106"), "700:0")
        XCTAssertEqual(try sql(url, "SELECT actual_ms || ':' || frozen_ms FROM family_daily_usage WHERE day=20261108"), "0:1000")
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM watch_sessions WHERE status='frozen'"), "1")
        await ledger.close()
    }

    func testCalendarRecoveryCarriedActualAndFrozenStillBindBothFamilyAndPersonalCaps() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 1_500, continuousLimitMilliseconds: 10_000)
        let (ledger, clock, _, _, child) = try await calendarSetup(config: config)
        var limited = child
        limited.dailyLimitMilliseconds = 1_200
        try await ledger.upsertProfile(limited, credential: credential)
        let second = profile("Second", limit: 1_500)
        try await ledger.upsertProfile(second, credential: credential)
        try await play(ledger, clock, 700)
        let abandoned = try await ledger.reservePlayback(eventID: "carry-cap", requestedMilliseconds: 300)
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try await ledger.reanchorClock(credential: credential)
        let limitedLease = try await ledger.reservePlayback(eventID: "personal-carry-cap", requestedMilliseconds: 5_000)
        XCTAssertEqual(limitedLease.reservedMilliseconds, 200)
        try await ledger.setPlaybackActivity(leaseID: limitedLease.id, activity: .playing)
        clock.advance(200)
        _ = try await ledger.settlePlayback(leaseID: limitedLease.id)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "personal-exhausted", requestedMilliseconds: 1) }
        try await ledger.selectViewers([second.id], credential: credential)
        let familyLease = try await ledger.reservePlayback(eventID: "family-carry-cap", requestedMilliseconds: 5_000)
        XCTAssertEqual(familyLease.reservedMilliseconds, 300)
        try await ledger.setPlaybackActivity(leaseID: familyLease.id, activity: .playing)
        clock.advance(300)
        _ = try await ledger.settlePlayback(leaseID: familyLease.id)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "family-exhausted", requestedMilliseconds: 1) }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 1_200)
        XCTAssertEqual(state.familyFrozenMilliseconds, 300)
        XCTAssertEqual(state.familyCarriedActualMilliseconds, 700)
        XCTAssertEqual(state.personalCarriedActualMilliseconds[child.id], 700)
        XCTAssertEqual(state.frozenReservations.first?.leaseID, abandoned.id)
        XCTAssertEqual(state.frozenReservations.first?.day, 20261106)
        await ledger.close()
    }

    func testCalendarRecoveryBackwardReanchorNeverExtendsAnEarlierGrantDeadline() async throws {
        let (ledger, clock, _, _, _) = try await calendarSetup()
        clock.setWall(calendarMilliseconds("2026-11-08T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        let original = try await ledger.grantQuizSkip(credential: credential)
        clock.setWall(calendarMilliseconds("2026-11-08T07:15:00Z"))
        try await ledger.reanchorClock(credential: credential)
        let before = try await ledger.snapshot()
        XCTAssertEqual(before.grants.first, original)
        clock.advance(1_000)
        let expired = try await ledger.snapshot()
        XCTAssertEqual(expired.day, 20261108)
        XCTAssertFalse(expired.quizSkipActive)
        XCTAssertTrue(expired.grants.isEmpty)
        await ledger.close()
    }

    func testDisablingSelectedProfileRequiresParentAndIdleLeaseWithoutSelectingAnotherChild() async throws {
        let (ledger, clock, _, url, people) = try await setup()
        try await play(ledger, clock, 700)
        var disabled = people[0]
        disabled.isEnabled = false
        await expect(.unauthorized) { try await ledger.upsertProfile(disabled, credential: Data()) }
        let lease = try await ledger.reservePlayback(eventID: "disable-while-active", requestedMilliseconds: 500)
        await expect(.leaseAlreadyActive) { try await ledger.upsertProfile(disabled, credential: self.credential) }
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let before = try await ledger.snapshot()
        try await ledger.upsertProfile(disabled, credential: credential)
        let after = try await ledger.snapshot()
        XCTAssertTrue(after.activeViewerIDs.isEmpty)
        XCTAssertEqual(after.familyActualMilliseconds, before.familyActualMilliseconds)
        XCTAssertEqual(after.personalActualMilliseconds, before.personalActualMilliseconds)
        XCTAssertEqual(after.continuousActualMilliseconds, before.continuousActualMilliseconds)
        XCTAssertEqual(after.profiles.first { $0.id == disabled.id }?.isEnabled, false)
        XCTAssertEqual(try sql(url, "SELECT object FROM parental_audit_logs WHERE operation='selectViewers' ORDER BY id DESC LIMIT 1"), "disable:" + disabled.id.uuidString)
        await expect(.noActiveViewers) { _ = try await ledger.reservePlayback(eventID: "not-other-child", requestedMilliseconds: 1) }
        await expect(.invalidInput("unknown or disabled viewer")) {
            try await ledger.selectViewers([disabled.id], credential: self.credential)
        }
        try await ledger.selectViewers([people[1].id], credential: credential)
        let next = try await ledger.reservePlayback(eventID: "explicit-new-child", requestedMilliseconds: 1)
        XCTAssertEqual(next.viewerIDs, [people[1].id])
        await ledger.close()
    }

    func testDisablingOneOfMultipleViewersPreservesOthersAndDoesNotAutoReselectOnEnable() async throws {
        let (ledger, _, _, _, people) = try await setup()
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        var disabled = people[0]
        disabled.isEnabled = false
        try await ledger.upsertProfile(disabled, credential: credential)
        let after = try await ledger.snapshot()
        XCTAssertEqual(after.activeViewerIDs, [people[1].id])
        disabled.isEnabled = true
        try await ledger.upsertProfile(disabled, credential: credential)
        let enabled = try await ledger.snapshot()
        XCTAssertEqual(enabled.activeViewerIDs, [people[1].id])
        await ledger.close()
    }

    func testFirstCreatedChildIsSelectedAutomatically() async throws {
        let url = try location()
        let clock = TestLedgerClock()
        let ledger = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: TestLedgerCheckpoint(), adminAuthorizer: TestLedgerAdmin())
        let child = profile("Only Child")
        try await ledger.upsertProfile(child, credential: credential)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.activeViewerIDs, [child.id])
        XCTAssertEqual(snapshot.familyActualMilliseconds, 0)
        await ledger.close()
    }

    func testAcceptance1Family120Personal90A80LeavesB40() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 86_400_000)
        let (ledger, clock, _, _, people) = try await setup(config: config)
        try await play(ledger, clock, 80 * minute)
        try await ledger.selectViewers([people[1].id], credential: credential)
        try await play(ledger, clock, 40 * minute)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 120 * minute)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 80 * minute)
        XCTAssertEqual(state.personalActualMilliseconds[people[1].id], 40 * minute)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "over", requestedMilliseconds: 1) }
        await ledger.close()
    }

    func testAcceptance23415Continuous35Plus5RestAndSwitching() async throws {
        let (ledger, clock, _, _, people) = try await setup()
        try await play(ledger, clock, 35 * minute)
        try await ledger.selectViewers([people[1].id], credential: credential)
        var state = try await ledger.snapshot()
        XCTAssertEqual(state.continuousActualMilliseconds, 35 * minute)
        try await play(ledger, clock, 5 * minute)
        try await ledger.selectViewers([people[0].id], credential: credential)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.remainingRestMilliseconds, 10 * minute)
        XCTAssertEqual(state.familyActualMilliseconds, 40 * minute)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "rest", requestedMilliseconds: 1) }
        clock.advance(10 * minute - 1)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "rest2", requestedMilliseconds: 1) }
        clock.advance(1)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.continuousActualMilliseconds, 0)
        XCTAssertEqual(state.familyActualMilliseconds, 40 * minute)
        await ledger.close()
    }

    // MARK: Clock continuity and recovery regressions

    func testClockRecoveryCumulativeDriftSurvivesProcessRestarts() async throws {
        let (initial, clock, store, url, _) = try await setup()
        var ledger = initial
        for index in 1...3 {
            await ledger.close()
            clock.advance(1_000, wallDelta: 2_000, continuityID: "process-\(index)")
            ledger = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let snapshot = try await ledger.snapshot()
            XCTAssertEqual(snapshot.clockIsTrusted, index < 3)
        }
        await expect(.clockUntrusted) {
            _ = try await ledger.reservePlayback(eventID: "drift", requestedMilliseconds: 1)
        }
        await ledger.close()
    }

    func testClockRecoveryNewlyFrozenRestDoesNotConsumePreFreezeElapsed() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        let lease = try await ledger.reservePlayback(eventID: "freeze-rest", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        await ledger.close()
        clock.advance(60_000, continuityID: "restarted")
        let reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await reopened.snapshot()
        XCTAssertTrue(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 1_000)
        XCTAssertEqual(snapshot.continuousFrozenMilliseconds, 1_000)
        XCTAssertEqual(snapshot.remainingRestMilliseconds, 10_000)
        await expect(.resting) {
            _ = try await reopened.reservePlayback(eventID: "wait-rest", requestedMilliseconds: 1)
        }
        clock.advance(10_000)
        let rested = try await reopened.snapshot()
        XCTAssertEqual(rested.remainingRestMilliseconds, 0)
        XCTAssertEqual(rested.familyFrozenMilliseconds, 1_000)
        await reopened.close()
    }

    func testClockRecoveryInvalidContinuityCannotBeAcceptedDuringMaintenance() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        clock.advance(1_000, continuityID: "")
        let snapshot = try await ledger.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        await expect(.clockUntrusted) { try await ledger.reanchorClock(credential: self.credential) }
        await ledger.close()
    }

    /// Only called with a closed, test-created ledger. Bind JSON as data, not SQL text.
    private func editPersistedState(_ url: URL, _ body: (inout [String: Any]) throws -> Void) throws {
        let db = try LedgerDatabase(path: url.path)
        defer { db.close() }
        let text = try XCTUnwrap(db.scalar("SELECT payload FROM ledger_state WHERE id=1"))
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        try body(&state)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self)
        try db.execute("UPDATE ledger_state SET payload=? WHERE id=1", [json])
        XCTAssertEqual(try db.scalar("SELECT json_valid(payload) FROM ledger_state WHERE id=1"), "1")
    }

    private func removeClockProvenance(_ state: inout [String: Any]) throws {
        state.removeValue(forKey: "clockRecoveryReason")
        for key in ["clockAnchor", "lastClock"] {
            var sample = try XCTUnwrap(state[key] as? [String: Any])
            sample.removeValue(forKey: "monotonicSource")
            sample.removeValue(forKey: "bootSessionID")
            state[key] = sample
        }
    }

    func testClockRecoveryAnonymousDeviceLegacyFalseNeedsParentOnlyOnce() async throws {
        let (ledger, clock, store, url, people) = try await setup(profiles: [profile("Anonymous")])
        await ledger.close()
        // Anonymized observed legacy payload: both deltas agree exactly, but the
        // values alone cannot establish which timebase or boot generated them.
        try editPersistedState(url) { state in
            state["clockAnchor"] = ["wallMilliseconds": Int64(1_794_024_542_037),
                "monotonicMilliseconds": Int64(5_489_681_731), "continuityID": "old-process"]
            state["lastClock"] = ["wallMilliseconds": Int64(1_794_024_577_964),
                "monotonicMilliseconds": Int64(5_489_717_658), "continuityID": "old-process"]
            state["logicalWall"] = Int64(1_794_024_577_964)
            state["day"] = Int64(20_261_107)
            state["clockTrusted"] = false
            try removeClockProvenance(&state)
        }
        clock.set(LedgerClockSample(wallMilliseconds: 1_794_024_578_964,
            monotonicMilliseconds: 5_489_718_658, continuityID: "upgraded-process",
            monotonicSource: "mach-continuous-v1", bootSessionID: "same-boot"))
        let reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let blocked = try await reopened.snapshot()
        XCTAssertFalse(blocked.clockIsTrusted)
        XCTAssertEqual(blocked.clockRecoveryReason, .legacyContinuityUnverifiable)
        XCTAssertFalse(blocked.recoveryQuarantineActive)
        XCTAssertEqual(blocked.profiles, people)
        XCTAssertEqual(blocked.familyActualMilliseconds, 0)
        XCTAssertEqual(blocked.familyFrozenMilliseconds, 0)
        await expect(.clockUntrusted) {
            _ = try await reopened.reservePlayback(eventID: "legacy-blocked", requestedMilliseconds: 100)
        }
        let unchanged = try store.load()
        await expect(.unauthorized) { try await reopened.reanchorClock(credential: Data()) }
        XCTAssertEqual(try store.load(), unchanged)
        try await reopened.reanchorClock(credential: credential)
        let confirmed = try await reopened.snapshot()
        XCTAssertTrue(confirmed.clockIsTrusted)
        XCTAssertNil(confirmed.clockRecoveryReason)
        XCTAssertEqual(confirmed.day, blocked.day)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), "1794024577964")
        await reopened.close()
        clock.advance(3_000, continuityID: "following-process")
        let following = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let stable = try await following.snapshot()
        XCTAssertTrue(stable.clockIsTrusted)
        XCTAssertNil(stable.clockRecoveryReason)
        XCTAssertEqual(stable.profiles, people)
        try await play(following, clock, 100)
        await following.close()
    }

    func testClockRecoveryBothOldTimebasePayloadsRequireProofEvenWithMatchingWallDelta() async throws {
        for oldMonotonic: Int64 in [10_000, 610_000] {
            for trusted in [true, false] {
                let (ledger, clock, store, url, _) = try await setup()
                let wall = clock.now().wallMilliseconds
                await ledger.close()
                try editPersistedState(url) { state in
                    try removeClockProvenance(&state)
                    state["clockTrusted"] = trusted
                    for key in ["clockAnchor", "lastClock"] {
                        var sample = try XCTUnwrap(state[key] as? [String: Any])
                        sample["monotonicMilliseconds"] = oldMonotonic
                        state[key] = sample
                    }
                }
                clock.set(LedgerClockSample(wallMilliseconds: wall + 1_000,
                    monotonicMilliseconds: 611_000, continuityID: "upgrade",
                    monotonicSource: "mach-continuous-v1", bootSessionID: "test-boot"))
                let upgraded = try UsageLedger(databaseURL: url, clock: clock,
                    checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
                let snapshot = try await upgraded.snapshot()
                XCTAssertFalse(snapshot.clockIsTrusted)
                XCTAssertEqual(snapshot.clockRecoveryReason, .legacyContinuityUnverifiable)
                XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), String(wall))
                await upgraded.close()
            }
        }
    }

    func testClockRecoveryProvenLegacyFalseFreezesLeaseAndDiscardsUnknownElapsed() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        let lease = try await ledger.reservePlayback(eventID: "proven-old", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        let wall = clock.now().wallMilliseconds
        await ledger.close()
        try editPersistedState(url) { state in
            state["clockTrusted"] = false
            state.removeValue(forKey: "clockRecoveryReason")
        }
        clock.advance(60_000, continuityID: "next-process")
        let recovered = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await recovered.snapshot()
        XCTAssertTrue(snapshot.clockIsTrusted)
        XCTAssertNil(snapshot.clockRecoveryReason)
        XCTAssertEqual(snapshot.familyActualMilliseconds, 0)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 1_000)
        XCTAssertEqual(snapshot.remainingRestMilliseconds, 10_000)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), String(wall))
        await expect(.leaseExpired) { _ = try await recovered.settlePlayback(leaseID: lease.id) }
        clock.advance(1_000)
        let after = try await recovered.snapshot()
        XCTAssertEqual(after.remainingRestMilliseconds, 9_000)
        XCTAssertEqual(after.frozenReservations.count, 1)
        await recovered.close()
    }

    func testClockRecoveryLegacyFalseMustMatchBothAnchorsAndPriorInterval() async throws {
        // Checking only now-last would miss accumulated drift; checking only
        // now-anchor would miss a corrupted/contradictory last checkpoint.
        for key in ["clockAnchor", "lastClock"] {
            let (ledger, clock, store, url, _) = try await setup()
            clock.advance(1_000)
            _ = try await ledger.snapshot()
            await ledger.close()
            try editPersistedState(url) { state in
                state["clockTrusted"] = false
                state.removeValue(forKey: "clockRecoveryReason")
                var sample = try XCTUnwrap(state[key] as? [String: Any])
                sample["wallMilliseconds"] = clock.now().wallMilliseconds + 5_000
                state[key] = sample
            }
            clock.advance(1_000, continuityID: "next-process")
            let reopened = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let snapshot = try await reopened.snapshot()
            XCTAssertFalse(snapshot.clockIsTrusted)
            XCTAssertEqual(snapshot.clockRecoveryReason, .wallDrift)
            await reopened.close()
        }
    }

    func testClockRecoverySameBootSleepAndRestartAdvanceExistingRest() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        try await play(ledger, clock, 1_000)
        await ledger.close()
        clock.advance(6_000, continuityID: "post-sleep-process")
        let restarted = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await restarted.snapshot()
        XCTAssertTrue(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.remainingRestMilliseconds, 4_000)
        XCTAssertEqual(snapshot.familyActualMilliseconds, 1_000)
        clock.advance(4_000)
        try await play(restarted, clock, 1_000)
        await restarted.close()
    }

    func testClockRecoveryBootChangeRejectsLargerMonotonicEvenWithMatchingWall() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        await ledger.close()
        clock.advance(900_000, continuityID: "after-reboot", bootSessionID: "different-boot")
        let restarted = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await restarted.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.clockRecoveryReason, .bootChanged)
        await restarted.close()
    }

    func testClockRecoveryMissingBootOnlyProvesSameProcess() async throws {
        let clock = TestLedgerClock(), store = TestLedgerCheckpoint(), url = try location()
        let base = clock.now()
        clock.set(LedgerClockSample(wallMilliseconds: base.wallMilliseconds,
            monotonicMilliseconds: base.monotonicMilliseconds, continuityID: base.continuityID,
            monotonicSource: base.monotonicSource))
        let ledger = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        clock.advance(1_000)
        let sameProcess = try await ledger.snapshot()
        XCTAssertTrue(sameProcess.clockIsTrusted)
        await ledger.close()
        clock.advance(1_000, continuityID: "other-process")
        let restarted = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await restarted.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.clockRecoveryReason, .bootIdentityUnavailable)
        await restarted.close()
    }

    func testClockRecoverySourceChangeCannotUseCoincidentalWallAgreement() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        clock.advance(1_000, monotonicSource: "dispatch-uptime-v1")
        let snapshot = try await ledger.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.clockRecoveryReason, .sourceChanged)
        await ledger.close()
    }

    func testClockRecoveryRejectsBothWallSelectedTimebaseAttacks() async throws {
        // U=10s, C=610s at anchor: forward-wall attack makes the wrong C delta
        // look plausible. Reverse attack starts at C and makes U appear plausible.
        let attacks: [(anchor: Int64, elapsed: Int64, wallDelta: Int64, currentC: Int64)] = [
            (10_000, 1_000, 601_000, 611_000),
            (610_000, 700_000, 100_000, 1_310_000)
        ]
        for attack in attacks {
            let (ledger, clock, store, url, _) = try await setup()
            let wall = clock.now().wallMilliseconds
            await ledger.close()
            try editPersistedState(url) { state in
                try removeClockProvenance(&state)
                for key in ["clockAnchor", "lastClock"] {
                    var sample = try XCTUnwrap(state[key] as? [String: Any])
                    sample["monotonicMilliseconds"] = attack.anchor
                    state[key] = sample
                }
            }
            clock.set(LedgerClockSample(wallMilliseconds: wall + attack.wallDelta,
                monotonicMilliseconds: attack.currentC, continuityID: "upgraded",
                monotonicSource: "mach-continuous-v1", bootSessionID: "test-boot"))
            let restarted = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let snapshot = try await restarted.snapshot()
            XCTAssertFalse(snapshot.clockIsTrusted, "actual elapsed \(attack.elapsed)")
            XCTAssertEqual(snapshot.clockRecoveryReason, .legacyContinuityUnverifiable)
            XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), String(wall))
            await expect(.clockUntrusted) {
                _ = try await restarted.reservePlayback(eventID: "attack", requestedMilliseconds: 1)
            }
            await restarted.close()
        }
    }

    func testClockRecoveryExplicitAnomaliesStayLatchedAfterWallCorrectionAndRestart() async throws {
        for (mono, wall, reason): (Int64, Int64, LedgerClockRecoveryReason) in [
            (1_000, 11_000, .wallDrift), (1_000, -9_000, .wallDrift),
            (-1, -1, .monotonicRollback)
        ] {
            let (ledger, clock, store, url, _) = try await setup()
            let base = clock.now()
            clock.advance(mono, wallDelta: wall)
            let anomaly = try await ledger.snapshot()
            XCTAssertFalse(anomaly.clockIsTrusted)
            XCTAssertEqual(anomaly.clockRecoveryReason, reason)
            await ledger.close()
            clock.set(LedgerClockSample(wallMilliseconds: base.wallMilliseconds + 20_000,
                monotonicMilliseconds: base.monotonicMilliseconds + 20_000, continuityID: "corrected-process",
                monotonicSource: base.monotonicSource, bootSessionID: base.bootSessionID))
            let restarted = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let corrected = try await restarted.snapshot()
            XCTAssertFalse(corrected.clockIsTrusted)
            XCTAssertEqual(corrected.clockRecoveryReason, reason)
            try await restarted.reanchorClock(credential: credential)
            let confirmed = try await restarted.snapshot()
            XCTAssertTrue(confirmed.clockIsTrusted)
            XCTAssertNil(confirmed.clockRecoveryReason)
            await restarted.close()
        }
    }

    func testClockRecoveryPreservesQuotaProfilesGrantsHistoryAndFullRest() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 10_000,
            continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, _, url, people) = try await setup(config: config)
        try await play(ledger, clock, 500)
        let yesterday = try await ledger.snapshot()
        try await ledger.requestFamilyRest()
        clock.advance(86_400_000)
        try await play(ledger, clock, 500)
        try await ledger.grantTemporaryBonus(1_000, credential: credential)
        let active = try await ledger.reservePlayback(eventID: "freeze-before-parent", requestedMilliseconds: 500)
        clock.advance(1_000, wallDelta: 86_401_000)
        let blocked = try await ledger.snapshot()
        XCTAssertEqual(blocked.remainingRestMilliseconds, 10_000)
        let logical = try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state")
        try await ledger.reanchorClock(credential: credential)
        let recovered = try await ledger.snapshot()
        XCTAssertTrue(recovered.clockIsTrusted)
        XCTAssertGreaterThan(recovered.day, blocked.day)
        XCTAssertEqual(recovered.configuration, config)
        XCTAssertEqual(recovered.profiles, blocked.profiles)
        XCTAssertEqual(recovered.activeViewerIDs, blocked.activeViewerIDs)
        XCTAssertEqual(recovered.personalActualMilliseconds, blocked.personalActualMilliseconds)
        XCTAssertEqual(recovered.familyActualMilliseconds, 500)
        XCTAssertEqual(recovered.familyFrozenMilliseconds, 500)
        XCTAssertEqual(recovered.continuousActualMilliseconds, blocked.continuousActualMilliseconds)
        XCTAssertEqual(recovered.continuousFrozenMilliseconds, blocked.continuousFrozenMilliseconds)
        XCTAssertEqual(recovered.frozenReservations, blocked.frozenReservations)
        XCTAssertEqual(recovered.grants.map(\.id), blocked.grants.map(\.id))
        for (effective, original) in zip(recovered.grants, blocked.grants) {
            XCTAssertEqual(effective.bonusMilliseconds, original.bonusMilliseconds)
            XCTAssertEqual(effective.viewerIDs, original.viewerIDs)
            XCTAssertLessThanOrEqual(effective.expiresAtLogicalWall, original.expiresAtLogicalWall)
        }
        let grantHistory = try await ledger.grantHistory()
        XCTAssertEqual(grantHistory, blocked.grants)
        XCTAssertEqual(recovered.parentalBonusMilliseconds, 1_000)
        XCTAssertEqual(recovered.remainingRestMilliseconds, 10_000)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), logical)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM child_daily_usage WHERE day=\(yesterday.day) AND profile_id='\(people[0].id.uuidString)'"), "500")
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: active.id) }
        clock.advance(10_000)
        let afterRest = try await ledger.snapshot()
        XCTAssertEqual(afterRest.familyActualMilliseconds, 500)
        XCTAssertEqual(afterRest.familyFrozenMilliseconds, 500)
        XCTAssertEqual(afterRest.remainingRestMilliseconds, 0)
        await ledger.close()
    }

    func testClockRecoveryPauseEndResumeAndRenewalNeverDoubleCharge() async throws {
        let (ledger, clock, store, url, people) = try await setup()
        try await play(ledger, clock, 700)
        let lost = try await ledger.reservePlayback(eventID: "old-lease", requestedMilliseconds: 1_000)
        await ledger.close()
        try editPersistedState(url) { state in
            state["clockTrusted"] = false
            try removeClockProvenance(&state)
        }
        clock.advance(10_000, continuityID: "upgrade")
        let recovered = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await recovered.reanchorClock(credential: credential)
        await expect(.leaseExpired) { _ = try await recovered.settlePlayback(leaseID: lost.id) }
        let first = try await recovered.reservePlayback(eventID: "new-play", requestedMilliseconds: 5_000)
        clock.advance(500) // paused
        try await recovered.setPlaybackActivity(leaseID: first.id, activity: .playing)
        clock.advance(1_000)
        try await recovered.setPlaybackActivity(leaseID: first.id, activity: .paused)
        clock.advance(500)
        let receipt = try await recovered.settlePlayback(leaseID: first.id)
        let repeated = try await recovered.settlePlayback(leaseID: first.id)
        XCTAssertEqual(receipt, repeated)
        XCTAssertEqual(receipt.actualMilliseconds, 1_000)
        let resumed = try await recovered.reservePlayback(eventID: "resume", requestedMilliseconds: 5_000)
        try await recovered.setPlaybackActivity(leaseID: resumed.id, activity: .playing)
        clock.advance(400)
        let renewed = try await recovered.renewPlayback(leaseID: resumed.id, requestedMilliseconds: 5_000)
        let retry = try await recovered.renewPlayback(leaseID: resumed.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(renewed, retry)
        clock.advance(600)
        let end = try await recovered.settlePlayback(leaseID: XCTUnwrap(renewed.nextLease).id)
        XCTAssertEqual(end.actualMilliseconds, 600)
        let snapshot = try await recovered.snapshot()
        XCTAssertEqual(snapshot.familyActualMilliseconds, 2_700)
        XCTAssertEqual(snapshot.personalActualMilliseconds[people[0].id], 2_700)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 1_000)
        XCTAssertEqual(snapshot.frozenReservations.count, 1)
        await recovered.close()
    }

    func testClockRecoveryInvalidSamplesFailClosedAndParentCannotConfirmThem() async throws {
        let base = TestLedgerClock().now()
        let invalid = [
            LedgerClockSample(wallMilliseconds: -1, monotonicMilliseconds: 10_000, continuityID: "p"),
            LedgerClockSample(wallMilliseconds: Int64.max, monotonicMilliseconds: 10_000, continuityID: "p"),
            LedgerClockSample(wallMilliseconds: base.wallMilliseconds, monotonicMilliseconds: -1, continuityID: "p"),
            LedgerClockSample(wallMilliseconds: base.wallMilliseconds, monotonicMilliseconds: Int64.max, continuityID: "p"),
            LedgerClockSample(wallMilliseconds: base.wallMilliseconds, monotonicMilliseconds: 10_000, continuityID: ""),
            LedgerClockSample(wallMilliseconds: base.wallMilliseconds, monotonicMilliseconds: 10_000, continuityID: "p", monotonicSource: ""),
            LedgerClockSample(wallMilliseconds: base.wallMilliseconds, monotonicMilliseconds: 10_000, continuityID: "p", bootSessionID: "")
        ]
        for sample in invalid {
            let (ledger, clock, store, url, _) = try await setup()
            clock.set(sample)
            let snapshot = try await ledger.snapshot()
            XCTAssertFalse(snapshot.clockIsTrusted)
            XCTAssertEqual(snapshot.clockRecoveryReason, .invalidSample)
            let checkpoint = try store.load()
            await expect(.clockUntrusted) { try await ledger.reanchorClock(credential: self.credential) }
            XCTAssertEqual(try store.load(), checkpoint)
            await ledger.close()
            XCTAssertEqual(try sql(url, "PRAGMA quick_check"), "ok")
        }
    }

    func testClockRecoveryBackupFalseWithoutReasonCannotAutoUnlockOrReturnAllowance() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 10_000,
            continuousLimitMilliseconds: 8_000, restMilliseconds: 1_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        try await play(ledger, clock, 1_000)
        _ = try await ledger.prepareRestoredBackup(minimumRevision: 1_000, credential: credential)
        await ledger.close()
        try editPersistedState(url) { state in state.removeValue(forKey: "clockRecoveryReason") }
        clock.advance(60_000, continuityID: "restored-process")
        let restored = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let blocked = try await restored.snapshot()
        XCTAssertFalse(blocked.clockIsTrusted)
        XCTAssertEqual(blocked.clockRecoveryReason, .restoredBackup)
        XCTAssertTrue(blocked.recoveryQuarantineActive)
        XCTAssertEqual(blocked.remainingRestMilliseconds, 1_000)
        XCTAssertEqual(blocked.familyFrozenMilliseconds, 9_000)
        try await restored.reanchorClock(credential: credential)
        let confirmed = try await restored.snapshot()
        XCTAssertTrue(confirmed.clockIsTrusted)
        XCTAssertNil(confirmed.clockRecoveryReason)
        XCTAssertTrue(confirmed.recoveryQuarantineActive)
        XCTAssertEqual(confirmed.familyActualMilliseconds, 1_000)
        XCTAssertEqual(confirmed.familyFrozenMilliseconds, 9_000)
        clock.advance(1_000)
        try await restored.grantDayExemption(credential: credential)
        await expect(.budgetExhausted) {
            _ = try await restored.reservePlayback(eventID: "still-quarantined", requestedMilliseconds: 1)
        }
        await restored.close()
        clock.advance(1_000, continuityID: "restored-next-process")
        let following = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let persisted = try await following.snapshot()
        XCTAssertTrue(persisted.clockIsTrusted)
        XCTAssertTrue(persisted.recoveryQuarantineActive)
        XCTAssertEqual(persisted.familyFrozenMilliseconds, 9_000)
        await following.close()
    }

    func testClockRecoveryMalformedProvenanceTypesNeverDecodeAsMissing() throws {
        for key in ["monotonicSource", "bootSessionID"] {
            for badValue: Any in [42, true, ["untrusted"], ["id": "untrusted"]] {
                var payload: [String: Any] = ["wallMilliseconds": 1_000,
                    "monotonicMilliseconds": 10, "continuityID": "legacy"]
                payload[key] = badValue
                let data = try JSONSerialization.data(withJSONObject: payload)
                XCTAssertThrowsError(try JSONDecoder().decode(LedgerClockSample.self, from: data))
            }
        }
    }

    private let observedKernelBootMarker = "kern-boottime-v1:1794110628:348481"
    private let driftedKernelBootMarker = "kern-boottime-v1:1794110628:456546"

    func testKernelBootDriftObserved108MillisecondsAfterHoursRemainsTrustedAcrossRestart() async throws {
        let (ledger, clock, store, url, people) = try await setup()
        clock.advance(0, bootSessionID: observedKernelBootMarker)
        try await ledger.reanchorClock(credential: credential)
        try await play(ledger, clock, 700)
        let anchor = try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state")
        await ledger.close()
        clock.advance(3 * 3_600_000, continuityID: "hours-later", bootSessionID: driftedKernelBootMarker)
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertTrue(state.clockIsTrusted)
        XCTAssertNil(state.clockRecoveryReason)
        XCTAssertEqual(state.familyActualMilliseconds, 700)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 700)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state"), anchor)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM parental_audit_logs WHERE operation='reanchorClock'"), "1")
        try await play(reopened, clock, 300)
        await reopened.close()
    }

    func testKernelBootDriftWithinTwoSecondsNeverRoundsOrExpandsExistingBudget() async throws {
        for drift: Int64 in [2_000, 108_065, 1_900_000, 2_000_000, 2_000_001, -1_900_000, -2_000_001] {
            let (ledger, clock, _, _, _) = try await setup()
            clock.advance(0, bootSessionID: observedKernelBootMarker)
            try await ledger.reanchorClock(credential: credential)
            let micros = 1_794_110_628_348_481 + drift
            let changed = "kern-boottime-v1:\(micros / 1_000_000):\(micros % 1_000_000)"
            clock.advance(3_600_000, bootSessionID: changed)
            let state = try await ledger.snapshot()
            XCTAssertEqual(state.clockIsTrusted, abs(drift) <= 2_000_000, "drift=\(drift)us")
            XCTAssertEqual(state.clockRecoveryReason, abs(drift) <= 2_000_000 ? nil : .bootChanged)
            await ledger.close()
        }
    }

    func testKernelBootDriftRepeatedOneSecondProcessChangesAccumulateAgainstFixedAnchor() async throws {
        let (initial, clock, store, url, _) = try await setup()
        clock.advance(0, bootSessionID: observedKernelBootMarker)
        try await initial.reanchorClock(credential: credential)
        let anchor = try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state")
        var ledger = initial
        for index in 1...3 {
            await ledger.close()
            clock.advance(10_000, continuityID: "drift-process-\(index)",
                bootSessionID: "kern-boottime-v1:\(1_794_110_628 + index):348481")
            ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let state = try await ledger.snapshot()
            XCTAssertEqual(state.clockIsTrusted, index <= 2)
            XCTAssertEqual(state.clockRecoveryReason, index <= 2 ? nil : .bootChanged)
            XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state"), anchor)
        }
        await expect(.clockUntrusted) { _ = try await ledger.reservePlayback(eventID: "over-cumulative-budget", requestedMilliseconds: 1) }
        await ledger.close()
        // A newly observed out-of-budget jump remains latched even if changed back.
        clock.advance(10_000, continuityID: "marker-corrected", bootSessionID: observedKernelBootMarker)
        let corrected = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await corrected.snapshot()
        XCTAssertFalse(state.clockIsTrusted)
        XCTAssertEqual(state.clockRecoveryReason, .bootChanged)
        await corrected.close()
    }

    func testKernelBootDriftLegacyBootChangedRecoversWithoutRefundingLeaseRestOrUnknownElapsed() async throws {
        for withActiveLease in [false, true] {
            let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
            let (ledger, clock, store, url, _) = try await setup(config: config)
            clock.advance(0, bootSessionID: observedKernelBootMarker)
            try await ledger.reanchorClock(credential: credential)
            try await play(ledger, clock, withActiveLease ? 500 : 1_000)
            let active = withActiveLease
                ? try await ledger.reservePlayback(eventID: "legacy-boot-active", requestedMilliseconds: 500) : nil
            let anchor = try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state")
            let logical = try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state")
            await ledger.close()
            try editPersistedState(url) { state in
                state["clockTrusted"] = false
                state["clockRecoveryReason"] = "bootChanged"
                state.removeValue(forKey: "kernelBootChangeRequiresParent") // build12 shape
            }
            clock.advance(3 * 3_600_000, continuityID: "legacy-boot-recovered", bootSessionID: driftedKernelBootMarker)
            let recovered = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let state = try await recovered.snapshot()
            XCTAssertTrue(state.clockIsTrusted)
            XCTAssertNil(state.clockRecoveryReason)
            XCTAssertEqual(state.familyActualMilliseconds, withActiveLease ? 500 : 1_000)
            XCTAssertEqual(state.familyFrozenMilliseconds, withActiveLease ? 500 : 0)
            XCTAssertEqual(state.remainingRestMilliseconds, 10_000)
            XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.logicalWall') FROM ledger_state"), logical)
            XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state"), anchor)
            if let active { await expect(.leaseExpired) { _ = try await recovered.settlePlayback(leaseID: active.id) } }
            await expect(.resting) { _ = try await recovered.reservePlayback(eventID: "must-still-rest", requestedMilliseconds: 1) }
            clock.advance(1_000)
            let waiting = try await recovered.snapshot()
            XCTAssertEqual(waiting.remainingRestMilliseconds, 9_000)
            await recovered.close()
        }
    }

    func testKernelBootDriftLegacyRecoveryStillRequiresBothAnchorsAndAllWallIntervals() async throws {
        for corrupted in ["clockAnchor", "lastClock"] {
            let (ledger, clock, store, url, _) = try await setup()
            clock.advance(0, bootSessionID: observedKernelBootMarker)
            try await ledger.reanchorClock(credential: credential)
            clock.advance(10_000)
            _ = try await ledger.snapshot()
            await ledger.close()
            try editPersistedState(url) { state in
                state["clockTrusted"] = false; state["clockRecoveryReason"] = "bootChanged"
                state.removeValue(forKey: "kernelBootChangeRequiresParent")
                var sample = try XCTUnwrap(state[corrupted] as? [String: Any])
                sample["wallMilliseconds"] = (try XCTUnwrap(sample["wallMilliseconds"] as? NSNumber)).int64Value + 3_000
                state[corrupted] = sample
            }
            clock.advance(10_000, continuityID: "bad-prior-wall", bootSessionID: driftedKernelBootMarker)
            let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let state = try await reopened.snapshot()
            XCTAssertFalse(state.clockIsTrusted)
            await expect(.clockUntrusted) { _ = try await reopened.reservePlayback(eventID: "bad-interval", requestedMilliseconds: 1) }
            await reopened.close()
        }
    }

    func testKernelBootDriftDoesNotRelaxWallBudgetMonotonicResetOrSourceIdentity() async throws {
        for scenario in ["wall-forward", "wall-backward", "reboot", "source"] {
            let (ledger, clock, _, _, _) = try await setup()
            clock.advance(0, bootSessionID: observedKernelBootMarker)
            try await ledger.reanchorClock(credential: credential)
            let initial = clock.now()
            if scenario == "reboot" {
                clock.set(LedgerClockSample(wallMilliseconds: initial.wallMilliseconds + 10_000,
                    monotonicMilliseconds: 1, continuityID: "real-reboot", monotonicSource: initial.monotonicSource,
                    bootSessionID: driftedKernelBootMarker))
            } else {
                clock.advance(10_000, wallDelta: scenario == "wall-forward" ? 12_001 : (scenario == "wall-backward" ? 7_999 : 10_000),
                    monotonicSource: scenario == "source" ? "dispatch-uptime-v1" : nil, bootSessionID: driftedKernelBootMarker)
            }
            let state = try await ledger.snapshot()
            XCTAssertFalse(state.clockIsTrusted, scenario)
            await expect(.clockUntrusted) { _ = try await ledger.reservePlayback(eventID: "no-\(scenario)", requestedMilliseconds: 1) }
            await ledger.close()
        }
    }

    func testKernelBootDriftNeverUnlocksChangedUUIDOrMalformedKernelMarker() async throws {
        let uuid = "00000000-0000-4000-8000-000000000001"
        let changedUUID = "00000000-0000-4000-8000-000000000002"
        for (original, changed) in [(uuid, changedUUID), (observedKernelBootMarker, "kern-boottime-v1:1794110628:0348481"),
                                    (observedKernelBootMarker, "kern-boottime-v1:1794110628:1000000"),
                                    (observedKernelBootMarker, "kern-boottime-v1:1794110628:348481:extra"),
                                    (observedKernelBootMarker, "kern-boottime-v2:1794110628:348481")] {
            let (ledger, clock, store, url, _) = try await setup()
            clock.advance(0, bootSessionID: original)
            try await ledger.reanchorClock(credential: credential)
            await ledger.close()
            try editPersistedState(url) { state in
                state["clockTrusted"] = false; state["clockRecoveryReason"] = "bootChanged"
                state.removeValue(forKey: "kernelBootChangeRequiresParent")
            }
            clock.advance(10_000, continuityID: "wrong-identity", bootSessionID: changed)
            let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let state = try await reopened.snapshot()
            XCTAssertFalse(state.clockIsTrusted)
            XCTAssertEqual(state.clockRecoveryReason, .bootChanged)
            await reopened.close()
        }
    }

    func testKernelBootDriftDoesNotAutoRecoverAnyQuarantinedBootChangedState() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 10_000, continuousLimitMilliseconds: 8_000, restMilliseconds: 1_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        clock.advance(0, bootSessionID: observedKernelBootMarker)
        try await ledger.reanchorClock(credential: credential)
        try await play(ledger, clock, 1_000)
        _ = try await ledger.prepareRestoredBackup(minimumRevision: 1_000, credential: credential)
        try await ledger.reanchorClock(credential: credential)
        await ledger.close()
        try editPersistedState(url) { state in
            state["clockTrusted"] = false; state["clockRecoveryReason"] = "bootChanged"
            state.removeValue(forKey: "kernelBootChangeRequiresParent")
        }
        clock.advance(10_000, continuityID: "confirmed-backup-drift", bootSessionID: driftedKernelBootMarker)
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertFalse(state.clockIsTrusted)
        XCTAssertEqual(state.clockRecoveryReason, .bootChanged)
        XCTAssertTrue(state.recoveryQuarantineActive)
        XCTAssertEqual(state.familyActualMilliseconds, 1_000)
        XCTAssertEqual(state.familyFrozenMilliseconds, 9_000)
        XCTAssertEqual(state.remainingRestMilliseconds, 1_000)
        clock.advance(1_000)
        await expect(.clockUntrusted) { _ = try await reopened.reservePlayback(eventID: "quarantine-not-refunded", requestedMilliseconds: 1) }
        await reopened.close()
    }

    func testKernelBootDriftExactBuild12SamplesRecoverOnlyOnceWithoutMovingAnchor() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        clock.set(LedgerClockSample(wallMilliseconds: 1_794_121_974_140,
            monotonicMilliseconds: 11_351_594, continuityID: "build12-anchor",
            monotonicSource: "mach-continuous-v1", bootSessionID: observedKernelBootMarker))
        try await ledger.reanchorClock(credential: credential)
        let anchor = try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state")
        await ledger.close()
        try editPersistedState(url) { state in
            state["clockTrusted"] = false; state["clockRecoveryReason"] = "bootChanged"
            state.removeValue(forKey: "kernelBootChangeRequiresParent")
        }
        clock.set(LedgerClockSample(wallMilliseconds: 1_794_130_424_256,
            monotonicMilliseconds: 19_801_770, continuityID: "build12-current",
            monotonicSource: "mach-continuous-v1", bootSessionID: driftedKernelBootMarker))
        XCTAssertEqual((1_794_130_424_256 - 1_794_121_974_140) - (19_801_770 - 11_351_594), -60)
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertTrue(state.clockIsTrusted)
        XCTAssertNil(state.clockRecoveryReason)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.clockAnchor') FROM ledger_state"), anchor)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM parental_audit_logs WHERE operation='reanchorClock'"), "1")
        let repeated = try await reopened.snapshot()
        XCTAssertEqual(state.checkpoint, repeated.checkpoint)
        await reopened.close()
    }

    func testKernelBootDriftFailedLegacyCompatibilityAttemptRemainsLatchedAfterCorrection() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        clock.advance(0, bootSessionID: observedKernelBootMarker)
        try await ledger.reanchorClock(credential: credential)
        let base = clock.now()
        await ledger.close()
        try editPersistedState(url) { state in
            state["clockTrusted"] = false; state["clockRecoveryReason"] = "bootChanged"
            state.removeValue(forKey: "kernelBootChangeRequiresParent")
        }
        clock.advance(10_000, wallDelta: 13_000, continuityID: "bad-first-attempt", bootSessionID: driftedKernelBootMarker)
        let failed = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let blocked = try await failed.snapshot()
        XCTAssertFalse(blocked.clockIsTrusted)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.kernelBootChangeRequiresParent') FROM ledger_state"), "1")
        await failed.close()
        clock.set(LedgerClockSample(wallMilliseconds: base.wallMilliseconds + 20_000,
            monotonicMilliseconds: base.monotonicMilliseconds + 20_000, continuityID: "corrected-after-failed-attempt",
            monotonicSource: base.monotonicSource, bootSessionID: driftedKernelBootMarker))
        let corrected = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await corrected.snapshot()
        XCTAssertFalse(state.clockIsTrusted)
        try await corrected.reanchorClock(credential: credential)
        let confirmed = try await corrected.snapshot()
        XCTAssertTrue(confirmed.clockIsTrusted)
        XCTAssertEqual(try sql(url, "SELECT json_extract(payload,'$.kernelBootChangeRequiresParent') FROM ledger_state"), "0")
        await corrected.close()
    }

    func testClockRecoveryKernelBootTimeFallbackIsExactValidatedAndUUIDIsPreferred() throws {
        let uuid = UUID().uuidString
        XCTAssertEqual(SystemLedgerClock.bootSessionID(bootUUID: uuid) {
            XCTFail("A readable boot UUID must not need a fallback")
            return nil
        }, uuid)
        let marker = SystemLedgerClock.bootSessionID(bootUUID: nil) { (1_788_534_785, 591_803) }
        XCTAssertEqual(marker, "kern-boottime-v1:1788534785:591803")
        XCTAssertEqual(SystemLedgerClock.bootSessionID(bootUUID: "invalid") { (1_788_534_785, 591_803) }, marker)
        XCTAssertNotEqual(SystemLedgerClock.bootSessionID(bootUUID: nil) { (1_788_534_785, 591_804) }, marker)
        XCTAssertNil(SystemLedgerClock.bootSessionID(bootUUID: nil) { nil })
        for time: (Int64, Int64) in [(0, 1), (-1, 0), (Int64.max, 0), (1, -1), (1, 1_000_000)] {
            XCTAssertNil(SystemLedgerClock.bootSessionID(bootUUID: nil) { time })
        }
    }

    func testClockRecoverySystemReadsBootMarkerOnEverySample() throws {
        let provider = TestLedgerClock()
        provider.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591803")
        let system = SystemLedgerClock(bootSessionIDProvider: { provider.now().bootSessionID })
        let first = system.now()
        provider.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591804")
        let next = system.now()
        XCTAssertEqual(first.bootSessionID, "kern-boottime-v1:1788534785:591803")
        XCTAssertEqual(next.bootSessionID, "kern-boottime-v1:1788534785:591804")
        XCTAssertEqual(first.continuityID, next.continuityID)
        XCTAssertEqual(first.monotonicSource, next.monotonicSource)
    }

    func testClockRecoveryKernelBootTimeSurvivesSleepAndRepeatedProcessRestarts() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (initial, clock, store, url, _) = try await setup(config: config)
        clock.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591803")
        try await initial.reanchorClock(credential: credential)
        try await play(initial, clock, 1_000)
        var ledger = initial
        for index in 1...3 {
            await ledger.close()
            clock.advance(2_000, continuityID: "fallback-process-\(index)")
            ledger = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let snapshot = try await ledger.snapshot()
            XCTAssertTrue(snapshot.clockIsTrusted)
            XCTAssertNil(snapshot.clockRecoveryReason)
            XCTAssertEqual(snapshot.remainingRestMilliseconds, 10_000 - Int64(index) * 2_000)
        }
        clock.advance(4_000)
        try await play(ledger, clock, 1_000)
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM parental_audit_logs WHERE operation='reanchorClock'"), "1")
        await ledger.close()
    }

    func testClockRecoveryKernelBootTimeOverBudgetChangeAndRebootRequireParent() async throws {
        for changed in ["kern-boottime-v1:1788534787:591804", "kern-boottime-v1:1790000000:1"] {
            let (ledger, clock, store, url, _) = try await setup()
            clock.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591803")
            try await ledger.reanchorClock(credential: credential)
            await ledger.close()
            // Even equal wall/mono deltas and a larger mono cannot justify an
            // out-of-budget marker change (2 seconds + 1 us, or a different boot).
            clock.advance(100_000, continuityID: "changed-process", bootSessionID: changed)
            let restarted = try UsageLedger(databaseURL: url, clock: clock,
                checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            let snapshot = try await restarted.snapshot()
            XCTAssertFalse(snapshot.clockIsTrusted)
            XCTAssertEqual(snapshot.clockRecoveryReason, .bootChanged)
            try await restarted.reanchorClock(credential: credential)
            let confirmed = try await restarted.snapshot()
            XCTAssertTrue(confirmed.clockIsTrusted)
            await restarted.close()
        }
    }

    func testClockRecoveryFallbackDoesNotRelaxWallDriftOrMonotonicChecks() async throws {
        for (mono, wall, reason): (Int64, Int64, LedgerClockRecoveryReason) in [
            (1_000, 11_000, .wallDrift), (1_000, -9_000, .wallDrift), (-1, -1, .monotonicRollback)
        ] {
            let (ledger, clock, _, _, _) = try await setup()
            clock.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591803")
            try await ledger.reanchorClock(credential: credential)
            clock.advance(mono, wallDelta: wall)
            let snapshot = try await ledger.snapshot()
            XCTAssertFalse(snapshot.clockIsTrusted)
            XCTAssertEqual(snapshot.clockRecoveryReason, reason)
            await ledger.close()
        }
    }

    func testClockRecoveryBootIdentityMethodChangeIsNotSameBootProof() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        clock.advance(0, bootSessionID: "kern-boottime-v1:1788534785:591803")
        try await ledger.reanchorClock(credential: credential)
        clock.advance(1_000, bootSessionID: UUID().uuidString)
        let snapshot = try await ledger.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertEqual(snapshot.clockRecoveryReason, .bootChanged)
        await ledger.close()
    }

    func testClockRecoverySystemSamplesRoundTripAndLegacyInitializerDecodes() throws {
        let clock = SystemLedgerClock()
        let sample = clock.now(), second = SystemLedgerClock().now()
        XCTAssertEqual(sample.monotonicSource, "mach-continuous-v1")
        XCTAssertNotNil(sample.bootSessionID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(sample.bootSessionID, second.bootSessionID)
        XCTAssertEqual(sample.monotonicSource, second.monotonicSource)
        XCTAssertEqual(sample.continuityID, second.continuityID)
        XCTAssertGreaterThanOrEqual(second.monotonicMilliseconds, sample.monotonicMilliseconds)
        XCTAssertEqual(try JSONDecoder().decode(LedgerClockSample.self, from: JSONEncoder().encode(sample)), sample)
        let legacy = Data("{\"wallMilliseconds\":1000,\"monotonicMilliseconds\":10,\"continuityID\":\"legacy\"}".utf8)
        let decoded = try JSONDecoder().decode(LedgerClockSample.self, from: legacy)
        XCTAssertNil(decoded.monotonicSource)
        XCTAssertNil(decoded.bootSessionID)
        XCTAssertEqual(decoded, LedgerClockSample(wallMilliseconds: 1_000, monotonicMilliseconds: 10, continuityID: "legacy"))
    }

    // MARK: Schedules, personal cap and profile deletion

    private func scheduleSetup(_ clock: TestLedgerClock, isoStart: String,
                               schedule: FamilySchedule) async throws -> (UsageLedger, ViewerProfile) {
        let url = try location()
        let store = TestLedgerCheckpoint()
        clock.setWall(Int64(ISO8601DateFormatter().date(from: isoStart)!.timeIntervalSince1970 * 1_000))
        let ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await ledger.configureFamily(FamilyConfiguration(schedule: schedule), credential: credential)
        let child = profile("A")
        try await ledger.upsertProfile(child, credential: credential)
        try await ledger.selectViewers([child.id], credential: credential)
        return (ledger, child)
    }

    // A confirmed clock can be days ahead of the retained accounting timeline.
    // Calendar policy must use the former without resetting the latter's debits.
    func testRecoveredScheduleUsesConfirmedSundayNotPreservedFridayNight() async throws {
        let clock = TestLedgerClock()
        let (ledger, child) = try await scheduleSetup(clock, isoStart: "2026-11-05T19:12:30Z", schedule: FamilySchedule())
        try await play(ledger, clock, 700)
        var config = try await ledger.snapshot().configuration
        config.schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 1080, endMinuteOfDay: 1275),
                                         weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))
        try await ledger.configureFamily(config, credential: credential)
        let before = try await ledger.snapshot()
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T07:15:30Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        let restored = try await ledger.snapshot()
        XCTAssertTrue(restored.clockIsTrusted)
        XCTAssertEqual(restored.day, 20261108)
        XCTAssertEqual(restored.familyActualMilliseconds, 700)
        XCTAssertEqual(restored.familyCarriedActualMilliseconds, 700)
        XCTAssertEqual(restored.profiles, before.profiles)
        XCTAssertEqual(restored.configuration, config)
        let lease = try await ledger.reservePlayback(eventID: "confirmed-sunday", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(600)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .paused)
        clock.advance(200)
        let receipt = try await ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(receipt.actualMilliseconds, 600)
        let duplicate = try await ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(duplicate, receipt)
        let after = try await ledger.snapshot()
        XCTAssertEqual(after.familyActualMilliseconds, 1_300)
        XCTAssertEqual(after.personalActualMilliseconds[child.id], 1_300)
        XCTAssertEqual(after.familyFrozenMilliseconds, 0)
        await ledger.close()
    }

    func testRecoveredScheduleSavedChangeAppliesWithoutAnotherClockConfirmation() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 900))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-05T19:12:30Z", schedule: schedule)
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T07:15:30Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        await expect(.scheduleBlocked) {
            _ = try await ledger.reservePlayback(eventID: "closed-before-edit", requestedMilliseconds: 1_000)
        }
        var config = try await ledger.snapshot().configuration
        config.schedule?.weekend = DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200)
        try await ledger.configureFamily(config, credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "open-after-edit", requestedMilliseconds: 1_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        await ledger.close()
    }

    func testRecoveredScheduleCannotUseOldAllowedHourAfterRealWindowCloses() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200),
                                      weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T01:00:00Z", schedule: schedule)
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T12:01:00Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        await expect(.scheduleBlocked) {
            _ = try await ledger.reservePlayback(eventID: "real-window-closed", requestedMilliseconds: 1_000)
        }
        await ledger.close()
    }

    func testRecoveredScheduleCapsAtActualMidnightThenUsesNewWeekday() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200),
                                      weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1440))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T02:00:00Z", schedule: schedule)
        let before = try await ledger.snapshot()
        XCTAssertEqual(before.day, 20261106)
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T15:59:58Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "actual-midnight", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 2_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(2_000)
        let renewal = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(renewal.receipt.actualMilliseconds, 2_000)
        XCTAssertNil(renewal.nextLease)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.day, 20261109, "the next proven civil midnight resets exactly once")
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        XCTAssertEqual(state.continuousActualMilliseconds, 2_000)
        XCTAssertEqual(renewal.receipt.day, 20261108)
        let report = try await ledger.report(lastDays: 7)
        XCTAssertEqual(report.days.first { $0.day == 20261108 }?.familyActualMilliseconds, 2_000)
        await ledger.close()
    }

    func testRecoveredScheduleDoesNotTreatDurationClockMidnightAsCalendarBoundary() async throws {
        let clock = TestLedgerClock()
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T15:59:58Z", schedule: FamilySchedule())
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T07:00:00Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "accounting-midnight", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 5_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(5_000)
        let receipt = try await ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(receipt.day, 20261108)
        XCTAssertEqual(receipt.actualMilliseconds, 5_000)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.familyActualMilliseconds, 5_000)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 0)
        await ledger.close()
    }

    func testRecoveredScheduleBedtimeUsesActualTimeAndCapsRenewal() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(bedtimeStartMinute: 1320, bedtimeEndMinute: 420)
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T02:00:00Z", schedule: schedule)
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T13:59:58Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "actual-bedtime", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 2_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(2_000)
        let renewal = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertNil(renewal.nextLease)
        XCTAssertEqual(renewal.receipt.actualMilliseconds, 2_000)
        await ledger.close()
    }

    func testRecoveredScheduleRealHouseholdRulesStillRequireQuiz() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1275),
                                      weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-05T19:12:30Z", schedule: schedule)
        var config = try await ledger.snapshot().configuration
        config.continuousLimitMilliseconds = 300_000
        config.quizRules = QuizRules(questionsPerRound: 5, passRatio: 0.7, rewardMinutes: 15,
            personalDailyRewards: 3, familyDailyRewards: 6, quizBeforeFirstWatch: true, quizAfterRest: true)
        try await ledger.configureFamily(config, credential: credential)
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T07:15:30Z")!.timeIntervalSince1970 * 1_000))
        try await ledger.reanchorClock(credential: credential)
        await expect(.quizRequired) {
            _ = try await ledger.reservePlayback(eventID: "schedule-passes-quiz-remains", requestedMilliseconds: 1_000)
        }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.configuration, config)
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertNil(state.activeLease)
        await ledger.close()
    }

    func testRecoveredScheduleDoesNotClearBackupIsolationInAllowedWindow() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-05T19:12:30Z", schedule: schedule)
        let before = try await ledger.snapshot()
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-08T07:15:30Z")!.timeIntervalSince1970 * 1_000))
        _ = try await ledger.prepareRestoredBackup(minimumRevision: before.checkpoint.revision, credential: credential)
        try await ledger.reanchorClock(credential: credential)
        let state = try await ledger.snapshot()
        XCTAssertTrue(state.clockIsTrusted)
        XCTAssertTrue(state.recoveryQuarantineActive)
        XCTAssertEqual(state.configuration, before.configuration)
        XCTAssertEqual(state.profiles, before.profiles)
        clock.advance(state.remainingRestMilliseconds)
        await expect(.budgetExhausted) {
            _ = try await ledger.reservePlayback(eventID: "calendar-cannot-unfreeze", requestedMilliseconds: 1_000)
        }
        await ledger.close()
    }

    func testScheduleBlocksOutsideWeekdayWindowCapsAtEdgeAndDiffersOnWeekend() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 600, endMinuteOfDay: 720),
                                      weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 720))
        // Friday 2026-11-06 09:00 local: outside the 10:00–12:00 weekday window.
        let (fridayMorning, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T01:00:00Z", schedule: schedule)
        await expect(.scheduleBlocked) { _ = try await fridayMorning.reservePlayback(eventID: "early", requestedMilliseconds: 1_000) }
        await fridayMorning.close()

        // Friday 10:10 local: inside; the 5s lease cap binds, not the window edge.
        let (fridayInside, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T02:10:00Z", schedule: schedule)
        let inside = try await fridayInside.reservePlayback(eventID: "inside", requestedMilliseconds: 5_000)
        XCTAssertEqual(inside.reservedMilliseconds, 5_000)
        await fridayInside.close()

        // Friday 11:59:56 local: only 4 seconds to the window edge; the lease may
        // not straddle it, so the reservation is capped below the requested 5s.
        let (fridayEdge, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T03:59:56Z", schedule: schedule)
        let edge = try await fridayEdge.reservePlayback(eventID: "edge", requestedMilliseconds: 5_000)
        XCTAssertEqual(edge.reservedMilliseconds, 4_000)
        await fridayEdge.close()

        // Friday 12:01 local: window closed again.
        let (fridayNoon, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T04:01:00Z", schedule: schedule)
        await expect(.scheduleBlocked) { _ = try await fridayNoon.reservePlayback(eventID: "noon", requestedMilliseconds: 1_000) }
        await fridayNoon.close()

        // Saturday 09:00 local: the weekend window (08:00–12:00) allows it.
        let (saturday, _) = try await scheduleSetup(clock, isoStart: "2026-11-07T01:00:00Z", schedule: schedule)
        let weekend = try await saturday.reservePlayback(eventID: "weekend", requestedMilliseconds: 5_000)
        XCTAssertEqual(weekend.reservedMilliseconds, 5_000)
        await saturday.close()
    }

    func testBedtimeWindowWrapsMidnightAndBlocksCrossing() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(bedtimeStartMinute: 1320, bedtimeEndMinute: 420)
        // Friday 09:00 local: between 07:00 and 22:00 → allowed.
        let (morning, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T01:00:00Z", schedule: schedule)
        let allowed = try await morning.reservePlayback(eventID: "day", requestedMilliseconds: 5_000)
        XCTAssertEqual(allowed.reservedMilliseconds, 5_000)
        await morning.close()

        // Friday 21:59:56 local: four seconds until bedtime; lease capped, never straddles.
        let (bedtimeEdge, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T13:59:56Z", schedule: schedule)
        let edge = try await bedtimeEdge.reservePlayback(eventID: "bededge", requestedMilliseconds: 5_000)
        XCTAssertEqual(edge.reservedMilliseconds, 4_000)
        await bedtimeEdge.close()

        // Friday 22:30 local: inside the bedtime block.
        let (night, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T14:30:00Z", schedule: schedule)
        await expect(.scheduleBlocked) { _ = try await night.reservePlayback(eventID: "night", requestedMilliseconds: 1_000) }
        await night.close()

        // Saturday 00:00 local: still inside the wrapped bedtime block.
        let (midnight, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T16:00:00Z", schedule: schedule)
        await expect(.scheduleBlocked) { _ = try await midnight.reservePlayback(eventID: "mid", requestedMilliseconds: 1_000) }
        await midnight.close()
    }

    func testPersonalLimitAboveFamilyTotalIsAcceptedButNeverBypassesFamilyCap() async throws {
        let (ledger, _, _, _, _) = try await setup()
        // A pointless-but-harmless personal total: the shared family cap binds at
        // reserve time regardless; the parental UI keeps pickers within the family.
        let oversized = profile("Big", limit: 8_000_000)
        try await ledger.upsertProfile(oversized, credential: credential)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.personalActualMilliseconds[oversized.id], 0)
        await ledger.close()
    }

    func testDeleteProfileKeepsHistoryAndRequiresAuthorization() async throws {
        let (ledger, clock, _, url, people) = try await setup()
        try await play(ledger, clock, 500)
        await expect(.unauthorized) { try await ledger.deleteProfile(people[1].id, credential: Data()) }
        try await ledger.deleteProfile(people[1].id, credential: credential)
        var state = try await ledger.snapshot()
        XCTAssertEqual(state.profiles.count, 1)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 500)
        // History projections keep every profile row, including a deleted one at 0.
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM child_daily_usage WHERE profile_id='\(people[1].id.uuidString)' AND day=\(state.day)"), "0")
        await expect(.invalidInput("unknown or disabled viewer")) {
            try await ledger.selectViewers([people[1].id], credential: self.credential)
        }
        // An active lease blocks deletion; the selected sole viewer can be removed
        // only once nothing is playing, leaving an explicit no-viewers state.
        let lease = try await ledger.reservePlayback(eventID: "delete-guard", requestedMilliseconds: 1_000)
        await expect(.leaseAlreadyActive) { try await ledger.deleteProfile(people[0].id, credential: self.credential) }
        try await ledger.settlePlayback(leaseID: lease.id)
        try await ledger.deleteProfile(people[0].id, credential: credential)
        state = try await ledger.snapshot()
        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertEqual(state.familyActualMilliseconds, 500)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=\(state.day)"), "500")
        await expect(.noActiveViewers) { _ = try await ledger.reservePlayback(eventID: "empty", requestedMilliseconds: 1_000) }
        await ledger.close()
    }

    // MARK: First-child auto selection

    /// The first enabled child becomes the initial viewer inside the same
    /// upsert; an existing choice is never overridden and a later or disabled
    /// save never re-selects.
    func testFirstEnabledChildAutoBecomesViewerAndNeverOverrides() async throws {
        let url = try location(); let clock = TestLedgerClock(); let store = TestLedgerCheckpoint()
        let ledger = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await ledger.configureFamily(FamilyConfiguration(), credential: credential)
        // No viewer has ever been chosen: the first enabled save selects it.
        let first = profile("First")
        try await ledger.upsertProfile(first, credential: credential)
        var state = try await ledger.snapshot()
        XCTAssertEqual(state.activeViewerIDs, [first.id])
        // A second child does not silently change the current viewer.
        let second = profile("Second")
        try await ledger.upsertProfile(second, credential: credential)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.activeViewerIDs, [first.id])
        // Disabling the non-viewer child changes nothing either.
        var disabledSecond = second
        disabledSecond.isEnabled = false
        try await ledger.upsertProfile(disabledSecond, credential: credential)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.activeViewerIDs, [first.id])
        // An explicit selection is honored and stays after further edits.
        try await ledger.selectViewers([first.id], credential: credential)
        var editedSecond = second
        editedSecond.displayName = "Second edited"
        try await ledger.upsertProfile(editedSecond, credential: credential)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.activeViewerIDs, [first.id])
        await ledger.close()
    }

    // MARK: Temporary parental relief

    func testBonusExtendsFamilyAndPersonalCapsAndIsAudited() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 60_000,
                                         continuousLimitMilliseconds: 600_000)
        let (ledger, clock, _, url, people) = try await setup(config: config)
        try await play(ledger, clock, 60_000)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "cap", requestedMilliseconds: 1_000) }
        await expect(.unauthorized) { try await ledger.grantTemporaryBonus(1_000, credential: Data()) }
        try await ledger.grantTemporaryBonus(30_000, credential: credential, note: "movie night")
        try await play(ledger, clock, 30_000)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 90_000)
        XCTAssertEqual(state.familyBonusMilliseconds, 30_000)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 90_000)
        XCTAssertEqual(state.grants.count, 1)
        XCTAssertEqual(state.grants[0].kind, .bonusTime)
        XCTAssertEqual(state.grants[0].viewerIDs, [people[0].id])
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM parental_audit_logs WHERE operation='temporaryOverride'"), "1")
        await ledger.close()
    }

    func testDayExemptionBypassesScheduleAndCapsUntilDayEnd() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 600, endMinuteOfDay: 720),
                                      weekend: DailyScheduleWindow(startMinuteOfDay: 600, endMinuteOfDay: 720))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T01:00:00Z", schedule: schedule)
        await expect(.scheduleBlocked) { _ = try await ledger.reservePlayback(eventID: "blocked", requestedMilliseconds: 1_000) }
        try await ledger.grantDayExemption(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "exempt", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 5_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(5_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        var state = try await ledger.snapshot()
        XCTAssertTrue(state.dayExemptionActive)
        XCTAssertEqual(state.grants.first?.kind, .dayExemption)
        // The exemption ends with the local day; the schedule binds again afterwards.
        clock.advance(86_400_000)
        state = try await ledger.snapshot()
        XCTAssertFalse(state.dayExemptionActive)
        await expect(.scheduleBlocked) { _ = try await ledger.reservePlayback(eventID: "again", requestedMilliseconds: 1_000) }
        await ledger.close()
    }

    func testQuizSkipGrantExpiresWithTheDay() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        try await ledger.grantQuizSkip(credential: credential)
        var state = try await ledger.snapshot()
        XCTAssertTrue(state.quizSkipActive)
        XCTAssertEqual(state.grants.first?.kind, .skipQuiz)
        clock.advance(86_400_000)
        state = try await ledger.snapshot()
        XCTAssertFalse(state.quizSkipActive)
        XCTAssertTrue(state.grants.isEmpty)
        await ledger.close()
    }

    // MARK: Quiz gates and rewards

    private func question(_ id: String) -> QuizQuestion {
        QuizQuestion(id: id, grade: 4, subject: "数学", difficulty: "easy",
            prompt: "\(id) 的答案？", options: [.init(id: "a", text: "1"), .init(id: "b", text: "2")],
            answerID: "a", explanation: "正确答案是 1。")
    }

    func testPendingQuizViewersResumeOnlyUnfinishedChildrenAndResetAtRealMidnight() async throws {
        let rules = QuizRules(questionsPerRound: 1, quizBeforeFirstWatch: true, quizAfterRest: false)
        let (ledger, clock, store, url, a) = try await calendarSetup(config: FamilyConfiguration(quizRules: rules))
        let b = profile("B"), inactive = profile("Not watching")
        try await ledger.upsertProfile(b, credential: credential)
        try await ledger.upsertProfile(inactive, credential: credential)
        try await ledger.selectViewers([a.id, b.id], credential: credential)
        let initial = try await ledger.snapshot()
        XCTAssertEqual(initial.pendingQuizViewerIDs, initial.activeViewerIDs)
        let roundA = try await ledger.startQuizRound(childID: a.id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(roundA, answers: ["q": "a"])
        // Recovery retains today's qualification, while the next *real* midnight
        // must rearm it instead of consulting the retained Nov 6 duration clock.
        clock.setWall(calendarMilliseconds("2026-11-08T15:59:59Z"))
        try await ledger.reanchorClock(credential: credential)
        let partial = try await ledger.snapshot()
        XCTAssertEqual(partial.day, 20261108)
        XCTAssertEqual(partial.pendingQuizViewerIDs, [b.id])
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "b-still-pending", requestedMilliseconds: 1) }
        await ledger.close()
        let resumed = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let reopened = try await resumed.snapshot()
        XCTAssertEqual(reopened.pendingQuizViewerIDs, [b.id])
        let repeated = try await resumed.snapshot()
        XCTAssertEqual(repeated.pendingQuizViewerIDs, [b.id])
        XCTAssertEqual(repeated.checkpoint, reopened.checkpoint, "querying pending children consumes nothing")
        let roundB = try await resumed.startQuizRound(childID: b.id, questions: [question("q")])
        _ = try await resumed.submitQuizRound(roundB, answers: ["q": "a"])
        let passed = try await resumed.snapshot()
        XCTAssertTrue(passed.pendingQuizViewerIDs.isEmpty)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM quiz_attempts"), "2", "A is not asked to repeat")
        let lease = try await resumed.reservePlayback(eventID: "both-qualified", requestedMilliseconds: 1)
        _ = try await resumed.settlePlayback(leaseID: lease.id)
        clock.advance(1_000)
        let tomorrow = try await resumed.snapshot()
        XCTAssertEqual(tomorrow.day, 20261109)
        XCTAssertEqual(tomorrow.pendingQuizViewerIDs, tomorrow.activeViewerIDs)
        XCTAssertFalse(tomorrow.pendingQuizViewerIDs.contains(inactive.id))
        await expect(.quizRequired) { _ = try await resumed.reservePlayback(eventID: "fresh-day-quiz", requestedMilliseconds: 1) }
        await resumed.close()
    }

    func testPendingQuizViewersRearmsBothOnlyAfterSharedRestCompletes() async throws {
        let rules = QuizRules(questionsPerRound: 1, quizBeforeFirstWatch: false, quizAfterRest: true)
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 1_000, quizRules: rules)
        let (ledger, clock, _, _, people) = try await setup(config: config)
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        for child in people {
            let round = try await ledger.startQuizRound(childID: child.id, questions: [question("q")])
            _ = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        }
        try await play(ledger, clock, 1_000)
        let resting = try await ledger.snapshot()
        XCTAssertTrue(resting.pendingQuizViewerIDs.isEmpty)
        XCTAssertEqual(resting.remainingRestMilliseconds, 1_000)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "rest-is-still-required", requestedMilliseconds: 1) }
        clock.advance(1_000)
        let rested = try await ledger.snapshot()
        XCTAssertEqual(rested.pendingQuizViewerIDs, rested.activeViewerIDs)
        XCTAssertEqual(rested.remainingRestMilliseconds, 0)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "rest-rearms-both", requestedMilliseconds: 1) }
        let first = try await ledger.startQuizRound(childID: people[0].id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(first, answers: ["q": "a"])
        let partial = try await ledger.snapshot()
        XCTAssertEqual(partial.pendingQuizViewerIDs, [people[1].id])
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "rest-second-pending", requestedMilliseconds: 1) }
        let second = try await ledger.startQuizRound(childID: people[1].id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(second, answers: ["q": "a"])
        let completed = try await ledger.snapshot()
        XCTAssertTrue(completed.pendingQuizViewerIDs.isEmpty)
        XCTAssertEqual(completed.familyActualMilliseconds, 1_000)
        let lease = try await ledger.reservePlayback(eventID: "rest-both-qualified", requestedMilliseconds: 1)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        await ledger.close()
    }

    func testPendingQuizViewersFiltersRecipientReliefAndCurrentRulesWithoutConsumingGrants() async throws {
        let rules = QuizRules(questionsPerRound: 1, quizBeforeFirstWatch: true, quizAfterRest: true)
        var config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 1_000, quizRules: rules)
        let (ledger, clock, _, _, people) = try await setup(config: config)
        // Bonus alone is not quiz relief; skip and exemption are recipient-scoped.
        _ = try await ledger.grantTemporaryBonus(1_000, credential: credential)
        let bonusOnly = try await ledger.snapshot()
        XCTAssertEqual(bonusOnly.pendingQuizViewerIDs, [people[0].id])
        let skip = try await ledger.grantQuizSkip(credential: credential)
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        let onlyB = try await ledger.snapshot()
        XCTAssertEqual(onlyB.pendingQuizViewerIDs, [people[1].id])
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "skip-does-not-cover-b", requestedMilliseconds: 1) }
        try await ledger.selectViewers([people[1].id], credential: credential)
        let exemption = try await ledger.grantDayExemption(credential: credential)
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        let relieved = try await ledger.snapshot()
        XCTAssertTrue(relieved.pendingQuizViewerIDs.isEmpty)
        XCTAssertFalse(relieved.quizSkipActive, "different individual relief need not be family-wide")
        XCTAssertFalse(relieved.dayExemptionActive)
        let repeated = try await ledger.snapshot()
        XCTAssertEqual(repeated.checkpoint, relieved.checkpoint)
        XCTAssertTrue(repeated.grants.contains(skip))
        XCTAssertTrue(repeated.grants.contains(exemption))
        try await play(ledger, clock, 1_000)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "relief-cannot-skip-rest", requestedMilliseconds: 1) }
        clock.advance(1_000)
        let afterRest = try await ledger.snapshot()
        XCTAssertTrue(afterRest.pendingQuizViewerIDs.isEmpty)
        clock.advance(86_400_000)
        let expired = try await ledger.snapshot()
        XCTAssertTrue(expired.grants.isEmpty)
        XCTAssertEqual(expired.pendingQuizViewerIDs, expired.activeViewerIDs)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "expired-relief-rearms", requestedMilliseconds: 1) }
        config.quizRules?.quizBeforeFirstWatch = false
        config.quizRules?.quizAfterRest = false
        try await ledger.configureFamily(config, credential: credential)
        let noGates = try await ledger.snapshot()
        XCTAssertTrue(noGates.pendingQuizViewerIDs.isEmpty)
        config.quizRules = nil
        try await ledger.configureFamily(config, credential: credential)
        let disabled = try await ledger.snapshot()
        XCTAssertTrue(disabled.pendingQuizViewerIDs.isEmpty)
        let lease = try await ledger.reservePlayback(eventID: "rules-disabled", requestedMilliseconds: 1)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        await ledger.close()
    }

    func testQuizGateBlocksFirstWatchAndRewardCreditingIsIdempotent() async throws {
        let rules = QuizRules(questionsPerRound: 2, passRatio: 0.5, rewardMinutes: 10,
                              personalDailyRewards: 1, familyDailyRewards: 2,
                              quizBeforeFirstWatch: true, quizAfterRest: false)
        let config = FamilyConfiguration(dailyLimitMilliseconds: 600_000, quizRules: rules)
        let (ledger, clock, _, url, people) = try await setup(config: config)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "gated", requestedMilliseconds: 1_000) }
        let questions = [question("q1"), question("q2")]
        let round = try await ledger.startQuizRound(childID: people[0].id, questions: questions)
        let failed = try await ledger.submitQuizRound(round, answers: ["q1": "b", "q2": "b"])
        XCTAssertFalse(failed.passed)
        XCTAssertEqual(failed.rewardMinutes, 0)
        // Replaying the same round returns the stored outcome; answers are final.
        let replay = try await ledger.submitQuizRound(round, answers: ["q1": "a", "q2": "a"])
        XCTAssertFalse(replay.passed)
        // A new round can pass and credit the reward exactly once.
        let passingRound = try await ledger.startQuizRound(childID: people[0].id, questions: questions)
        let passed = try await ledger.submitQuizRound(passingRound, answers: ["q1": "a", "q2": "a"])
        XCTAssertTrue(passed.passed)
        XCTAssertEqual(passed.rewardMinutes, 600_000)
        let credited = try await ledger.snapshot()
        XCTAssertEqual(credited.familyBonusMilliseconds, 600_000)
        let replayPassed = try await ledger.submitQuizRound(passingRound, answers: ["q1": "a", "q2": "a"])
        XCTAssertEqual(replayPassed.rewardMinutes, 600_000)
        let afterReplay = try await ledger.snapshot()
        XCTAssertEqual(afterReplay.familyBonusMilliseconds, 600_000)
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM quiz_rewards"), "1")
        let lease = try await ledger.reservePlayback(eventID: "afterquiz", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let round2 = try await ledger.startQuizRound(childID: people[0].id, questions: questions)
        let second = try await ledger.submitQuizRound(round2, answers: ["q1": "a", "q2": "a"])
        XCTAssertTrue(second.passed)
        XCTAssertEqual(second.rewardDeniedReason, "personal-daily-cap")
        XCTAssertEqual(second.rewardMinutes, 0)
        let report = try await ledger.report(lastDays: 7)
        XCTAssertEqual(report.quizAttempts.count, 3) // failed, passed, capped-second
        XCTAssertTrue(report.wrongAnswers.contains { $0.questionID == "q1" && $0.chosenOptionID == "b" })
        await ledger.close()
    }

    func testCompletedRestRearmsQuizGateAndSkipGrantWaivesIt() async throws {
        let rules = QuizRules(quizBeforeFirstWatch: false, quizAfterRest: true)
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000,
                                         restMilliseconds: 1_000, quizRules: rules)
        let (ledger, clock, _, _, _) = try await setup(config: config)
        try await play(ledger, clock, 1_000)
        clock.advance(1_000)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "afterrest", requestedMilliseconds: 1_000) }
        try await ledger.grantQuizSkip(credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "skipped", requestedMilliseconds: 1_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        try await ledger.settlePlayback(leaseID: lease.id)
        await ledger.close()
    }

    func testEarlyFamilyRestWaitsFullyAndNeverResetsDailyUsage() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000,
                                         quizRules: QuizRules(quizAfterRest: false))
        let (ledger, clock, _, _, _) = try await setup(config: config)
        try await play(ledger, clock, 850)
        try await ledger.requestFamilyRest()
        var state = try await ledger.snapshot()
        XCTAssertEqual(state.remainingRestMilliseconds, 10_000)
        XCTAssertEqual(state.continuousActualMilliseconds, 850)
        XCTAssertEqual(state.familyActualMilliseconds, 850)
        clock.advance(9_000)
        try await ledger.requestFamilyRest()
        state = try await ledger.snapshot()
        XCTAssertEqual(state.remainingRestMilliseconds, 1_000)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "early", requestedMilliseconds: 500) }
        clock.advance(1_000)
        state = try await ledger.snapshot()
        XCTAssertEqual(state.continuousActualMilliseconds, 0)
        XCTAssertEqual(state.familyActualMilliseconds, 850)
        let lease = try await ledger.reservePlayback(eventID: "after-rest", requestedMilliseconds: 500)
        await expect(.leaseAlreadyActive) { try await ledger.requestFamilyRest() }
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        await ledger.close()
    }

    func testRendererMarginEndsRenewalWithoutPhantomFrozenReservation() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, _, url, _) = try await setup(config: config)
        let lease = try await ledger.reservePlayback(eventID: "margin", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(850)
        let renewal = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 1_000,
                                                     minimumSuccessorMilliseconds: 250)
        XCTAssertNil(renewal.nextLease)
        XCTAssertEqual(renewal.receipt.actualMilliseconds, 850)
        clock.advance(500)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        XCTAssertEqual(state.familyActualMilliseconds, 850)
        XCTAssertEqual(state.remainingRestMilliseconds, 9_500)
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM usage_events"), "1")
        let retry = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 1_000,
                                                  minimumSuccessorMilliseconds: 250)
        XCTAssertNil(retry.nextLease)
        XCTAssertEqual(retry.receipt.actualMilliseconds, 850)
        await ledger.close()
    }

    func testAcceptance7UnauthorizedSwitchCannotBorrowAnotherProfile() async throws {
        let people = [profile("A", limit: 1_000), profile("B")]
        let (ledger, clock, _, _, _) = try await setup(profiles: people)
        try await play(ledger, clock, 1_000)
        await expect(.unauthorized) { try await ledger.selectViewers([people[1].id], credential: Data()) }
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "borrow", requestedMilliseconds: 1) }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.activeViewerIDs, [people[0].id])
        await ledger.close()
    }

    func testAcceptance89MultiViewerFamilyOnceAndOneChildStopsEveryone() async throws {
        let people = [profile("A", limit: 20 * minute), profile("B")]
        let (ledger, clock, _, _, _) = try await setup(profiles: people)
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        try await play(ledger, clock, 20 * minute)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 20 * minute)
        for person in people { XCTAssertEqual(state.personalActualMilliseconds[person.id], 20 * minute) }
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "over", requestedMilliseconds: 1) }
        await ledger.close()
    }

    func testAcceptance13PauseBufferingAccuratelyExcludeTime() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        let lease = try await ledger.reservePlayback(eventID: "states", requestedMilliseconds: 5_000)
        clock.advance(500) // starts paused
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .buffering)
        clock.advance(1_500)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(750)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .paused)
        clock.advance(1_000)
        let receipt = try await ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(receipt.actualMilliseconds, 1_750)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 1_750)
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        await ledger.close()
    }

    func testEightCurriculumProfilesAndLockedViewersPersistWithoutAccountDependency() async throws {
        let people = (1...8).map { profile("Child \($0)") }
        let (ledger, clock, store, url, _) = try await setup(profiles: people)
        try await ledger.selectViewers([people[5].id, people[7].id], credential: credential)
        try await play(ledger, clock, 123)
        await ledger.close()
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertEqual(state.profiles.sorted { $0.id.uuidString < $1.id.uuidString },
                       people.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(Set(state.activeViewerIDs), Set([people[5].id, people[7].id]))
        XCTAssertEqual(state.familyActualMilliseconds, 123)
        await reopened.close()
    }

    func testNormalProcessRelaunchDoesNotBlockChildPlayback() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        try await play(ledger, clock, 1_000)
        await ledger.close()
        clock.advance(3_000, continuityID: "new-process")
        let reopened = try UsageLedger(databaseURL: url, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await reopened.snapshot()
        XCTAssertTrue(state.clockIsTrusted)
        XCTAssertEqual(state.familyActualMilliseconds, 1_000)
        let lease = try await reopened.reservePlayback(eventID: "restart", requestedMilliseconds: 1_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        _ = try await reopened.settlePlayback(leaseID: lease.id)
        await reopened.close()
    }

    func testAcceptance56CoreCrashReservationFreezesSeparatelyOnReopen() async throws {
        let config = FamilyConfiguration(dailyLimitMilliseconds: 5_000)
        let (ledger, clock, store, url, people) = try await setup(config: config)
        try await play(ledger, clock, 1_000)
        let lease = try await ledger.reservePlayback(eventID: "crash", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 4_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(2_000)
        await ledger.close() // deliberately no settle
        clock.advance(1_000, wallDelta: 86_400_000, continuityID: "new-process")
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        var state = try await reopened.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 1_000)
        XCTAssertEqual(state.familyFrozenMilliseconds, 4_000)
        XCTAssertEqual(state.personalFrozenMilliseconds[people[0].id], 4_000)
        XCTAssertFalse(state.clockIsTrusted)
        await expect(.clockUntrusted) { _ = try await reopened.reservePlayback(eventID: "again", requestedMilliseconds: 1) }
        try await reopened.reanchorClock(credential: credential)
        state = try await reopened.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 1_000)
        await expect(.budgetExhausted) { _ = try await reopened.reservePlayback(eventID: "again", requestedMilliseconds: 1) }
        await expect(.leaseExpired) { _ = try await reopened.settlePlayback(leaseID: lease.id) }
        await reopened.close()
    }

    func testRebootRestCannotUseWallClockToUnlock() async throws {
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 10_000)
        let (ledger, clock, store, url, _) = try await setup(config: config)
        try await play(ledger, clock, 1_000)
        await ledger.close()
        clock.advance(1_000, wallDelta: 100_000, continuityID: "reboot")
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        var state = try await reopened.snapshot()
        XCTAssertEqual(state.remainingRestMilliseconds, 10_000)
        XCTAssertFalse(state.clockIsTrusted)
        try await reopened.reanchorClock(credential: credential)
        clock.advance(9_999)
        await expect(.resting) { _ = try await reopened.reservePlayback(eventID: "rest", requestedMilliseconds: 1) }
        clock.advance(1)
        state = try await reopened.snapshot()
        XCTAssertEqual(state.remainingRestMilliseconds, 0)
        await reopened.close()
    }

    func testAcceptance11WallForwardBackwardAndMonotonicRollbackFailClosed() async throws {
        for (mono, wall) in [(Int64(100), Int64(86_400_000)), (100, -86_400_000), (-1, -1)] {
            let (ledger, clock, _, _, _) = try await setup()
            try await play(ledger, clock, 700)
            let before = try await ledger.snapshot()
            clock.advance(mono, wallDelta: wall)
            let after = try await ledger.snapshot()
            XCTAssertFalse(after.clockIsTrusted)
            XCTAssertEqual(after.day, before.day)
            XCTAssertEqual(after.familyActualMilliseconds, 700)
            await expect(.clockUntrusted) { _ = try await ledger.reservePlayback(eventID: "clock", requestedMilliseconds: 100) }
            await ledger.close()
        }
    }

    func testGradualWallClockEditsCannotEvadeAnchorCheck() async throws {
        let (ledger, clock, _, _, _) = try await setup()
        for _ in 0..<3 { clock.advance(1_000, wallDelta: 2_000); _ = try await ledger.snapshot() }
        let state = try await ledger.snapshot()
        XCTAssertFalse(state.clockIsTrusted)
        await ledger.close()
    }

    func testLateAndDuplicateLeaseEventsAndSinglePlayerExclusion() async throws {
        let (ledger, clock, _, url, people) = try await setup()
        let first = try await ledger.reservePlayback(eventID: "unique", requestedMilliseconds: 1_000)
        let duplicate = try await ledger.reservePlayback(eventID: "unique", requestedMilliseconds: 1_000)
        XCTAssertEqual(first, duplicate)
        await expect(.leaseAlreadyActive) { _ = try await ledger.reservePlayback(eventID: "parallel", requestedMilliseconds: 1) }
        await expect(.leaseAlreadyActive) { try await ledger.selectViewers([people[1].id], credential: credential) }
        try await ledger.setPlaybackActivity(leaseID: first.id, activity: .playing)
        clock.advance(1_000)
        let receipt = try await ledger.settlePlayback(leaseID: first.id)
        let again = try await ledger.settlePlayback(leaseID: first.id)
        XCTAssertEqual(again, receipt)
        await expect(.eventConflict) { _ = try await ledger.reservePlayback(eventID: "unique", requestedMilliseconds: 1_000) }
        let late = try await ledger.reservePlayback(eventID: "late", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: late.id, activity: .playing)
        clock.advance(1_001)
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: late.id) }
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: late.id) }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 1_000)
        XCTAssertEqual(state.familyFrozenMilliseconds, 1_000)
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM usage_events"), "2")
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM watch_sessions WHERE event_id='unique'"), "1000")
        await ledger.close()
    }

    func testSQLiteTransactionRollbackDoesNotPartiallyChargeFamilyOrChild() async throws {
        let (ledger, clock, _, url, people) = try await setup()
        let lease = try await ledger.reservePlayback(eventID: "rollback", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        _ = try await ledger.snapshot() // persist clock before injecting settlement fault
        _ = try sql(url, "CREATE TRIGGER fail_settlement BEFORE UPDATE OF receipt ON usage_events WHEN NEW.status='settled' BEGIN SELECT RAISE(ABORT,'test rollback'); END")
        do { _ = try await ledger.settlePlayback(leaseID: lease.id); XCTFail("must roll back") }
        catch let error as LedgerError { if case .database = error {} else { XCTFail("\(error)") } }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 0)
        XCTAssertEqual(state.activeLease?.id, lease.id)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=\(state.day)"), "0")
        _ = try sql(url, "DROP TRIGGER fail_settlement")
        let receipt = try await ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(receipt.actualMilliseconds, 1_000)
        await ledger.close()
    }

    func testCheckpointDetectsMissingDatabaseOldBackupAndWriteFailure() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        await ledger.close()
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try FileManager.default.copyItem(at: url, to: backup)
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await play(reopened, clock, 100)
        await reopened.close()
        XCTAssertThrowsError(try UsageLedger(databaseURL: backup, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .checkpointMismatch)
        }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .missingDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let (other, otherClock, otherStore, otherURL, _) = try await setup()
        otherStore.failWrite = true
        otherClock.advance(1)
        await expect(.securityStoreUnavailable) { _ = try await other.snapshot() }
        await expect(.closed) { _ = try await other.snapshot() }
        await other.close()
        otherStore.failWrite = false
        XCTAssertThrowsError(try UsageLedger(databaseURL: otherURL, clock: otherClock, checkpointStore: otherStore, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .checkpointMismatch)
        }
    }

    func testDatabaseAliasesCannotOpenASecondLiveLedger() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        let lease = try await ledger.reservePlayback(eventID: "alias", requestedMilliseconds: 5_000)
        let symbolic = url.deletingLastPathComponent().appendingPathComponent("alias.sqlite")
        let hard = url.deletingLastPathComponent().appendingPathComponent("hard.sqlite")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: url)
        XCTAssertThrowsError(try UsageLedger(databaseURL: symbolic, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .ledgerAlreadyOpen)
        }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.activeLease?.id, lease.id)
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        await ledger.close()
        try FileManager.default.linkItem(at: url, to: hard)
        XCTAssertThrowsError(try UsageLedger(databaseURL: hard, clock: clock,
            checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .invalidInput("hard-linked databases are unsupported"))
        }
    }

    func testCorruptDatabaseIsNotDeletedAndSecondLedgerIsDenied() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .ledgerAlreadyOpen)
        }
        await ledger.close()
        let bytes = Data("not a SQLite database".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin()))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAcceptance16VersionOneFixtureMigrationPreservesAllUsageAndProfiles() async throws {
        let (ledger, clock, store, url, people) = try await setup()
        try await play(ledger, clock, 2_000)
        await ledger.close()
        // V1 fixture is intentionally the documented V1 state/event format without projections.
        for table in ["active_viewers", "child_profiles", "family_config", "family_daily_usage", "child_daily_usage", "watch_sessions", "rest_sessions", "parental_audit_logs"] {
            _ = try sql(url, "DROP TABLE \(table)")
        }
        _ = try sql(url, "PRAGMA user_version=1")
        let migrated = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let state = try await migrated.snapshot()
        XCTAssertEqual(state.familyActualMilliseconds, 2_000)
        XCTAssertEqual(state.profiles.count, 2)
        XCTAssertEqual(state.personalActualMilliseconds[people[0].id], 2_000)
        XCTAssertEqual(try sql(url, "PRAGMA user_version"), "3")
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM usage_events"), "1")
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=\(state.day)"), "2000")
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM watch_sessions WHERE actual_ms=2000"), "1")
        await migrated.close()
        _ = try sql(url, "PRAGMA user_version=999")
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .unsupportedSchema(999))
        }
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM usage_events"), "1")
    }

    func testTrustedLocalDayRolloverRetainsHistoricalProjection() async throws {
        let (ledger, clock, _, url, people) = try await setup()
        try await play(ledger, clock, 500)
        let before = try await ledger.snapshot()
        clock.advance(86_400_000)
        let after = try await ledger.snapshot()
        XCTAssertNotEqual(before.day, after.day)
        XCTAssertEqual(after.familyActualMilliseconds, 0)
        XCTAssertEqual(after.continuousActualMilliseconds, 500) // day reset cannot bypass continuous rule
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=\(before.day)"), "500")
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM child_daily_usage WHERE day=\(before.day) AND profile_id='\(people[0].id.uuidString)'"), "500")
        await ledger.close()
    }

    func testExpiredLeaseCrossingMidnightPreservesFrozenPreviousDayHistory() async throws {
        let url = try location(); let clock = TestLedgerClock(); let store = TestLedgerCheckpoint()
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-05T15:59:59Z")!.timeIntervalSince1970 * 1_000))
        let ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let child = profile("A")
        try await ledger.upsertProfile(child, credential: credential)
        try await ledger.selectViewers([child.id], credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "midnight", requestedMilliseconds: 5_000)
        XCTAssertEqual(lease.reservedMilliseconds, 1_000)
        clock.advance(1_001)
        await expect(.leaseExpired) { _ = try await ledger.settlePlayback(leaseID: lease.id) }
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.day, 20261106)
        XCTAssertEqual(state.familyActualMilliseconds, 0)
        XCTAssertEqual(state.familyFrozenMilliseconds, 0)
        XCTAssertEqual(state.continuousFrozenMilliseconds, 1_000)
        XCTAssertEqual(try sql(url, "SELECT frozen_ms FROM family_daily_usage WHERE day=20261105"), "1000")
        await ledger.close()
    }

    func testIANATimezoneDSTUsesLocalCalendarDayNotFixedTwentyFourHours() async throws {
        for (start, duration, nextDay) in [("2026-03-08T05:00:00Z", Int64(23 * 3_600_000), Int64(20260309)),
                                           ("2026-11-01T04:00:00Z", Int64(25 * 3_600_000), Int64(20261102))] {
            let url = try location(); let clock = TestLedgerClock(); let store = TestLedgerCheckpoint()
            let date = ISO8601DateFormatter().date(from: start)!
            clock.setWall(Int64(date.timeIntervalSince1970 * 1_000))
            let ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
            try await ledger.configureFamily(FamilyConfiguration(timeZoneIdentifier: "America/New_York"), credential: credential)
            let before = try await ledger.snapshot()
            clock.advance(duration - 1)
            let near = try await ledger.snapshot()
            XCTAssertEqual(near.day, before.day)
            clock.advance(1)
            let after = try await ledger.snapshot()
            XCTAssertEqual(after.day, nextDay)
            XCTAssertTrue(after.clockIsTrusted)
            await ledger.close()
        }
    }

    // MARK: Integrity regressions (real legacy payload shape and adversarial inputs)

    func testRealV2PayloadMissingNewFieldsMigratesAtomicallyWithoutCheckpointChange() async throws {
        let (ledger, clock, store, url, people) = try await setup()
        try await play(ledger, clock, 700)
        let checkpoint = try store.load()
        await ledger.close()
        let payload = try XCTUnwrap(sql(url, "SELECT payload FROM ledger_state WHERE id=1"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        // Actual pre-relief/pre-quiz V2 JSON has NONE of these keys. A schema-only
        // downgrade would not reproduce synthesized-Decodable's missing-key failure.
        for key in ["grants", "familyBonusMilliseconds", "personalBonus", "dayExemptUntilLogicalWall",
                    "quizSkipUntilLogicalWall", "quizPassedToday", "quizRewardCountToday", "familyQuizRewardsToday",
                    "restNeedingQuiz", "familyQuizRewardMilliseconds", "personalQuizRewardMilliseconds",
                    "familyRecoveryFrozen", "personalRecoveryFrozen", "recoveryQuarantinedDay"] { old.removeValue(forKey: key) }
        try removeClockProvenance(&old)
        // Keep this DDL-only migration in its original process/timebase, so the
        // checkpoint assertion tests schema migration, not a new clock observation.
        let originalSample = clock.now()
        clock.set(LedgerClockSample(wallMilliseconds: originalSample.wallMilliseconds,
            monotonicMilliseconds: originalSample.monotonicMilliseconds,
            continuityID: originalSample.continuityID))
        var config = try XCTUnwrap(old["configuration"] as? [String: Any])
        config.removeValue(forKey: "quizRules"); config.removeValue(forKey: "schedule")
        old["configuration"] = config
        let json = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        XCTAssertFalse(json.contains("quizPassedToday"))
        _ = try sql(url, "UPDATE ledger_state SET payload='\(json.replacingOccurrences(of: "'", with: "''"))' WHERE id=1")
        for table in ["quiz_rounds", "quiz_outcomes", "temporary_grants", "quiz_attempts", "quiz_rewards"] {
            _ = try sql(url, "DROP TABLE \(table)")
        }
        _ = try sql(url, "ALTER TABLE parental_audit_logs DROP COLUMN duration_ms")
        _ = try sql(url, "ALTER TABLE parental_audit_logs DROP COLUMN action_id")
        _ = try sql(url, "PRAGMA user_version=2")
        // A migration must not require a Keychain rewrite just to add tables/defaults.
        store.failWrite = true
        let migrated = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await migrated.snapshot()
        XCTAssertEqual(snapshot.checkpoint, checkpoint)
        XCTAssertEqual(snapshot.familyActualMilliseconds, 700)
        // Snapshots list children alphabetically (name, then UUID tiebreaker).
        XCTAssertEqual(snapshot.profiles,
                       people.sorted { ($0.displayName, $0.id.uuidString) < ($1.displayName, $1.id.uuidString) })
        XCTAssertNil(snapshot.configuration.quizRules)
        XCTAssertEqual(snapshot.familyBonusMilliseconds, 0)
        XCTAssertEqual(try sql(url, "PRAGMA user_version"), "3")
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM quiz_rounds"), "0")
        await migrated.close()
        store.failWrite = false
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        try await reopened.requestFamilyRest()
        clock.advance(600_000)
        // nil rules must NOT silently force the newly introduced after-rest quiz.
        let lease = try await reopened.reservePlayback(eventID: "legacy-no-gate", requestedMilliseconds: 100)
        XCTAssertEqual(lease.reservedMilliseconds, 100)
        await reopened.close()
    }

    func testMigrationFailureRollsBackDDLAndVersionWithoutCheckpointRewrite() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        let checkpoint = try store.load()
        await ledger.close()
        _ = try sql(url, "DROP TABLE quiz_rounds")
        _ = try sql(url, "PRAGMA user_version=2")
        _ = try sql(url, "CREATE TRIGGER fail_migration BEFORE UPDATE ON ledger_state BEGIN SELECT RAISE(ABORT,'migration fault'); END")
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin()))
        XCTAssertEqual(try sql(url, "PRAGMA user_version"), "2")
        XCTAssertNil(try sql(url, "SELECT name FROM sqlite_master WHERE name='quiz_rounds'"))
        XCTAssertEqual(try store.load(), checkpoint)
        _ = try sql(url, "DROP TRIGGER fail_migration")
        let migrated = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        XCTAssertEqual(try sql(url, "PRAGMA user_version"), "3")
        await migrated.close()
    }

    func testForgedReplayedAndCrossChildRoundsNeverTrustClientAnswerKeys() async throws {
        let rules = QuizRules(questionsPerRound: 1, personalDailyRewards: 1, quizAfterRest: false)
        let (ledger, clock, store, url, people) = try await setup(config: FamilyConfiguration(quizRules: rules))
        let q = question("q")
        let fake = QuizRound(id: UUID(), childID: people[0].id, questions: [q])
        await expect(.invalidInput("unknown quiz round")) { _ = try await ledger.submitQuizRound(fake, answers: ["q": "a"]) }
        let round = try await ledger.startQuizRound(childID: people[0].id, questions: [q])
        let forgedQuestion = QuizQuestion(id: "q", grade: 4, subject: "数学", difficulty: "easy", prompt: q.prompt,
            options: q.options, answerID: "b", explanation: q.explanation)
        let forged = QuizRound(id: round.id, childID: people[0].id, questions: [forgedQuestion])
        await expect(.invalidInput("quiz round mismatch")) { _ = try await ledger.submitQuizRound(forged, answers: ["q": "b"]) }
        await expect(.invalidInput("quiz round mismatch")) {
            _ = try await ledger.submitQuizRound(id: round.id, childID: people[1].id, answers: ["q": "a"])
        }
        for answers in [["other": "a"], ["q": "nonexistent"], [:]] {
            await expect(.invalidInput("incomplete or invalid answers")) { _ = try await ledger.submitQuizRound(round, answers: answers) }
        }
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM quiz_attempts"), "0")
        await ledger.close()
        // Issued questions and outcomes must survive ledger lifetime/reopen.
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let passed = try await reopened.submitQuizRound(id: round.id, childID: people[0].id, answers: ["q": "a"])
        let duplicate = try await reopened.submitQuizRound(round, answers: ["q": "b"])
        XCTAssertEqual(passed, duplicate)
        let cappedRound = try await reopened.startQuizRound(childID: people[0].id, questions: [q])
        let denied = try await reopened.submitQuizRound(cappedRound, answers: ["q": "a"])
        XCTAssertEqual(denied.rewardDeniedReason, "personal-daily-cap")
        let deniedReplay = try await reopened.submitQuizRound(cappedRound, answers: ["q": "a"])
        XCTAssertEqual(deniedReplay, denied)
        await expect(.invalidInput("quiz round mismatch")) {
            _ = try await reopened.submitQuizRound(id: cappedRound.id, childID: people[1].id, answers: ["q": "a"])
        }
        XCTAssertEqual(try sql(url, "SELECT count(*) FROM quiz_rewards"), "1")
        await reopened.close()
    }

    func testRoundValidationAndDayRuleAndRestBindings() async throws {
        var rules = QuizRules(questionsPerRound: 2, quizAfterRest: true)
        var config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 1_000, quizRules: rules)
        let (ledger, clock, _, _, people) = try await setup(config: config)
        await expect(.invalidInput("round question count or identity mismatch")) {
            _ = try await ledger.startQuizRound(childID: people[0].id, questions: [self.question("same"), self.question("same")])
        }
        let qs = [question("1"), question("2")], answers = ["1": "a", "2": "a"]
        let oldDay = try await ledger.startQuizRound(childID: people[0].id, questions: qs)
        clock.advance(86_400_000)
        await expect(.invalidInput("stale quiz round")) { _ = try await ledger.submitQuizRound(oldDay, answers: answers) }
        let oldRule = try await ledger.startQuizRound(childID: people[0].id, questions: qs)
        rules.ruleVersion += 1; config.quizRules = rules
        try await ledger.configureFamily(config, credential: credential)
        await expect(.invalidInput("unknown quiz round")) { _ = try await ledger.submitQuizRound(oldRule, answers: answers) }
        let beforeRest = try await ledger.startQuizRound(childID: people[1].id, questions: qs)
        try await ledger.grantQuizSkip(credential: credential)
        try await play(ledger, clock, 1_000)
        await expect(.resting) { _ = try await ledger.submitQuizRound(beforeRest, answers: answers) }
        clock.advance(1_000)
        await expect(.invalidInput("stale quiz round")) { _ = try await ledger.submitQuizRound(beforeRest, answers: answers) }
        await ledger.close()
    }

    func testFamilyRewardDurationAndAbsoluteTotalCapsSeparateFromParentalBonus() async throws {
        let rules = QuizRules(questionsPerRound: 1, rewardMinutes: 1, personalDailyRewards: 10,
            familyDailyRewards: 20, quizAfterRest: false, maxFamilyDailyRewardMilliseconds: 90_000,
            familyAbsoluteTotalMilliseconds: 1_000_000)
        let (ledger, _, _, url, people) = try await setup(config: FamilyConfiguration(dailyLimitMilliseconds: 600_000, quizRules: rules))
        try await ledger.grantTemporaryBonus(1_000, credential: credential)
        for (index, person) in people.enumerated() {
            let round = try await ledger.startQuizRound(childID: person.id, questions: [question("q")])
            let result = try await ledger.submitQuizRound(round, answers: ["q": "a"])
            XCTAssertEqual(result.rewardMilliseconds, index == 0 ? 60_000 : 0)
            XCTAssertEqual(result.rewardDeniedReason, index == 0 ? nil : "family-daily-duration-cap")
        }
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.parentalBonusMilliseconds, 1_000)
        XCTAssertEqual(snapshot.familyQuizRewardMilliseconds, 60_000)
        XCTAssertEqual(snapshot.familyBonusMilliseconds, 61_000)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM quiz_rewards"), "1")
        var absoluteRules = rules
        absoluteRules.maxFamilyDailyRewardMilliseconds = 300_000
        absoluteRules.familyAbsoluteTotalMilliseconds = 700_000
        try await ledger.configureFamily(FamilyConfiguration(dailyLimitMilliseconds: 600_000, quizRules: absoluteRules), credential: credential)
        let round = try await ledger.startQuizRound(childID: people[1].id, questions: [question("q")])
        let denied = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        XCTAssertEqual(denied.rewardDeniedReason, "family-absolute-total-cap")
        await expect(.invalidInput("family absolute total exceeded")) { try await ledger.grantTemporaryBonus(40_000, credential: self.credential) }
        await ledger.close()
    }

    func testRewardInsertFailureRollsBackQualificationCountersAndOutcome() async throws {
        let rules = QuizRules(questionsPerRound: 1, quizBeforeFirstWatch: true, quizAfterRest: false)
        let (ledger, _, _, url, people) = try await setup(config: FamilyConfiguration(quizRules: rules))
        let round = try await ledger.startQuizRound(childID: people[0].id, questions: [question("q")])
        _ = try sql(url, "CREATE TRIGGER fail_reward BEFORE INSERT ON quiz_rewards BEGIN SELECT RAISE(ABORT,'reward fault'); END")
        do { _ = try await ledger.submitQuizRound(round, answers: ["q": "a"]); XCTFail("must roll back") } catch {}
        let before = try await ledger.snapshot()
        XCTAssertEqual(before.familyQuizRewardMilliseconds, 0)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM quiz_outcomes"), "0")
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "not-qualified", requestedMilliseconds: 100) }
        _ = try sql(url, "DROP TRIGGER fail_reward")
        let success = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        XCTAssertEqual(success.rewardMilliseconds, 600_000)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM quiz_rewards"), "1")
        await ledger.close()
    }

    func testAllProfilesNeedFreshQuizAfterSharedRestAndAcrossMidnight() async throws {
        let rules = QuizRules(questionsPerRound: 1, quizBeforeFirstWatch: true, quizAfterRest: true)
        let (ledger, clock, _, _, people) = try await setup(config: FamilyConfiguration(continuousLimitMilliseconds: 1_000,
            restMilliseconds: 1_000, quizRules: rules))
        for person in people {
            let round = try await ledger.startQuizRound(childID: person.id, questions: [question("q")])
            _ = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        }
        try await play(ledger, clock, 1_000)
        clock.advance(1_000)
        try await ledger.selectViewers([people[1].id], credential: credential)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "B-old-pass", requestedMilliseconds: 100) }
        let fresh = try await ledger.startQuizRound(childID: people[1].id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(fresh, answers: ["q": "a"])
        try await play(ledger, clock, 100)
        try await ledger.selectViewers([people[0].id], credential: credential)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "A-old-pass", requestedMilliseconds: 100) }
        clock.advance(86_400_000)
        await expect(.quizRequired) { _ = try await ledger.reservePlayback(eventID: "tomorrow", requestedMilliseconds: 100) }
        await ledger.close()
    }

    func testScheduleRenewalStopsAndPersistsActualReceiptWithoutFrozenUsage() async throws {
        let clock = TestLedgerClock()
        let schedule = FamilySchedule(weekday: .init(startMinuteOfDay: 600, endMinuteOfDay: 720))
        let (ledger, _) = try await scheduleSetup(clock, isoStart: "2026-11-06T03:59:59Z", schedule: schedule)
        let lease = try await ledger.reservePlayback(eventID: "schedule-edge", requestedMilliseconds: 5_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        let ended = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertNil(ended.nextLease)
        XCTAssertEqual(ended.receipt.actualMilliseconds, 1_000)
        let retry = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(retry, ended)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.familyActualMilliseconds, 1_000)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 0)
        XCTAssertNil(snapshot.activeLease)
        await ledger.close()
    }

    func testMidnightQuizRenewalCommitsPreviousDayUsageThenStops() async throws {
        let clock = TestLedgerClock(), url = try location(), store = TestLedgerCheckpoint()
        clock.setWall(Int64(ISO8601DateFormatter().date(from: "2026-11-30T15:59:59Z")!.timeIntervalSince1970 * 1_000))
        let ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let child = profile("A")
        try await ledger.configureFamily(FamilyConfiguration(quizRules: QuizRules(questionsPerRound: 1,
            quizBeforeFirstWatch: true, quizAfterRest: false)), credential: credential)
        try await ledger.upsertProfile(child, credential: credential)
        try await ledger.selectViewers([child.id], credential: credential)
        let round = try await ledger.startQuizRound(childID: child.id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        let lease = try await ledger.reservePlayback(eventID: "quiz-midnight", requestedMilliseconds: 5_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        let ended = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
        XCTAssertNil(ended.nextLease)
        XCTAssertEqual(ended.receipt.actualMilliseconds, 1_000)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=20261130"), "1000")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.familyActualMilliseconds, 0)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 0)
        await ledger.close()
    }

    func testExemptionBypassesExhaustedFamilyCapOnlyForRecipientsAndAuditsSurviveExpiry() async throws {
        let (ledger, clock, _, url, people) = try await setup(config: FamilyConfiguration(dailyLimitMilliseconds: 1_000,
            continuousLimitMilliseconds: 3_000, restMilliseconds: 1_000))
        try await play(ledger, clock, 1_000)
        let id = UUID()
        let grant = try await ledger.grantDayExemption(credential: credential, note: "approved", id: id)
        let duplicate = try await ledger.grantDayExemption(credential: credential, note: "approved", id: id)
        XCTAssertEqual(grant, duplicate)
        XCTAssertEqual(grant.viewerIDs, [people[0].id])
        XCTAssertNotNil(grant.issuedAtLogicalWall)
        try await play(ledger, clock, 1_000)
        try await ledger.selectViewers([people[1].id], credential: credential)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "B-not-exempt", requestedMilliseconds: 100) }
        try await ledger.selectViewers([people[0].id], credential: credential)
        try await play(ledger, clock, 1_000)
        await expect(.resting) { _ = try await ledger.reservePlayback(eventID: "rest-not-exempt", requestedMilliseconds: 100) }
        clock.advance(86_400_000)
        let history = try await ledger.grantHistory()
        XCTAssertEqual(history, [grant])
        let expiredReplay = try await ledger.grantDayExemption(credential: credential, note: "approved", id: id)
        XCTAssertEqual(expiredReplay, grant)
        let snapshot = try await ledger.snapshot()
        XCTAssertFalse(snapshot.dayExemptionActive)
        XCTAssertTrue(snapshot.grants.isEmpty)
        XCTAssertEqual(try sql(url, "SELECT COUNT(*) FROM parental_audit_logs WHERE action_id='\(id.uuidString)'"), "1")
        XCTAssertNotNil(try sql(url, "SELECT duration_ms FROM parental_audit_logs WHERE action_id='\(id.uuidString)'"))
        await ledger.close()
    }

    func testReportsUseLocalCalendarMonthAndYearRolloverWithChildBoundWrongs() async throws {
        for start in ["2026-11-30T15:00:00Z", "2026-12-31T15:00:00Z"] {
            let clock = TestLedgerClock(), url = try location(), store = TestLedgerCheckpoint()
            clock.setWall(Int64(ISO8601DateFormatter().date(from: start)!.timeIntervalSince1970 * 1_000))
            let ledger = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store,
                adminAuthorizer: TestLedgerAdmin(), reportRequiresAuthorization: true)
            let people = [profile("A"), profile("B")]
            try await ledger.configureFamily(FamilyConfiguration(quizRules: QuizRules(questionsPerRound: 1, quizAfterRest: false)), credential: credential)
            for person in people {
                try await ledger.upsertProfile(person, credential: credential)
                let round = try await ledger.startQuizRound(childID: person.id, questions: [question("q")])
                _ = try await ledger.submitQuizRound(round, answers: ["q": "b"])
            }
            try await ledger.selectViewers([people[0].id], credential: credential)
            try await play(ledger, clock, 500)
            clock.advance(7_200_000)
            await expect(.unauthorized) { _ = try await ledger.report(lastDays: 7) }
            let report = try await ledger.report(lastDays: 7, childID: people[0].id, credential: credential)
            XCTAssertEqual(report.days.reduce(0) { $0 + $1.familyActualMilliseconds }, 500)
            XCTAssertEqual(report.quizAttempts.count, 1)
            XCTAssertEqual(report.wrongAnswers.count, 1)
            XCTAssertEqual(report.wrongAnswers.first?.childID, people[0].id)
            XCTAssertNotNil(report.wrongAnswers.first?.attemptID)
            let todayOnly = try await ledger.report(lastDays: 1, credential: credential)
            XCTAssertTrue(todayOnly.quizAttempts.isEmpty)
            await ledger.close()
        }
    }

    func testDeletedProfileProjectionStaysDeletedAndMetadataEditPreservesCurriculum() async throws {
        let (ledger, clock, store, url, people) = try await setup()
        try await play(ledger, clock, 500)
        try await ledger.updateProfile(people[0].id, displayName: "renamed", avatarSymbol: "star",
            dailyLimitMilliseconds: 2_000, credential: credential)
        let edited = try await ledger.snapshot()
        XCTAssertEqual(edited.profiles.first { $0.id == people[0].id }?.curriculum, people[0].curriculum)
        try await ledger.deleteProfile(people[0].id, credential: credential)
        XCTAssertNil(try sql(url, "SELECT id FROM child_profiles WHERE id='\(people[0].id.uuidString)'"))
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM child_daily_usage WHERE profile_id='\(people[0].id.uuidString)'"), "500")
        await ledger.close()
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let snapshot = try await reopened.snapshot()
        XCTAssertFalse(snapshot.profiles.contains { $0.id == people[0].id })
        XCTAssertNil(try sql(url, "SELECT id FROM child_profiles WHERE id='\(people[0].id.uuidString)'"))
        await reopened.close()
    }

    func testRestoredBackupQuarantinesRemainingQuotaWithoutInventingActualOrReusingCheckpoint() async throws {
        let (ledger, clock, store, url, people) = try await setup(config: FamilyConfiguration(dailyLimitMilliseconds: 10_000,
            continuousLimitMilliseconds: 8_000, restMilliseconds: 1_000))
        try await play(ledger, clock, 1_000)
        let active = try await ledger.reservePlayback(eventID: "restore-active", requestedMilliseconds: 2_000)
        let before = try await ledger.backupState()
        clock.advance(500)
        let unchanged = try await ledger.backupState()
        XCTAssertEqual(unchanged.checkpoint, before.checkpoint) // safe read never ticks
        await expect(.unauthorized) { _ = try await ledger.prepareRestoredBackup(minimumRevision: 1_000, credential: Data()) }
        let cp = try await ledger.prepareRestoredBackup(minimumRevision: 1_000, credential: credential)
        XCTAssertGreaterThan(cp.revision, 1_000)
        XCTAssertEqual(cp.databaseID, before.checkpoint.databaseID)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.familyActualMilliseconds, 1_000)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 9_000)
        XCTAssertEqual(snapshot.familyRecoveryFrozenMilliseconds, 7_000)
        XCTAssertEqual(snapshot.frozenReservations.first?.leaseID, active.id)
        XCTAssertEqual(snapshot.remainingRestMilliseconds, 1_000)
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertNil(snapshot.activeLease)
        XCTAssertEqual(snapshot.personalActualMilliseconds[people[1].id], 0)
        try await ledger.reanchorClock(credential: credential)
        clock.advance(1_000)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "restored-no-fresh-quota", requestedMilliseconds: 1) }
        await ledger.close()
        let reopened = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted.familyActualMilliseconds, 1_000)
        XCTAssertEqual(persisted.familyFrozenMilliseconds, 9_000)
        await reopened.close()
    }

    func testOldDayBackupRestorationKeepsHistoryAndCannotUnlockWithDayExemption() async throws {
        let (ledger, clock, _, url, people) = try await setup(config: FamilyConfiguration(dailyLimitMilliseconds: 10_000,
            continuousLimitMilliseconds: 8_000, restMilliseconds: 1_000))
        try await play(ledger, clock, 1_000)
        let before = try await ledger.snapshot()
        clock.advance(86_400_000)
        _ = try await ledger.prepareRestoredBackup(minimumRevision: 2_000, credential: credential)
        let restored = try await ledger.snapshot()
        XCTAssertNotEqual(restored.day, before.day)
        XCTAssertEqual(restored.familyActualMilliseconds, 1_000)
        XCTAssertEqual(restored.familyCarriedActualMilliseconds, 1_000)
        XCTAssertEqual(restored.familyRecoveryFrozenMilliseconds, 9_000)
        XCTAssertEqual(restored.familyActualMilliseconds + restored.familyFrozenMilliseconds, 10_000)
        let today = try await ledger.report(lastDays: 1)
        XCTAssertEqual(today.days.first?.familyActualMilliseconds, 0)
        XCTAssertEqual(try sql(url, "SELECT actual_ms FROM family_daily_usage WHERE day=\(before.day)"), "1000")
        try await ledger.reanchorClock(credential: credential)
        clock.advance(1_000)
        try await ledger.grantDayExemption(credential: credential)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "no-restore-override", requestedMilliseconds: 1) }
        try await ledger.selectViewers([people[1].id], credential: credential)
        await expect(.budgetExhausted) { _ = try await ledger.reservePlayback(eventID: "no-restore-switch", requestedMilliseconds: 1) }
        clock.advance(86_400_000)
        let nextDay = try await ledger.reservePlayback(eventID: "next-trusted-day", requestedMilliseconds: 1)
        XCTAssertEqual(nextDay.reservedMilliseconds, 1)
        await ledger.close()
    }

    func testV2MigrationSplitsExistingRewardsWithoutChangingTotalAllowance() async throws {
        let (ledger, clock, store, url, people) = try await setup(config: FamilyConfiguration(quizRules: QuizRules(questionsPerRound: 1, quizAfterRest: false)))
        let round = try await ledger.startQuizRound(childID: people[0].id, questions: [question("q")])
        _ = try await ledger.submitQuizRound(round, answers: ["q": "a"])
        try await ledger.grantTemporaryBonus(1_000, credential: credential)
        let before = try await ledger.snapshot()
        await ledger.close()
        let payload = try XCTUnwrap(sql(url, "SELECT payload FROM ledger_state WHERE id=1"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        // V2 stored quiz and parental rewards together. Reproduce that representation.
        old["familyBonusMilliseconds"] = 601_000
        old["personalBonus"] = [people[0].id.uuidString: 601_000]
        old.removeValue(forKey: "familyQuizRewardMilliseconds")
        old.removeValue(forKey: "personalQuizRewardMilliseconds")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        _ = try sql(url, "UPDATE ledger_state SET payload='\(json.replacingOccurrences(of: "'", with: "''"))' WHERE id=1")
        _ = try sql(url, "PRAGMA user_version=2")
        let migrated = try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())
        let after = try await migrated.snapshot()
        XCTAssertEqual(after.checkpoint, before.checkpoint)
        XCTAssertEqual(after.familyBonusMilliseconds, 601_000)
        XCTAssertEqual(after.parentalBonusMilliseconds, 1_000)
        XCTAssertEqual(after.familyQuizRewardMilliseconds, 600_000)
        await migrated.close()
    }

    func testBonusGrantIdempotencyAndRequiredOriginalAccountingKeys() async throws {
        let (ledger, clock, store, url, _) = try await setup()
        let id = UUID()
        let bonus = try await ledger.grantTemporaryBonus(1_000, credential: credential, id: id)
        let replay = try await ledger.grantTemporaryBonus(1_000, credential: credential, id: id)
        XCTAssertEqual(replay, bonus)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.parentalBonusMilliseconds, 1_000)
        await expect(.eventConflict) { try await ledger.grantTemporaryBonus(2_000, credential: self.credential, id: id) }
        await ledger.close()
        _ = try sql(url, "UPDATE ledger_state SET payload=json_remove(payload,'$.familyActual') WHERE id=1")
        XCTAssertThrowsError(try UsageLedger(databaseURL: url, clock: clock, checkpointStore: store, adminAuthorizer: TestLedgerAdmin())) {
            XCTAssertEqual($0 as? LedgerError, .corruptDatabase)
        }
    }

    func testParentalActionRequiresTemporaryOverrideAndStoresDurationAndIdentity() async throws {
        let (ledger, _, _, url, _) = try await setup()
        await expect(.unauthorized) { try await ledger.recordParentalAction(operation: "mode", object: "adult", credential: Data()) }
        try await ledger.recordParentalAction(operation: "mode", object: "adult", durationMilliseconds: 10_000, credential: credential)
        XCTAssertEqual(try sql(url, "SELECT duration_ms FROM parental_audit_logs WHERE operation='mode'"), "10000")
        XCTAssertNotNil(try sql(url, "SELECT action_id FROM parental_audit_logs WHERE operation='mode'"))
        await ledger.close()
    }

    func testLegacyQuizModelsDecodeWithoutOptionalProvenanceOrNewLimits() throws {
        let oldRules = Data("{\"questionsPerRound\":1,\"passRatio\":0.6,\"rewardMinutes\":10,\"personalDailyRewards\":3,\"familyDailyRewards\":6,\"quizBeforeFirstWatch\":false,\"quizAfterRest\":true}".utf8)
        let rules = try JSONDecoder().decode(QuizRules.self, from: oldRules)
        XCTAssertEqual(rules.maxFamilyDailyRewardMilliseconds, 3_600_000)
        XCTAssertEqual(rules.familyAbsoluteTotalMilliseconds, 86_400_000)
        let decoded = try JSONDecoder().decode(QuizQuestion.self, from: JSONEncoder().encode(question("old")))
        XCTAssertNil(decoded.sourceMetadata)
    }

    func testDeterministicRandomPlaybackSequencesPreserveMultiViewerInvariants() async throws {
        let (ledger, clock, _, _, people) = try await setup()
        try await ledger.selectViewers(people.map(\.id), credential: credential)
        var seed: UInt64 = 42; var total: Int64 = 0
        for index in 0..<100 {
            let lease = try await ledger.reservePlayback(eventID: "random-\(index)", requestedMilliseconds: 500)
            var expected: Int64 = 0
            for _ in 0..<5 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let activity: PlaybackActivity = [.playing, .paused, .buffering][Int(seed % 3)]
                try await ledger.setPlaybackActivity(leaseID: lease.id, activity: activity)
                clock.advance(100)
                if activity == .playing { expected += 100 }
            }
            let receipt = try await ledger.settlePlayback(leaseID: lease.id)
            XCTAssertEqual(receipt.actualMilliseconds, expected)
            total += expected
            let state = try await ledger.snapshot()
            XCTAssertEqual(state.familyActualMilliseconds, total)
            for person in people { XCTAssertEqual(state.personalActualMilliseconds[person.id], total) }
            XCTAssertLessThanOrEqual(state.familyActualMilliseconds + state.familyFrozenMilliseconds,
                                     state.configuration.dailyLimitMilliseconds)
        }
        await ledger.close()
    }
}
