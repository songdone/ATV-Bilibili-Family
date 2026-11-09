import Foundation
import XCTest
@testable import FamilyCore

final class FamilyModePolicyTests: XCTestCase {
    private final class Store: SecureStore, @unchecked Sendable {
        var values: [String: Data] = [:]
        var fail = false
        func read(key: String) throws -> Data? {
            if fail { throw LedgerError.securityStoreUnavailable }
            return values[key]
        }
        func write(_ data: Data, key: String) throws {
            if fail { throw LedgerError.securityStoreUnavailable }
            values[key] = data
        }
    }
    private struct Authorizer: LedgerAdminAuthorizing {
        func authorize(operation: LedgerAdminOperation, credential: Data) throws {
            guard operation == .temporaryOverride, credential == Data([1]) else { throw LedgerError.unauthorized }
        }
    }

    func testFreshAdultDefaultAndLegacyChildMigration() throws {
        XCTAssertFalse(try FamilyModePolicy(store: Store(), authorizer: Authorizer()).isChildActive())
        XCTAssertTrue(try FamilyModePolicy(store: Store(), authorizer: Authorizer(), legacyChildActive: true).isChildActive())
    }

    func testUnprivilegedSwitchRejectedAndChildSettingSurvivesRecreation() throws {
        let store = Store()
        let policy = try FamilyModePolicy(store: store, authorizer: Authorizer())
        XCTAssertThrowsError(try policy.setChildActive(true, credential: Data()))
        try policy.setChildActive(true, credential: Data([1]))
        XCTAssertThrowsError(try policy.setChildActive(false, credential: Data()))
        let reopened = try FamilyModePolicy(store: store, authorizer: Authorizer())
        XCTAssertTrue(reopened.isChildActive())
        try reopened.setChildActive(false, credential: Data([1]))
        XCTAssertFalse(reopened.isChildActive())
    }

    func testMissingRecordAndReadFailureFailClosed() throws {
        let store = Store()
        let policy = try FamilyModePolicy(store: store, authorizer: Authorizer())
        store.values["family-mode.record.v1"] = nil
        XCTAssertTrue(policy.isChildActive())
        XCTAssertThrowsError(try policy.setChildActive(false, credential: Data([1])))
        XCTAssertThrowsError(try FamilyModePolicy(store: store, authorizer: Authorizer()))
        let other = Store()
        let active = try FamilyModePolicy(store: other, authorizer: Authorizer())
        other.fail = true
        XCTAssertTrue(active.isChildActive())
    }

    func testBackupAuthenticatedRoundTripTamperAndMissingKey() throws {
        let store = Store()
        let archive = LedgerBackupArchive(store: store)
        var database = Data("SQLite format 3\0".utf8)
        database.append(Data(repeating: 0, count: 300))
        let checkpoint = LedgerCheckpoint(databaseID: UUID(), revision: 9, commitToken: UUID())
        let sealed = try archive.seal(LedgerBackupSnapshot(checkpoint: checkpoint, database: database))
        let restored = try archive.open(sealed)
        XCTAssertEqual(restored.database, database)
        XCTAssertEqual(restored.checkpoint, checkpoint)
        var corrupted = sealed
        corrupted[corrupted.count / 2] ^= 1
        XCTAssertThrowsError(try archive.open(corrupted))
        let emptyStore = Store()
        XCTAssertThrowsError(try LedgerBackupArchive(store: emptyStore).open(sealed))
        XCTAssertTrue(emptyStore.values.isEmpty, "Restore must not generate a replacement key")
    }
}
