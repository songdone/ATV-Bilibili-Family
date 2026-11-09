import Foundation
import XCTest
@testable import FamilyCore

final class SecureLedgerCheckpointStoreTests: XCTestCase {
    private final class MemoryStore: SecureStore, @unchecked Sendable {
        var values: [String: Data] = [:]
        var failsWrites = false
        func read(key: String) throws -> Data? { values[key] }
        func write(_ data: Data, key: String) throws {
            if failsWrites { throw LedgerError.securityStoreUnavailable }
            values[key] = data
        }
    }

    private final class ResettableMemoryStore: SecureStore, ResettableSecureStore, @unchecked Sendable {
        var values: [String: Data] = [:]
        func read(key: String) throws -> Data? { values[key] }
        func write(_ data: Data, key: String) throws { values[key] = data }
        func delete(key: String) throws { values.removeValue(forKey: key) }
    }

    func testClearRemovesOnlyTheCheckpointOnResettableStore() throws {
        let memory = ResettableMemoryStore()
        let store = SecureLedgerCheckpointStore(store: memory)
        let checkpoint = LedgerCheckpoint(databaseID: UUID(), revision: 1, commitToken: UUID())
        try store.compareAndSwap(expected: nil, new: checkpoint)
        try store.clear()
        XCTAssertNil(try store.load())
        // A fresh ledger can now start without a stale checkpoint.
        try store.compareAndSwap(expected: nil, new: checkpoint)
        XCTAssertEqual(try store.load(), checkpoint)
    }

    func testClearRefusesNonResettableStore() {
        let store = SecureLedgerCheckpointStore(store: MemoryStore())
        XCTAssertThrowsError(try store.clear()) { error in
            XCTAssertEqual(error as? LedgerError, .securityStoreUnavailable)
        }
    }

    func testCompareAndSwapPersistsAcrossAdapterRecreation() throws {
        let memory = MemoryStore()
        let store = SecureLedgerCheckpointStore(store: memory)
        XCTAssertNil(try store.load())
        let checkpoint = LedgerCheckpoint(databaseID: UUID(), revision: 1, commitToken: UUID())
        try store.compareAndSwap(expected: nil, new: checkpoint)
        XCTAssertEqual(try SecureLedgerCheckpointStore(store: memory).load(), checkpoint)
        XCTAssertThrowsError(try store.compareAndSwap(expected: nil, new: checkpoint))
    }

    func testCorruptCheckpointNeverBecomesFreshInstallation() throws {
        let memory = MemoryStore()
        memory.values["family-ledger-checkpoint-v1"] = Data("corrupt".utf8)
        let store = SecureLedgerCheckpointStore(store: memory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.compareAndSwap(expected: nil,
            new: LedgerCheckpoint(databaseID: UUID(), revision: 0, commitToken: UUID())))
    }

    func testConcurrentAdaptersCannotBothReplaceTheSameCheckpoint() throws {
        final class SlowStore: SecureStore, @unchecked Sendable {
            let lock = NSLock()
            var data: Data?
            func read(key: String) throws -> Data? {
                lock.lock()
                let value = data
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.02)
                return value
            }
            func write(_ data: Data, key: String) throws {
                lock.lock()
                self.data = data
                lock.unlock()
            }
        }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var successes = 0
            func record() { lock.lock(); successes += 1; lock.unlock() }
        }
        let memory = SlowStore()
        let adapters = [SecureLedgerCheckpointStore(store: memory), SecureLedgerCheckpointStore(store: memory)]
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try adapters[index].compareAndSwap(expected: nil,
                    new: LedgerCheckpoint(databaseID: UUID(), revision: 0, commitToken: UUID()))
                results.record()
            } catch {}
        }
        XCTAssertEqual(results.successes, 1)
    }

    func testFailedWriteDoesNotReportSuccess() throws {
        let memory = MemoryStore()
        memory.failsWrites = true
        let store = SecureLedgerCheckpointStore(store: memory)
        XCTAssertThrowsError(try store.compareAndSwap(expected: nil,
            new: LedgerCheckpoint(databaseID: UUID(), revision: 0, commitToken: UUID())))
        XCTAssertNil(try store.load())
    }
}
