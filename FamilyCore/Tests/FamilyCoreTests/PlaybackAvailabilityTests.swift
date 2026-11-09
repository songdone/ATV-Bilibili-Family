import XCTest
import Foundation
@testable import FamilyCore

final class PlaybackAvailabilityTests: XCTestCase {
    private final class Clock: LedgerClock, @unchecked Sendable {
        var wall: Int64
        var mono: Int64 = 10_000
        init(_ iso: String) { wall = Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000) }
        func now() -> LedgerClockSample {
            LedgerClockSample(wallMilliseconds: wall, monotonicMilliseconds: mono,
                continuityID: "availability-process", monotonicSource: "test-continuous", bootSessionID: "test-boot")
        }
        func advance(_ ms: Int64) { wall += ms; mono += ms }
    }
    private final class Checkpoints: LedgerCheckpointStore, @unchecked Sendable {
        var value: LedgerCheckpoint?
        func load() throws -> LedgerCheckpoint? { value }
        func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws {
            guard value == expected else { throw LedgerError.checkpointMismatch }
            value = new
        }
    }
    private struct Admin: LedgerAdminAuthorizing {
        func authorize(operation: LedgerAdminOperation, credential: Data) throws {
            guard credential == Data("availability-test".utf8) else { throw LedgerError.unauthorized }
        }
    }
    private let credential = Data("availability-test".utf8)
    private var dirs: [URL] = []
    override func tearDownWithError() throws { for dir in dirs { try FileManager.default.removeItem(at: dir) } }

    private func make(_ clock: Clock, config: FamilyConfiguration = FamilyConfiguration(), personal: Int64 = 5_400_000) async throws -> UsageLedger {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        dirs.append(dir)
        let ledger = try UsageLedger(databaseURL: dir.appendingPathComponent("usage.sqlite"), clock: clock,
            checkpointStore: Checkpoints(), adminAuthorizer: Admin())
        try await ledger.configureFamily(config, credential: credential)
        let child = ViewerProfile(displayName: "Availability fixture", curriculum: CurriculumProfile(
            schoolStage: "小学", schoolSystem: "六三", grade: 4, academicYear: "2026-2027", semester: "全年"),
            dailyLimitMilliseconds: personal)
        try await ledger.upsertProfile(child, credential: credential)
        return ledger
    }

    func testWeekendRestrictionOffStillShowsFiveMinuteLimitAndTenMinuteRest() async throws {
        let clock = Clock("2026-11-08T07:00:00Z")
        let ledger = try await make(clock, config: FamilyConfiguration(dailyLimitMilliseconds: 7_200_000,
            continuousLimitMilliseconds: 300_000, restMilliseconds: 600_000,
            schedule: FamilySchedule(weekday: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))))
        for i in 0..<60 {
            let lease = try await ledger.reservePlayback(eventID: "five-min-\(i)", requestedMilliseconds: 5_000)
            try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
            clock.advance(5_000)
            _ = try await ledger.settlePlayback(leaseID: lease.id)
        }
        let rest = try await ledger.playbackAvailability()
        XCTAssertEqual(rest.blockedReason, .resting)
        XCTAssertEqual(rest.restRemainingMs, 600_000)
        XCTAssertEqual(rest.familyRemainingMs, 6_900_000)
        XCTAssertEqual(rest.availableRemainingMs, 5_100_000)
        XCTAssertFalse(rest.isScheduleBlocked)
        XCTAssertNil(rest.nextScheduleOpeningWallMilliseconds)
        let before = try await ledger.snapshot()
        clock.advance(60_000)
        let tick = try await ledger.playbackAvailability()
        XCTAssertEqual(tick.restRemainingMs, 540_000)
        XCTAssertEqual(tick.availableRemainingMs, rest.availableRemainingMs)
        let after = try await ledger.snapshot()
        XCTAssertEqual(after.familyActualMilliseconds, before.familyActualMilliseconds)
        XCTAssertNil(after.activeLease)
        clock.advance(540_000)
        let ready = try await ledger.playbackAvailability()
        XCTAssertEqual(ready.blockedReason, .ready)
        XCTAssertEqual(ready.continuousRemainingMs, 300_000)
        await ledger.close()
    }

    func testBalanceIncludesBonusMeasuredPlaybackAndNoPausedOrDuplicateCharge() async throws {
        let clock = Clock("2026-11-08T07:00:00Z")
        let ledger = try await make(clock, config: FamilyConfiguration(dailyLimitMilliseconds: 60_000), personal: 30_000)
        try await ledger.grantTemporaryBonus(10_000, credential: credential)
        let lease = try await ledger.reservePlayback(eventID: "balance", requestedMilliseconds: 5_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_200)
        let active = try await ledger.playbackAvailability()
        XCTAssertEqual(active.familyRemainingMs, 68_800)
        XCTAssertEqual(active.availableRemainingMs, 38_800)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .paused)
        clock.advance(1_000)
        let paused = try await ledger.playbackAvailability()
        XCTAssertEqual(paused.availableRemainingMs, active.availableRemainingMs)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let settled = try await ledger.playbackAvailability()
        XCTAssertEqual(settled.availableRemainingMs, active.availableRemainingMs)
        await ledger.close()
    }

    func testNextOpeningChangesFromSundayToMondayPolicy() async throws {
        let clock = Clock("2026-11-08T13:00:00Z") // Sunday 21:00 Shanghai
        let ledger = try await make(clock, config: FamilyConfiguration(schedule: FamilySchedule(
            weekday: DailyScheduleWindow(startMinuteOfDay: 600, endMinuteOfDay: 1200),
            weekend: DailyScheduleWindow(startMinuteOfDay: 480, endMinuteOfDay: 1200))))
        let status = try await ledger.playbackAvailability()
        XCTAssertEqual(status.blockedReason, .scheduleBlocked)
        XCTAssertEqual(status.nextScheduleOpeningWallMilliseconds, Clock("2026-11-09T02:00:00Z").wall)
        XCTAssertGreaterThan(status.availableRemainingMs, 0)
        await ledger.close()
    }

    func testWrappedBedtimeAndRestReportedTogether() async throws {
        let clock = Clock("2026-11-08T13:59:59Z")
        let ledger = try await make(clock, config: FamilyConfiguration(continuousLimitMilliseconds: 1_000,
            restMilliseconds: 600_000, schedule: FamilySchedule(bedtimeStartMinute: 1320, bedtimeEndMinute: 420)))
        let lease = try await ledger.reservePlayback(eventID: "bed", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let status = try await ledger.playbackAvailability()
        XCTAssertEqual(status.blockedReason, .resting)
        XCTAssertTrue(status.isScheduleBlocked)
        XCTAssertEqual(status.restRemainingMs, 600_000)
        XCTAssertEqual(status.nextScheduleOpeningWallMilliseconds, Clock("2026-11-08T23:00:00Z").wall)
        await ledger.close()
    }

    func testSpringForwardNextOpeningUsesCivilClockNotElapsedHours() async throws {
        let clock = Clock("2026-03-08T06:50:00Z") // 01:50 New York, clocks jump 02 -> 03
        let ledger = try await make(clock, config: FamilyConfiguration(timeZoneIdentifier: "America/New_York",
            schedule: FamilySchedule(weekend: DailyScheduleWindow(startMinuteOfDay: 180, endMinuteOfDay: 240))))
        let status = try await ledger.playbackAvailability()
        XCTAssertEqual(status.nextScheduleOpeningWallMilliseconds, Clock("2026-03-08T07:00:00Z").wall)
        clock.advance(10 * 60_000)
        let open = try await ledger.playbackAvailability()
        XCTAssertEqual(open.blockedReason, .ready)
        await ledger.close()
    }

    func testFallBackCanReopenRepeatedWindowAtTransition() async throws {
        let clock = Clock("2026-11-01T05:50:00Z") // first 01:50 New York
        let ledger = try await make(clock, config: FamilyConfiguration(timeZoneIdentifier: "America/New_York",
            schedule: FamilySchedule(weekend: DailyScheduleWindow(startMinuteOfDay: 60, endMinuteOfDay: 90))))
        let status = try await ledger.playbackAvailability()
        XCTAssertEqual(status.nextScheduleOpeningWallMilliseconds, Clock("2026-11-01T06:00:00Z").wall)
        await ledger.close()
    }

    func testQuizRemainsRequiredAfterRestButNoRoundIsCreatedByPolling() async throws {
        let clock = Clock("2026-11-08T07:00:00Z")
        let config = FamilyConfiguration(continuousLimitMilliseconds: 1_000, restMilliseconds: 2_000,
            quizRules: QuizRules(quizBeforeFirstWatch: false, quizAfterRest: true))
        let ledger = try await make(clock, config: config)
        let lease = try await ledger.reservePlayback(eventID: "before-rest", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let resting = try await ledger.playbackAvailability()
        XCTAssertEqual(resting.restRemainingMs, 2_000)
        XCTAssertFalse(resting.canStartQuiz)
        clock.advance(2_000)
        let status = try await ledger.playbackAvailability()
        XCTAssertTrue(status.quizRequired)
        XCTAssertTrue(status.canStartQuiz)
        XCTAssertEqual(status.blockedReason, .quizRequired)
        let report = try await ledger.report(lastDays: 1)
        XCTAssertTrue(report.quizAttempts.isEmpty)
        let snapshot = try await ledger.snapshot()
        XCTAssertNil(snapshot.activeLease)
        await ledger.close()
    }

    func testZeroBalanceAndExemptionAreNotMisreportedAsOrdinaryReady() async throws {
        let clock = Clock("2026-11-08T07:00:00Z")
        let ledger = try await make(clock, config: FamilyConfiguration(dailyLimitMilliseconds: 1_000), personal: 1_000)
        let lease = try await ledger.reservePlayback(eventID: "exhaust", requestedMilliseconds: 1_000)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .playing)
        clock.advance(1_000)
        _ = try await ledger.settlePlayback(leaseID: lease.id)
        let status = try await ledger.playbackAvailability()
        XCTAssertEqual(status.availableRemainingMs, 0)
        XCTAssertEqual(status.blockedReason, .budgetExhausted)
        try await ledger.grantDayExemption(credential: credential)
        let exempt = try await ledger.playbackAvailability()
        XCTAssertTrue(exempt.isDayExempt)
        XCTAssertEqual(exempt.blockedReason, .ready)
        await ledger.close()
    }
}
