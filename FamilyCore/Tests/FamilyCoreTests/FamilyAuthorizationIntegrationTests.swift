import Foundation
import XCTest
@testable import FamilyCore

final class FamilyAuthorizationIntegrationTests: XCTestCase {
    private final class MemoryStore: SecureStore, @unchecked Sendable {
        private var values: [String: Data] = [:]
        private let lock = NSLock()
        func read(key: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }
        func write(_ data: Data, key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            values[key] = data
        }
    }

    func testRealParentalCapabilitiesProtectLedgerAndPreserveUsageWhenSwitching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore()
        let auth = ParentalAuth(store: store)
        try await auth.setup(pin: "647291")
        let ledger = try UsageLedger(databaseURL: directory.appendingPathComponent("usage.sqlite"),
            checkpointStore: SecureLedgerCheckpointStore(store: store),
            adminAuthorizer: auth.ledgerAuthorizer)
        let curriculum = CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
            academicYear: "2026-2027", semester: "上")
        let child = ViewerProfile(displayName: "Synthetic A", curriculum: curriculum,
            dailyLimitMilliseconds: 5_400_000)
        do {
            try await ledger.upsertProfile(child, credential: Data(repeating: 0, count: 32))
            XCTFail("Forged authorization must not create a profile")
        } catch is ParentalAuthError {}

        let profiles = try await auth.authenticate(pin: "647291", context: .manageProfiles)
        try await ledger.upsertProfile(child, credential: profiles.credential)
        do {
            try await ledger.selectViewers([child.id], credential: profiles.credential)
            XCTFail("Profile management authorization must not select viewers")
        } catch let error as ParentalAuthError {
            XCTAssertEqual(error, .wrongContext)
        }

        let session = try await auth.authenticate(pin: "647291", context: .manageSession)
        try await ledger.selectViewers([child.id], credential: session.credential)
        let before = try await ledger.snapshot()
        let support = try await auth.authenticate(pin: "647291", context: .support)
        do {
            try await ledger.configureFamily(FamilyConfiguration(), credential: support.credential)
            XCTFail("Support page permission must not change limits")
        } catch let error as ParentalAuthError {
            XCTAssertEqual(error, .wrongContext)
        }
        let after = try await ledger.snapshot()
        XCTAssertEqual(after.activeViewerIDs, [child.id])
        XCTAssertEqual(before.familyActualMilliseconds, after.familyActualMilliseconds)
        XCTAssertEqual(before.day, after.day)
        await auth.revokeAuthorizations()
        do {
            try await ledger.selectViewers([child.id], credential: session.credential)
            XCTFail("Revoked session permission must be rejected")
        } catch is ParentalAuthError {}
        await ledger.close()
    }
}
