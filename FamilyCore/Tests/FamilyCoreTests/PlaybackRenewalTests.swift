import Foundation
import XCTest
@testable import FamilyCore

private final class RenewalClock: LedgerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sample: LedgerClockSample

    init(wall: Int64 = 1_735_732_800_000) { // 2025-01-01 noon UTC
        sample = LedgerClockSample(wallMilliseconds: wall, monotonicMilliseconds: 0,
                                   continuityID: "renewal-test-process", monotonicSource: "mach-continuous-v1",
                                   bootSessionID: "renewal-test-boot")
    }
    func now() -> LedgerClockSample {
        lock.lock(); defer { lock.unlock() }
        return sample
    }
    func advance(_ milliseconds: Int64, wallExtra: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        sample = LedgerClockSample(wallMilliseconds: sample.wallMilliseconds + milliseconds + wallExtra,
            monotonicMilliseconds: sample.monotonicMilliseconds + milliseconds,
            continuityID: sample.continuityID, monotonicSource: sample.monotonicSource,
            bootSessionID: sample.bootSessionID)
    }
}

private final class RenewalStore: LedgerCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoint: LedgerCheckpoint?

    func load() throws -> LedgerCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return checkpoint
    }
    func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard checkpoint == expected else { throw LedgerError.checkpointMismatch }
        checkpoint = new
    }
}

private struct RenewalChecker: LedgerAdminAuthorizing {
    func authorize(operation: LedgerAdminOperation, credential: Data) throws {
        guard credential == Data("renewal-test-parent".utf8) else { throw LedgerError.unauthorized }
    }
}

private struct RenewalFixture {
    let directory: URL
    let databaseURL: URL
    let clock: RenewalClock
    let store: RenewalStore
    let ledger: UsageLedger
    let profiles: [ViewerProfile]

    static func make(familyLimit: Int64 = 60_000, personalLimit: Int64 = 60_000,
                     continuousLimit: Int64 = 60_000, wall: Int64 = 1_735_732_800_000) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackRenewal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("ledger.sqlite")
        let clock = RenewalClock(wall: wall)
        let store = RenewalStore()
        let ledger = try UsageLedger(databaseURL: databaseURL, clock: clock,
                                     checkpointStore: store, adminAuthorizer: RenewalChecker())
        let credential = Data("renewal-test-parent".utf8)
        try await ledger.configureFamily(FamilyConfiguration(dailyLimitMilliseconds: familyLimit,
            continuousLimitMilliseconds: continuousLimit, restMilliseconds: 5_000,
            maximumLeaseMilliseconds: 5_000, timeZoneIdentifier: "UTC"), credential: credential)
        let profiles = ["First", "Second"].map {
            ViewerProfile(displayName: $0,
                curriculum: CurriculumProfile(schoolStage: "primary", schoolSystem: "test", grade: 1,
                                              academicYear: "2025", semester: "first"),
                dailyLimitMilliseconds: personalLimit)
        }
        for profile in profiles { try await ledger.upsertProfile(profile, credential: credential) }
        try await ledger.selectViewers(profiles.map(\.id), credential: credential)
        return Self(directory: directory, databaseURL: databaseURL, clock: clock,
                    store: store, ledger: ledger, profiles: profiles)
    }
    func start(requested: Int64 = 5_000, activity: PlaybackActivity = .playing) async throws -> PlaybackLease {
        let lease = try await ledger.reservePlayback(eventID: "initial", requestedMilliseconds: requested)
        try await ledger.setPlaybackActivity(leaseID: lease.id, activity: activity)
        return lease
    }
    func cleanup() async {
        await ledger.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class PlaybackRenewalTests: XCTestCase {
    private func expectError<T>(_ expected: LedgerError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as LedgerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertUsage(_ snapshot: LedgerSnapshot, _ milliseconds: Int64,
                             profiles: [ViewerProfile], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.familyActualMilliseconds, milliseconds, file: file, line: line)
        for profile in profiles {
            XCTAssertEqual(snapshot.personalActualMilliseconds[profile.id], milliseconds, file: file, line: line)
        }
    }

    func testPlayingRenewsEverySecondWithoutPauseAndChargesEveryViewerOnce() async throws {
        let f = try await RenewalFixture.make()
        var lease = try await f.start()
        for round in 1...12 {
            f.clock.advance(1_000)
            let revision = try XCTUnwrap(f.store.load()).revision
            let renewal = try await f.ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: 5_000)
            XCTAssertEqual(renewal.receipt.actualMilliseconds, 1_000)
            XCTAssertEqual(renewal.receipt.leaseID, lease.id)
            XCTAssertEqual(Set(renewal.receipt.viewerIDs), Set(f.profiles.map(\.id)))
            lease = try XCTUnwrap(renewal.nextLease)
            XCTAssertEqual(lease.reservedMilliseconds, 5_000)
            XCTAssertEqual(lease.expiresAtMonotonicMilliseconds, Int64(round) * 1_000 + 5_000)
            // One prepare commit and one atomic settlement/reservation commit, not two mutations.
            XCTAssertEqual(try XCTUnwrap(f.store.load()).revision, revision + 2)
            let snapshot = try await f.ledger.snapshot()
            assertUsage(snapshot, Int64(round) * 1_000, profiles: f.profiles)
            XCTAssertEqual(snapshot.continuousActualMilliseconds, Int64(round) * 1_000)
            XCTAssertEqual(snapshot.activeLease, lease)
            XCTAssertEqual(snapshot.familyFrozenMilliseconds, 0)
        }
        f.clock.advance(1_000)
        let receipt = try await f.ledger.settlePlayback(leaseID: lease.id)
        XCTAssertEqual(receipt.actualMilliseconds, 1_000)
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 13_000, profiles: f.profiles)
        await f.cleanup()
    }

    func testLostResponseRetryIsIdempotentButAncestorCannotReplay() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000)
        let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        let checkpoint = try f.store.load()
        let duplicate = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try f.store.load(), checkpoint)
        await expectError(.invalidLease) {
            try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 4_000)
        }
        f.clock.advance(500)
        let delayedDuplicate = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(delayedDuplicate, first) // Same deadline, not a refreshed playable grant.
        f.clock.advance(500)
        let next = try XCTUnwrap(first.nextLease)
        let second = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(second.receipt.actualMilliseconds, 1_000)
        await expectError(.invalidLease) {
            try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        }
        let originalReceipt = try await f.ledger.settlePlayback(leaseID: initial.id)
        XCTAssertEqual(originalReceipt, first.receipt)
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 2_000, profiles: f.profiles)
        XCTAssertEqual(snapshot.activeLease, second.nextLease)
        await f.cleanup()
    }

    func testRetryRejectsSettledSuccessorAndOrdinarySettlement() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000)
        let renewal = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        let next = try XCTUnwrap(renewal.nextLease)
        f.clock.advance(1_000)
        _ = try await f.ledger.settlePlayback(leaseID: next.id)
        for id in [initial.id, next.id] {
            await expectError(.invalidLease) {
                try await f.ledger.renewPlayback(leaseID: id, requestedMilliseconds: 5_000)
            }
        }
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 2_000, profiles: f.profiles)
        XCTAssertNil(snapshot.activeLease)
        await f.cleanup()
    }

    func testRetryRejectsExpiredSuccessorWithoutRefundOrDoubleCharge() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000)
        let renewal = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        f.clock.advance(5_001)
        await expectError(.invalidLease) {
            try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        }
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 1_000, profiles: f.profiles)
        XCTAssertNil(snapshot.activeLease)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 5_000)
        XCTAssertEqual(snapshot.frozenReservations.first?.leaseID, renewal.nextLease?.id)
        await f.cleanup()
    }

    func testReopenFreezesSuccessorAndPreservesRenewalReceipt() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000)
        let renewal = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        await f.ledger.close()
        let reopened = try UsageLedger(databaseURL: f.databaseURL, clock: f.clock,
                                       checkpointStore: f.store, adminAuthorizer: RenewalChecker())
        await expectError(.invalidLease) {
            try await reopened.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        }
        let receipt = try await reopened.settlePlayback(leaseID: initial.id)
        XCTAssertEqual(receipt, renewal.receipt)
        let snapshot = try await reopened.snapshot()
        assertUsage(snapshot, 1_000, profiles: f.profiles)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 5_000)
        await reopened.close()
        await f.cleanup()
    }

    func testFamilyQuotaShortensDeadlineAndTerminalRetryNeverReissues() async throws {
        let f = try await RenewalFixture.make(familyLimit: 2_500)
        let initial = try await f.start()
        XCTAssertEqual(initial.reservedMilliseconds, 2_500)
        f.clock.advance(1_000)
        let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        let next = try XCTUnwrap(first.nextLease)
        XCTAssertEqual(next.reservedMilliseconds, 1_500)
        XCTAssertEqual(next.expiresAtMonotonicMilliseconds, 2_500)
        f.clock.advance(1_500)
        let terminal = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(terminal.receipt.actualMilliseconds, 1_500)
        XCTAssertNil(terminal.nextLease)
        let duplicate = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(duplicate, terminal)
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 2_500, profiles: f.profiles)
        XCTAssertNil(snapshot.activeLease)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 0)
        // Even on a fresh day this retry must not turn a terminal result into a new lease.
        f.clock.advance(86_400_000)
        let nextDayRetry = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(nextDayRetry, terminal)
        await f.cleanup()
    }

    func testPersonalQuotaAlsoEndsRenewalWithoutRollingBackUsage() async throws {
        let f = try await RenewalFixture.make(personalLimit: 2_000)
        let initial = try await f.start()
        f.clock.advance(1_000)
        let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        let next = try XCTUnwrap(first.nextLease)
        XCTAssertEqual(next.reservedMilliseconds, 1_000)
        XCTAssertEqual(next.expiresAtMonotonicMilliseconds, 2_000)
        f.clock.advance(1_000)
        let terminal = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertNil(terminal.nextLease)
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 2_000, profiles: f.profiles)
        await f.cleanup()
    }

    func testContinuousLimitCommitsReceiptAndStartsRestWithNoSuccessor() async throws {
        let f = try await RenewalFixture.make(continuousLimit: 2_500)
        let initial = try await f.start()
        f.clock.advance(1_000)
        let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        let next = try XCTUnwrap(first.nextLease)
        XCTAssertEqual(next.reservedMilliseconds, 1_500)
        XCTAssertEqual(next.expiresAtMonotonicMilliseconds, 2_500)
        f.clock.advance(1_500)
        let terminal = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(terminal.receipt.actualMilliseconds, 1_500)
        XCTAssertNil(terminal.nextLease)
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 2_500, profiles: f.profiles)
        XCTAssertEqual(snapshot.continuousActualMilliseconds, 2_500)
        XCTAssertEqual(snapshot.remainingRestMilliseconds, 5_000)
        XCTAssertNil(snapshot.activeLease)
        f.clock.advance(5_000)
        let retry = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(retry, terminal)
        let afterRest = try await f.ledger.snapshot()
        XCTAssertEqual(afterRest.remainingRestMilliseconds, 0)
        XCTAssertEqual(afterRest.continuousActualMilliseconds, 0)
        XCTAssertNil(afterRest.activeLease)
        await f.cleanup()
    }

    func testLateRenewalPersistsFreezeBeforeRejecting() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(5_001)
        await expectError(.leaseExpired) {
            try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        }
        await expectError(.leaseExpired) { try await f.ledger.settlePlayback(leaseID: initial.id) }
        let snapshot = try await f.ledger.snapshot()
        assertUsage(snapshot, 0, profiles: f.profiles)
        XCTAssertNil(snapshot.activeLease)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 5_000)
        for profile in f.profiles { XCTAssertEqual(snapshot.personalFrozenMilliseconds[profile.id], 5_000) }
        await f.cleanup()
    }

    func testClockAnomalyPersistsFreezeBeforeRejecting() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000, wallExtra: 10_000)
        await expectError(.clockUntrusted) {
            try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        }
        let snapshot = try await f.ledger.snapshot()
        XCTAssertFalse(snapshot.clockIsTrusted)
        XCTAssertNil(snapshot.activeLease)
        XCTAssertEqual(snapshot.familyFrozenMilliseconds, 5_000)
        assertUsage(snapshot, 0, profiles: f.profiles)
        await f.cleanup()
    }

    func testInvalidRequestsRejectBeforeSettlementAndReservedNamespaceCannotBeForged() async throws {
        let f = try await RenewalFixture.make()
        let initial = try await f.start()
        f.clock.advance(1_000)
        let checkpoint = try f.store.load()
        for request: Int64 in [0, -1, 86_400_001, Int64.max] {
            await expectError(.invalidInput("invalid lease request")) {
                try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: request)
            }
        }
        XCTAssertEqual(try f.store.load(), checkpoint)
        await expectError(.invalidInput("invalid lease request")) {
            try await f.ledger.reservePlayback(eventID: "renew:" + initial.id.uuidString, requestedMilliseconds: 5_000)
        }
        await expectError(.invalidLease) {
            try await f.ledger.renewPlayback(leaseID: UUID(), requestedMilliseconds: 5_000)
        }
        let before = try await f.ledger.snapshot()
        assertUsage(before, 0, profiles: f.profiles)
        XCTAssertEqual(before.activeLease, initial)
        let renewal = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 1)
        XCTAssertEqual(renewal.receipt.actualMilliseconds, 1_000) // Request is never the charge.
        XCTAssertEqual(renewal.nextLease?.reservedMilliseconds, 1)
        XCTAssertEqual(renewal.nextLease?.expiresAtMonotonicMilliseconds, 1_001)
        await f.cleanup()
    }

    func testPausedAndBufferingActivitySurviveRenewalAndOnlyPlayingEdgesCharge() async throws {
        for activity in [PlaybackActivity.paused, .buffering] {
            let f = try await RenewalFixture.make()
            let initial = try await f.start(activity: activity)
            f.clock.advance(1_000)
            let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
            XCTAssertEqual(first.receipt.actualMilliseconds, 0)
            let next = try XCTUnwrap(first.nextLease)
            f.clock.advance(1_000)
            try await f.ledger.setPlaybackActivity(leaseID: next.id, activity: .playing)
            f.clock.advance(400)
            try await f.ledger.setPlaybackActivity(leaseID: next.id, activity: activity)
            f.clock.advance(600)
            let second = try await f.ledger.renewPlayback(leaseID: next.id, requestedMilliseconds: 5_000)
            XCTAssertEqual(second.receipt.actualMilliseconds, 400)
            f.clock.advance(1_000)
            let final = try await f.ledger.settlePlayback(leaseID: XCTUnwrap(second.nextLease).id)
            XCTAssertEqual(final.actualMilliseconds, 0)
            let snapshot = try await f.ledger.snapshot()
            assertUsage(snapshot, 400, profiles: f.profiles)
            await f.cleanup()
        }
    }

    func testMidnightProjectsOldDayBeforeReservingNextDay() async throws {
        // 2025-01-01 23:59:59 UTC. Old day's quota is exhausted exactly at midnight.
        let f = try await RenewalFixture.make(familyLimit: 1_000, wall: 1_735_775_999_000)
        let initial = try await f.start()
        XCTAssertEqual(initial.reservedMilliseconds, 1_000)
        f.clock.advance(1_000)
        let first = try await f.ledger.renewPlayback(leaseID: initial.id, requestedMilliseconds: 5_000)
        XCTAssertEqual(first.receipt.day, 20_250_101)
        XCTAssertEqual(first.receipt.actualMilliseconds, 1_000)
        let next = try XCTUnwrap(first.nextLease)
        XCTAssertEqual(next.reservedMilliseconds, 1_000)
        XCTAssertEqual(next.expiresAtMonotonicMilliseconds, 2_000)
        let midnight = try await f.ledger.snapshot()
        XCTAssertEqual(midnight.day, 20_250_102)
        assertUsage(midnight, 0, profiles: f.profiles)
        XCTAssertEqual(midnight.continuousActualMilliseconds, 1_000)
        f.clock.advance(500)
        let receipt = try await f.ledger.settlePlayback(leaseID: next.id)
        XCTAssertEqual(receipt.day, 20_250_102)
        XCTAssertEqual(receipt.actualMilliseconds, 500)
        await f.ledger.close()
        // Inspect only this fixture's existing projections after releasing the ledger's lock.
        let db = try LedgerDatabase(path: f.databaseURL.path)
        XCTAssertEqual(try db.scalar("SELECT actual_ms FROM family_daily_usage WHERE day=20250101"), "1000")
        XCTAssertEqual(try db.scalar("SELECT actual_ms FROM family_daily_usage WHERE day=20250102"), "500")
        for profile in f.profiles {
            XCTAssertEqual(try db.scalar("SELECT actual_ms FROM child_daily_usage WHERE day=20250101 AND profile_id=?", [profile.id.uuidString]), "1000")
            XCTAssertEqual(try db.scalar("SELECT actual_ms FROM child_daily_usage WHERE day=20250102 AND profile_id=?", [profile.id.uuidString]), "500")
        }
        XCTAssertEqual(try db.scalar("SELECT day FROM watch_sessions WHERE lease_id=?", [initial.id.uuidString]), "20250101")
        XCTAssertEqual(try db.scalar("SELECT day FROM watch_sessions WHERE lease_id=?", [next.id.uuidString]), "20250102")
        db.close()
        await f.cleanup()
    }
}
