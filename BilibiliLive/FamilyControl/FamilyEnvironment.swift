import FamilyCore
import Foundation

@MainActor
final class FamilyEnvironment: ObservableObject {
    static let shared = FamilyEnvironment()

    let auth: ParentalAuth
    @Published private(set) var ledger: UsageLedger?
    @Published private(set) var snapshot: LedgerSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReady = false
    @Published private(set) var childModeActive = true
    @Published private(set) var isMaintaining = false
    /// The database file is gone but a secure checkpoint survived (typically a
    /// reinstall). Only an explicit parent-authorized reset may clear it.
    @Published private(set) var ledgerNeedsReset = false
    private let secureStore: KeychainSecureStore
    private let checkpointStore: SecureLedgerCheckpointStore
    private let storageDirectoryName: String
    private let modePolicy: FamilyModePolicy?
    private var startTask: Task<Void, Never>?

    private init() {
        var namespace = "ATV-Bilibili-Family.ParentalAuth.v1"
        var directory = "FamilyLedger"
        var isolatedTest = false
        var testChildMode = false
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--family-preview"),
           let index = arguments.firstIndex(of: "--family-test-store"), index + 1 < arguments.count,
           let identifier = UUID(uuidString: arguments[index + 1]) {
            namespace += ".test." + identifier.uuidString
            directory += "-test-" + identifier.uuidString
            isolatedTest = true
            testChildMode = !arguments.contains("--family-probe-adult")
                && (arguments.contains("--family-probe-media") || arguments.contains("--family-probe-quiz"))
        }
        #endif
        let store = KeychainSecureStore(service: namespace)
        secureStore = store
        checkpointStore = SecureLedgerCheckpointStore(store: store)
        storageDirectoryName = directory
        let authority = ParentalAuth(store: store)
        auth = authority
        do {
            let mode = try FamilyModePolicy(store: store, authorizer: authority.ledgerAuthorizer,
                legacyChildActive: isolatedTest ? testChildMode : UserDefaults.standard.bool(forKey: FamilyModeState.legacyDefaultsKey))
            modePolicy = mode
            FamilyModeState.configure(mode)
            childModeActive = mode.isChildActive()
        } catch {
            modePolicy = nil
            FamilyModeState.configure(nil)
            errorMessage = "家庭权限存储不可用，儿童限制保持开启。"
        }
    }

    func start() async {
        guard !isMaintaining else { return }
        if let startTask { await startTask.value; return }
        guard !isReady else { return }
        let task = Task { @MainActor [self] in await openLedger() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func openLedger() async {
        defer { isReady = true }
        guard modePolicy != nil else { return }
        do {
            let directory = try storageDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let service = try UsageLedger(databaseURL: directory.appendingPathComponent("usage.sqlite"),
                checkpointStore: checkpointStore,
                adminAuthorizer: auth.ledgerAuthorizer, reportRequiresAuthorization: true)
            ledger = service
            snapshot = try await service.snapshot()
            ledgerNeedsReset = false
            errorMessage = nil
        } catch {
            if let ledger { await ledger.close() }
            ledger = nil
            snapshot = nil
            let missingDatabase = (error as? LedgerError) == .missingDatabase
            ledgerNeedsReset = missingDatabase
            NSLog("FamilyEnvironment open failed: %@", String(describing: error))
            errorMessage = missingDatabase
                ? "本机家庭账本文件已丢失（可能刚重装应用）。历史无法自动恢复；家长可在“家庭概览”创建新账本，或先尝试恢复备份。"
                : "家庭账本不可用，儿童播放保持锁定。请由家长在“备份与恢复”检查或恢复备份。"
        }
    }

    func refresh() async {
        await start()
        guard !isMaintaining, let ledger else { return }
        do {
            snapshot = try await ledger.snapshot()
            childModeActive = FamilyModeState.childActive
            errorMessage = nil
        } catch {
            NSLog("FamilyEnvironment refresh failed: %@", String(describing: error))
            errorMessage = "读取家庭账本失败，儿童播放保持锁定。请由家长在“家庭概览”检查家庭状态。"
        }
    }

    /// Editors must distinguish a successful durable save/readback from a stale
    /// published snapshot. Ordinary polling may still use refresh()'s error UI.
    @discardableResult
    func refreshVerified() async throws -> LedgerSnapshot {
        await start()
        guard !isMaintaining, let ledger else { throw LedgerError.closed }
        let current = try await ledger.snapshot()
        guard !isMaintaining, self.ledger === ledger else { throw LedgerError.closed }
        snapshot = current
        childModeActive = FamilyModeState.childActive
        errorMessage = nil
        return current
    }

    /// Parent confirmation establishes a new measurement anchor, never a new day
    /// or a fresh budget. Old child players and their loading work stay revoked.
    @discardableResult
    func confirmClock(authorization: ParentalAuthorization,
                      isCurrent: () -> Bool = { true }) async throws -> LedgerSnapshot {
        try await auth.validate(authorization, for: .recovery)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard !isMaintaining else { throw LedgerError.closed }
        await start()
        // start() can suspend: another maintenance operation may have won meanwhile.
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard !isMaintaining, let ledger else { throw LedgerError.closed }
        isMaintaining = true
        defer { isMaintaining = false }
        PlaybackCoordinator.shared.beginClockRecoveryMaintenance()
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        try await auth.validate(authorization, for: .recovery)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        do {
            try await ledger.reanchorClock(credential: authorization.credential)
            // refresh() intentionally refuses to run during maintenance. Read the
            // authoritative post-operation state here, before reopening the gate.
            let current = try await ledger.snapshot()
            snapshot = current
            childModeActive = FamilyModeState.childActive
            errorMessage = nil
            return current
        } catch {
            // Do not report a cached "normal" state after a failed confirmation.
            snapshot = try? await ledger.snapshot()
            errorMessage = "时间确认未完成，儿童播放仍按当前账本状态限制。"
            throw error
        }
    }

    func setChildMode(_ active: Bool, authorization: ParentalAuthorization) async throws {
        guard !isMaintaining else { throw LedgerError.closed }
        try await auth.validate(authorization, for: .temporaryOverride)
        await start()
        guard let ledger, let modePolicy else { throw LedgerError.securityStoreUnavailable }
        if active {
            // Legacy one-child profiles were not automatically selected.
            try await ledger.selectSoleViewerIfNeeded(credential: authorization.credential)
            let current = try await ledger.snapshot()
            guard current.clockIsTrusted else {
                throw LedgerError.invalidInput("设备时间需要确认：请打开“家长控制”→“家庭概览”→“确认设备时间”。")
            }
            guard !current.activeViewerIDs.isEmpty else {
                throw LedgerError.invalidInput("还没有选择观看的孩子，请打开“孩子管理”选择当前观看者。")
            }
        }
        PlaybackCoordinator.shared.modeWillChange(toChild: active)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        try await auth.validate(authorization, for: .temporaryOverride)
        try await ledger.recordParentalAction(operation: "child-mode-change",
            object: active ? "enabled" : "disabled", credential: authorization.credential)
        do {
            try modePolicy.setChildActive(active, credential: authorization.credential)
        } catch {
            childModeActive = FamilyModeState.childActive
            BiliBiliUpnpDMR.shared.stop()
            throw error
        }
        childModeActive = FamilyModeState.childActive
        if childModeActive { BiliBiliUpnpDMR.shared.stop() }
        else { BiliBiliUpnpDMR.shared.start() }
        await refresh()
    }

    func exportBackup(authorization: ParentalAuthorization) async throws -> URL {
        try await auth.validate(authorization, for: .recovery)
        guard !isMaintaining else { throw LedgerError.closed }
        await start()
        guard let ledger else { throw LedgerError.closed }
        isMaintaining = true
        defer { isMaintaining = false }
        PlaybackCoordinator.shared.modeWillChange(toChild: childModeActive)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        let state = try await ledger.backupState()
        guard !state.hasActiveLease else { throw LedgerError.leaseAlreadyActive }
        try await auth.validate(authorization, for: .recovery)
        await closeLedger()
        do {
            let url = try FamilyBackupManager.export(databaseDirectory: storageDirectory(),
                checkpoint: state.checkpoint, store: secureStore)
            await openLedger()
            guard self.ledger != nil else { throw LedgerError.checkpointMismatch }
            return url
        } catch {
            await openLedger()
            throw error
        }
    }

    /// Recovery is available even when the live database is missing or cannot open.
    func restoreBackup(authorization: ParentalAuthorization) async throws {
        try await auth.validate(authorization, for: .recovery)
        guard !isMaintaining else { throw LedgerError.closed }
        isMaintaining = true
        defer { isMaintaining = false }
        PlaybackCoordinator.shared.modeWillChange(toChild: childModeActive)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        await closeLedger()
        do {
            try await FamilyBackupManager.restore(databaseDirectory: storageDirectory(), store: secureStore,
                checkpoints: checkpointStore,
                authorizer: auth.ledgerAuthorizer, credential: authorization.credential)
            await openLedger()
            guard ledger != nil else { throw LedgerError.checkpointMismatch }
        } catch {
            await openLedger()
            throw error
        }
    }

    /// Explicit parent recovery for a reinstall or a deliberately removed live
    /// database. The stale checkpoint is cleared only after the parent authorizes
    /// the reset; backup files are preserved and any leftover database is moved
    /// aside for inspection rather than deleted.
    @discardableResult
    func resetMissingLedger(authorization: ParentalAuthorization) async throws -> LedgerSnapshot {
        try await auth.validate(authorization, for: .recovery)
        guard !isMaintaining, ledgerNeedsReset else {
            throw LedgerError.invalidInput("当前没有需要创建新账本的缺失状态。")
        }
        isMaintaining = true
        defer { isMaintaining = false }
        PlaybackCoordinator.shared.modeWillChange(toChild: childModeActive)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        await closeLedger()
        let directory = try storageDirectory()
        if FileManager.default.fileExists(atPath: directory.path) {
            let quarantine = directory.deletingLastPathComponent()
                .appendingPathComponent("FamilyLedger-reset-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: quarantine)
        }
        // Re-validate immediately before the destructive checkpoint change.
        try await auth.validate(authorization, for: .recovery)
        try checkpointStore.clear()
        await openLedger()
        guard let snapshot else { throw LedgerError.missingDatabase }
        return snapshot
    }

    private func closeLedger() async {
        if let startTask { await startTask.value }
        if let ledger { await ledger.close() }
        ledger = nil
        snapshot = nil
        isReady = false
        startTask = nil
    }

    /// Used only to tell the parent whether a restore is possible.
    func latestBackupDate() -> Date? {
        guard let directory = try? storageDirectory() else { return nil }
        return FamilyBackupManager.latestBackupDate(databaseDirectory: directory)
    }

    private func storageDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }
}
