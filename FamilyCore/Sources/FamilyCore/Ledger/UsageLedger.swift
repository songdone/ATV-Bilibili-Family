import Foundation

private struct ActiveLease: Codable {
    var lease: PlaybackLease
    var requestedMilliseconds: Int64
    var activity: PlaybackActivity = .paused
    var lastTick: Int64
    var actualMilliseconds: Int64 = 0
}

// Keep renewal provenance private, in the existing receipt JSON. Plain receipts remain readable
// by UsageReceipt (including V1 projection backfill); no schema or caller-supplied link is needed.
private struct StoredUsageReceipt: Codable {
    let receipt: UsageReceipt
    let renewalRequestedMilliseconds: Int64?

    init(receipt: UsageReceipt, renewalRequestedMilliseconds: Int64? = nil) {
        self.receipt = receipt
        self.renewalRequestedMilliseconds = renewalRequestedMilliseconds
    }
    private enum CodingKeys: String, CodingKey { case renewalRequestedMilliseconds }
    init(from decoder: Decoder) throws {
        receipt = try UsageReceipt(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        renewalRequestedMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .renewalRequestedMilliseconds)
    }
    func encode(to encoder: Encoder) throws {
        try receipt.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(renewalRequestedMilliseconds, forKey: .renewalRequestedMilliseconds)
    }
}

private struct LedgerState: Codable {
    var checkpoint: LedgerCheckpoint
    var configuration = FamilyConfiguration()
    var profiles: [String: ViewerProfile] = [:]
    var viewers: [UUID] = []
    var day: Int64
    var logicalWall: Int64
    var clockAnchor: LedgerClockSample
    var lastClock: LedgerClockSample
    var clockTrusted = true
    var clockRecoveryReason: LedgerClockRecoveryReason?
    // New boot failures and a failed legacy compatibility attempt remain latched.
    // Missing means a pre-drift-policy payload, not permission to skip evidence.
    var kernelBootChangeRequiresParent = false
    var familyActual: Int64 = 0
    var personalActual: [String: Int64] = [:]
    var continuousActual: Int64 = 0
    var continuousFrozen: Int64 = 0
    var restRemaining: Int64 = 0
    var restID: UUID?
    var restStartedLogicalWall: Int64?
    var active: ActiveLease?
    var frozen: [FrozenReservation] = []
    var grants: [TemporaryGrant] = []
    var familyBonusMilliseconds: Int64 = 0
    var personalBonus: [String: Int64] = [:]
    var dayExemptUntilLogicalWall: Int64 = 0
    var quizSkipUntilLogicalWall: Int64 = 0
    var quizPassedToday: [String: Bool] = [:]
    var quizRewardCountToday: [String: Int] = [:]
    var familyQuizRewardsToday = 0
    var restNeedingQuiz: [String: Bool] = [:]
    var familyQuizRewardMilliseconds: Int64 = 0
    var personalQuizRewardMilliseconds: [String: Int64] = [:]
    var familyRecoveryFrozen: Int64 = 0
    var personalRecoveryFrozen: [String: Int64] = [:]
    var recoveryQuarantinedDay: Int64?
    // Calendar attribution and budget consumption diverge after recovery. Carry
    // keeps the debit without reporting previously watched time on another day.
    var calendarAccountingAligned = true
    var familyReportBaseline: Int64 = 0
    var personalReportBaseline: [String: Int64] = [:]
    var familyFrozenCarry: Int64 = 0
    var personalFrozenCarry: [String: Int64] = [:]

    init(checkpoint: LedgerCheckpoint, day: Int64, logicalWall: Int64,
         clockAnchor: LedgerClockSample, lastClock: LedgerClockSample) {
        self.checkpoint = checkpoint; self.day = day; self.logicalWall = logicalWall
        self.clockAnchor = clockAnchor; self.lastClock = lastClock
    }
    private enum CodingKeys: String, CodingKey {
        case checkpoint, configuration, profiles, viewers, day, logicalWall, clockAnchor, lastClock, clockTrusted
        case clockRecoveryReason, kernelBootChangeRequiresParent
        case familyActual, personalActual, continuousActual, continuousFrozen, restRemaining, restID, restStartedLogicalWall, active, frozen
        case grants, familyBonusMilliseconds, personalBonus, dayExemptUntilLogicalWall, quizSkipUntilLogicalWall
        case quizPassedToday, quizRewardCountToday, familyQuizRewardsToday, restNeedingQuiz
        case familyQuizRewardMilliseconds, personalQuizRewardMilliseconds, familyRecoveryFrozen, personalRecoveryFrozen, recoveryQuarantinedDay
        case calendarAccountingAligned, familyReportBaseline, personalReportBaseline, familyFrozenCarry, personalFrozenCarry
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkpoint = try c.decode(LedgerCheckpoint.self, forKey: .checkpoint)
        day = try c.decode(Int64.self, forKey: .day)
        logicalWall = try c.decode(Int64.self, forKey: .logicalWall)
        clockAnchor = try c.decode(LedgerClockSample.self, forKey: .clockAnchor)
        lastClock = try c.decode(LedgerClockSample.self, forKey: .lastClock)
        // Only additive fields default. Missing original accounting fields is corruption,
        // never a reason to silently reset usage, profiles or trust.
        configuration = try c.decode(FamilyConfiguration.self, forKey: .configuration)
        profiles = try c.decode([String: ViewerProfile].self, forKey: .profiles)
        viewers = try c.decode([UUID].self, forKey: .viewers)
        clockTrusted = try c.decode(Bool.self, forKey: .clockTrusted)
        clockRecoveryReason = try c.decodeIfPresent(LedgerClockRecoveryReason.self, forKey: .clockRecoveryReason)
        kernelBootChangeRequiresParent = try c.decodeIfPresent(Bool.self, forKey: .kernelBootChangeRequiresParent) ?? false
        familyActual = try c.decode(Int64.self, forKey: .familyActual)
        personalActual = try c.decode([String: Int64].self, forKey: .personalActual)
        continuousActual = try c.decode(Int64.self, forKey: .continuousActual)
        continuousFrozen = try c.decode(Int64.self, forKey: .continuousFrozen)
        restRemaining = try c.decode(Int64.self, forKey: .restRemaining)
        restID = try c.decodeIfPresent(UUID.self, forKey: .restID)
        restStartedLogicalWall = try c.decodeIfPresent(Int64.self, forKey: .restStartedLogicalWall)
        active = try c.decodeIfPresent(ActiveLease.self, forKey: .active)
        frozen = try c.decode([FrozenReservation].self, forKey: .frozen)
        grants = try c.decodeIfPresent([TemporaryGrant].self, forKey: .grants) ?? []
        familyBonusMilliseconds = try c.decodeIfPresent(Int64.self, forKey: .familyBonusMilliseconds) ?? 0
        personalBonus = try c.decodeIfPresent([String: Int64].self, forKey: .personalBonus) ?? [:]
        dayExemptUntilLogicalWall = try c.decodeIfPresent(Int64.self, forKey: .dayExemptUntilLogicalWall) ?? 0
        quizSkipUntilLogicalWall = try c.decodeIfPresent(Int64.self, forKey: .quizSkipUntilLogicalWall) ?? 0
        quizPassedToday = try c.decodeIfPresent([String: Bool].self, forKey: .quizPassedToday) ?? [:]
        quizRewardCountToday = try c.decodeIfPresent([String: Int].self, forKey: .quizRewardCountToday) ?? [:]
        familyQuizRewardsToday = try c.decodeIfPresent(Int.self, forKey: .familyQuizRewardsToday) ?? 0
        restNeedingQuiz = try c.decodeIfPresent([String: Bool].self, forKey: .restNeedingQuiz) ?? [:]
        familyQuizRewardMilliseconds = try c.decodeIfPresent(Int64.self, forKey: .familyQuizRewardMilliseconds) ?? 0
        personalQuizRewardMilliseconds = try c.decodeIfPresent([String: Int64].self, forKey: .personalQuizRewardMilliseconds) ?? [:]
        familyRecoveryFrozen = try c.decodeIfPresent(Int64.self, forKey: .familyRecoveryFrozen) ?? 0
        personalRecoveryFrozen = try c.decodeIfPresent([String: Int64].self, forKey: .personalRecoveryFrozen) ?? [:]
        recoveryQuarantinedDay = try c.decodeIfPresent(Int64.self, forKey: .recoveryQuarantinedDay)
        calendarAccountingAligned = try c.decodeIfPresent(Bool.self, forKey: .calendarAccountingAligned) ?? false
        familyReportBaseline = try c.decodeIfPresent(Int64.self, forKey: .familyReportBaseline) ?? 0
        personalReportBaseline = try c.decodeIfPresent([String: Int64].self, forKey: .personalReportBaseline) ?? [:]
        familyFrozenCarry = try c.decodeIfPresent(Int64.self, forKey: .familyFrozenCarry) ?? 0
        personalFrozenCarry = try c.decodeIfPresent([String: Int64].self, forKey: .personalFrozenCarry) ?? [:]
    }
}

private struct StoredQuizRound: Codable {
    let round: QuizRound
    let day: Int64
    let configuration: FamilyConfiguration
    let curriculum: CurriculumProfile
    let restID: UUID?
}

/// A single family-wide SQLite authority, independent of account/login and UI lifecycle.
/// All SQLite transactions and checkpoint operations below are synchronous, with no await.
public actor UsageLedger {
    private let database: LedgerDatabase
    private let clock: any LedgerClock
    private let checkpointStore: any LedgerCheckpointStore
    private let adminAuthorizer: any LedgerAdminAuthorizing
    private let reportRequiresAuthorization: Bool
    private var unavailable = false
    private static let schemaVersion = 3
    private static let maximumDuration: Int64 = 86_400_000
    private static let clockDriftBudgetMilliseconds: Int64 = 2_000
    private static let maximumWallMilliseconds: Int64 = 253_402_214_400_000 // before year 10000

    public init(databaseURL: URL, clock: any LedgerClock = SystemLedgerClock(),
                checkpointStore: any LedgerCheckpointStore,
                adminAuthorizer: any LedgerAdminAuthorizing,
                reportRequiresAuthorization: Bool = false) throws {
        self.clock = clock; self.checkpointStore = checkpointStore
        self.adminAuthorizer = adminAuthorizer
        self.reportRequiresAuthorization = reportRequiresAuthorization
        let existing: LedgerCheckpoint?
        do { existing = try checkpointStore.load() }
        catch { throw LedgerError.securityStoreUnavailable }
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        if !exists && existing != nil { throw LedgerError.missingDatabase }
        let db = try LedgerDatabase(path: databaseURL.path)
        self.database = db
        do {
            if !exists {
                let sample = clock.now()
                try Self.validate(sample)
                let checkpoint = LedgerCheckpoint(databaseID: UUID(), revision: 0, commitToken: UUID())
                let config = FamilyConfiguration()
                let state = LedgerState(checkpoint: checkpoint,
                    day: Self.day(sample.wallMilliseconds, offset: config.timeZoneIdentifier),
                    logicalWall: sample.wallMilliseconds, clockAnchor: sample, lastClock: sample)
                try db.execute("BEGIN IMMEDIATE")
                do {
                    try db.execute("CREATE TABLE ledger_state (id INTEGER PRIMARY KEY CHECK(id = 1), payload TEXT NOT NULL)")
                    try db.execute("CREATE TABLE usage_events (event_id TEXT PRIMARY KEY, lease_id TEXT UNIQUE NOT NULL, request TEXT NOT NULL, status TEXT NOT NULL, receipt TEXT)")
                    try Self.createProjectionTables(db)
                    try Self.project(state, db: db)
                    try db.execute("INSERT INTO ledger_state(id,payload) VALUES(1,?)", [try Self.encode(state)])
                    try db.execute("PRAGMA user_version=3")
                    try db.execute("COMMIT")
                } catch { try? db.execute("ROLLBACK"); throw error }
                // Not atomic with SQLite. Any interrupted/mismatched checkpoint fails closed on reopen.
                do { try checkpointStore.compareAndSwap(expected: nil, new: checkpoint) }
                catch { throw LedgerError.securityStoreUnavailable }
            } else {
                guard let existing else { throw LedgerError.checkpointMismatch }
                let version = Int(try db.scalar("PRAGMA user_version") ?? "0") ?? 0
                guard (1...Self.schemaVersion).contains(version) else {
                    throw LedgerError.unsupportedSchema(version)
                }
                var state = try Self.readState(db)
                guard state.checkpoint == existing else { throw LedgerError.checkpointMismatch }
                if version < Self.schemaVersion {
                    // DDL, backfill and version advance commit together. Migration changes no
                    // checkpoint: it preserves authority and only normalizes its representation.
                    try db.execute("BEGIN IMMEDIATE")
                    do {
                        try Self.createProjectionTables(db)
                        if version == 1 { try Self.backfillVersionOne(state, db: db) }
                        try Self.migrateVersionTwo(&state, db: db)
                        try Self.project(state, db: db)
                        try db.execute("UPDATE ledger_state SET payload=? WHERE id=1", [try Self.encode(state)])
                        try db.execute("PRAGMA user_version=3")
                        try db.execute("COMMIT")
                    } catch { try? db.execute("ROLLBACK"); throw error }
                }
            }
            // A persisted lease belongs to a prior ledger lifetime: never silently release its debit.
            try Self.transaction(db: db, store: checkpointStore) { state in
                try Self.maintain(&state, now: clock.now(), db: db)
                if state.active != nil { try Self.freeze(&state, db: db) }
            }
        } catch { db.close(); throw error }
    }

    /// Does not release an outstanding lease. Reopen freezes it; logout must not remove this DB.
    public func close() { database.close(); unavailable = true }

    public func configureFamily(_ configuration: FamilyConfiguration, credential: Data) throws {
        try adminAuthorizer.authorize(operation: .configureFamily, credential: credential)
        try Self.validate(configuration)
        try prepare()
        try mutate { state in
            guard state.active == nil else { throw LedgerError.leaseAlreadyActive }
            if configuration.timeZoneIdentifier != state.configuration.timeZoneIdentifier {
                guard state.profiles.isEmpty, state.familyActual == 0, state.frozen.isEmpty else {
                    throw LedgerError.invalidInput("day boundary changes require a future policy migration")
                }
                state.day = Self.day(try Self.calendarWall(state), offset: configuration.timeZoneIdentifier)
            }
            if let rules = configuration.quizRules {
                guard configuration.dailyLimitMilliseconds + state.familyBonusMilliseconds + state.familyQuizRewardMilliseconds
                        <= rules.familyAbsoluteTotalMilliseconds else { throw LedgerError.invalidInput("family absolute total exceeded") }
            }
            if configuration.quizRules != state.configuration.quizRules {
                state.quizPassedToday = [:]
                state.restNeedingQuiz = configuration.quizRules?.quizAfterRest == true
                    ? Dictionary(uniqueKeysWithValues: state.profiles.keys.map { ($0, true) }) : [:]
                // Do not reset reward totals when a parent edits policy mid-day.
                try database.execute("DELETE FROM quiz_rounds WHERE id NOT IN (SELECT attempt_id FROM quiz_outcomes)")
            }
            state.configuration = configuration
            Self.startRestIfNeeded(&state)
            try audit(.configureFamily, state: state)
        }
    }

    public func upsertProfile(_ profile: ViewerProfile, credential: Data) throws {
        try adminAuthorizer.authorize(operation: .upsertProfile, credential: credential)
        guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.displayName.count <= 80, profile.avatarSymbol.count <= 100,
              profile.dailyLimitMilliseconds > 0,
              profile.dailyLimitMilliseconds <= Self.maximumDuration,
              profile.curriculum.schemaVersion == 1,
              (1...12).contains(profile.curriculum.grade) else {
            throw LedgerError.invalidInput("invalid profile")
        }
        try prepare()
        try mutate { state in
            guard state.active == nil else { throw LedgerError.leaseAlreadyActive }
            if !profile.isEnabled, state.viewers.contains(profile.id) {
                // Disabling is a parent-authorized removal, not a viewer switch.
                // Never pick another child or change counters; active leases above
                // still lock the entire viewer set until settlement.
                state.viewers.removeAll { $0 == profile.id }
                try audit(.selectViewers, state: state, object: "disable:" + profile.id.uuidString)
            }
            // A personal allowance above the family total is pointless but never a
            // bypass: reserve() always binds to the shared hard cap atomically.
            // The parental UI keeps the picker within the family limit instead.
            if state.profiles[profile.id.uuidString] == nil, state.restID != nil,
               state.configuration.quizRules?.quizAfterRest == true {
                state.restNeedingQuiz[profile.id.uuidString] = true
            }
            state.profiles[profile.id.uuidString] = profile
            // First child becomes the default viewer; keep any existing selection.
            if state.viewers.isEmpty && state.profiles.count == 1 && profile.isEnabled {
                state.viewers = [profile.id]
                try audit(.selectViewers, state: state, object: profile.id.uuidString)
            }
            // Updating limits or curriculum never resets per-profile or family counters.
            try audit(.upsertProfile, state: state, object: profile.id.uuidString)
        }
    }

    /// Metadata-only edits preserve the complete curriculum unless explicitly supplied.
    public func updateProfile(_ id: UUID, displayName: String, avatarSymbol: String,
                              dailyLimitMilliseconds: Int64, isEnabled: Bool = true,
                              curriculum: CurriculumProfile? = nil, credential: Data) throws {
        try adminAuthorizer.authorize(operation: .upsertProfile, credential: credential)
        guard let existing = try Self.readState(database).profiles[id.uuidString] else {
            throw LedgerError.invalidInput("unknown profile")
        }
        try upsertProfile(ViewerProfile(id: id, displayName: displayName, avatarSymbol: avatarSymbol,
            curriculum: curriculum ?? existing.curriculum, dailyLimitMilliseconds: dailyLimitMilliseconds,
            isEnabled: isEnabled), credential: credential)
    }

    /// Deleting a profile keeps every historical usage projection for reports.
    /// Requires the same parental capability as creating profiles.
    public func deleteProfile(_ id: UUID, credential: Data) throws {
        try adminAuthorizer.authorize(operation: .upsertProfile, credential: credential)
        try prepare()
        try mutate { state in
            guard state.active == nil else { throw LedgerError.leaseAlreadyActive }
            guard state.profiles.removeValue(forKey: id.uuidString) != nil else {
                throw LedgerError.invalidInput("unknown profile")
            }
            state.viewers.removeAll { $0 == id }
            try audit(.upsertProfile, state: state, object: "delete:" + id.uuidString)
        }
    }

    public func selectViewers(_ viewerIDs: [UUID], credential: Data) throws {
        try adminAuthorizer.authorize(operation: .selectViewers, credential: credential)
        guard !viewerIDs.isEmpty, Set(viewerIDs).count == viewerIDs.count else {
            throw LedgerError.invalidInput("viewers must be nonempty and unique")
        }
        try prepare()
        try mutate { state in
            guard state.active == nil else { throw LedgerError.leaseAlreadyActive }
            for id in viewerIDs {
                guard state.profiles[id.uuidString]?.isEnabled == true else {
                    throw LedgerError.invalidInput("unknown or disabled viewer")
                }
            }
            state.viewers = viewerIDs.sorted { $0.uuidString < $1.uuidString }
            try audit(.selectViewers, state: state, object: state.viewers.map(\.uuidString).joined(separator: ","))
        }
    }

    /// Upgrade older single-child installations that never stored a viewer
    /// selection. This does not reset any usage or broaden multi-child permissions.
    public func selectSoleViewerIfNeeded(credential: Data) throws {
        try adminAuthorizer.authorize(operation: .temporaryOverride, credential: credential)
        try prepare()
        try mutate { state in
            guard state.viewers.isEmpty, state.active == nil else { return }
            let enabled = state.profiles.values.filter { $0.isEnabled }
            guard enabled.count == 1, let onlyChild = enabled.first else { return }
            state.viewers = [onlyChild.id]
            try audit(.selectViewers, state: state, object: onlyChild.id.uuidString)
        }
    }

    /// Parent acknowledgment restores a monotonic anchor, not quota or historical counters.
    /// Unproven elapsed time is discarded, and any remaining rest must still be waited out.
    public func reanchorClock(credential: Data) throws {
        try adminAuthorizer.authorize(operation: .reanchorClock, credential: credential)
        let now = clock.now()
        try Self.validate(now)
        try mutate { state in
            if state.active != nil { try Self.freeze(&state, db: database) }
            state.clockAnchor = now; state.lastClock = now; state.clockTrusted = true
            state.clockRecoveryReason = nil
            state.kernelBootChangeRequiresParent = false
            try Self.alignCalendarAccounting(&state, calendarWall: now.wallMilliseconds, db: database)
            try audit(.reanchorClock, state: state)
        }
    }

    /// Only call on an isolated candidate using its own checkpoint store, before app-level
    /// atomic replacement. Recovery quarantines allowance; it never invents watched time.
    public func prepareRestoredBackup(minimumRevision: Int64, credential: Data) throws -> LedgerCheckpoint {
        try adminAuthorizer.authorize(operation: .reanchorClock, credential: credential)
        guard minimumRevision >= 0, minimumRevision < Int64.max else { throw LedgerError.invalidInput("invalid recovery revision") }
        let now = clock.now()
        try Self.validate(now)
        try mutate(minimumRevision: minimumRevision) { state in
            if state.active != nil { try Self.freeze(&state, db: database) }
            try Self.alignCalendarAccounting(&state, calendarWall: now.wallMilliseconds, db: database)
            state.familyBonusMilliseconds = 0; state.personalBonus = [:]
            state.familyQuizRewardMilliseconds = 0; state.personalQuizRewardMilliseconds = [:]
            state.recoveryQuarantinedDay = state.day
            state.grants = []; state.dayExemptUntilLogicalWall = 0; state.quizSkipUntilLogicalWall = 0
            state.quizPassedToday = [:]
            state.restNeedingQuiz = Dictionary(uniqueKeysWithValues: state.profiles.keys.map { ($0, true) })
            state.familyRecoveryFrozen += max(0, state.configuration.dailyLimitMilliseconds - state.familyActual - Self.familyFrozen(state))
            for profile in state.profiles.values {
                state.personalRecoveryFrozen[profile.id.uuidString, default: 0] += max(0,
                    profile.dailyLimitMilliseconds - state.personalActual[profile.id.uuidString, default: 0]
                    - Self.personalFrozen(state, id: profile.id))
            }
            state.restRemaining = state.configuration.restMilliseconds
            state.restID = UUID(); state.restStartedLogicalWall = state.logicalWall
            state.clockAnchor = now; state.lastClock = now; state.clockTrusted = false
            state.clockRecoveryReason = .restoredBackup
            try audit(.reanchorClock, state: state, object: "restore-quarantine", duration: state.restRemaining)
        }
        return try Self.readState(database).checkpoint
    }

    /// No tick, settlement or checkpoint mutation. Safe for backup preflight, not a DB copy.
    public func backupState() throws -> LedgerBackupState {
        guard !unavailable else { throw LedgerError.closed }
        let state = try Self.readState(database)
        let checkpoint: LedgerCheckpoint?
        do { checkpoint = try checkpointStore.load() } catch { throw LedgerError.securityStoreUnavailable }
        guard checkpoint == state.checkpoint else { throw LedgerError.checkpointMismatch }
        return LedgerBackupState(checkpoint: state.checkpoint, day: state.day,
                                 hasActiveLease: state.active != nil, clockIsTrusted: state.clockTrusted)
    }

    // MARK: Temporary parental relief (audited, time-boxed, never counted as usage)

    /// Adds parental bonus only; quiz rewards remain independently accounted.
    @discardableResult
    public func grantTemporaryBonus(_ milliseconds: Int64, credential: Data, note: String = "",
                                    id: UUID = UUID()) throws -> TemporaryGrant {
        try grant(kind: .bonusTime, milliseconds: milliseconds, credential: credential, note: note, id: id)
    }

    /// Waives daily/schedule gates for the selected viewers, never continuous rest.
    @discardableResult
    public func grantDayExemption(credential: Data, note: String = "", id: UUID = UUID()) throws -> TemporaryGrant {
        try grant(kind: .dayExemption, milliseconds: 0, credential: credential, note: note, id: id)
    }

    @discardableResult
    public func grantQuizSkip(credential: Data, note: String = "", id: UUID = UUID()) throws -> TemporaryGrant {
        try grant(kind: .skipQuiz, milliseconds: 0, credential: credential, note: note, id: id)
    }

    private func grant(kind: TemporaryGrant.Kind, milliseconds: Int64, credential: Data,
                       note: String, id: UUID) throws -> TemporaryGrant {
        try adminAuthorizer.authorize(operation: .temporaryOverride, credential: credential)
        guard note.utf8.count <= 200,
              kind != .bonusTime || (1_000...Self.maximumDuration).contains(milliseconds) else {
            throw LedgerError.invalidInput("invalid bonus grant or note")
        }
        try prepare()
        return try mutate { state in
            if let payload = try database.scalar("SELECT payload FROM temporary_grants WHERE id=?", [id.uuidString]) {
                let old = try Self.decode(TemporaryGrant.self, payload)
                guard old.kind == kind, old.bonusMilliseconds == milliseconds, old.note == note,
                      old.viewerIDs == state.viewers else { throw LedgerError.eventConflict }
                return old // Even after expiry, never extend or re-credit the same id.
            }
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard !state.viewers.isEmpty else { throw LedgerError.noActiveViewers }
            let expiry = state.logicalWall + Self.untilNextDay(try Self.calendarWall(state), timeZone: state.configuration.timeZoneIdentifier)
            let grant = TemporaryGrant(id: id, kind: kind, bonusMilliseconds: milliseconds,
                viewerIDs: state.viewers, expiresAtLogicalWall: expiry, note: note, issuedAtLogicalWall: state.logicalWall)
            if kind == .bonusTime {
                let cap = state.configuration.quizRules?.familyAbsoluteTotalMilliseconds ?? Self.maximumDuration
                guard milliseconds <= cap - state.configuration.dailyLimitMilliseconds - state.familyBonusMilliseconds
                    - state.familyQuizRewardMilliseconds else { throw LedgerError.invalidInput("family absolute total exceeded") }
                state.familyBonusMilliseconds += milliseconds
                for id in state.viewers { state.personalBonus[id.uuidString, default: 0] += milliseconds }
            }
            state.grants.append(grant)
            try database.execute("INSERT INTO temporary_grants(id,payload) VALUES(?,?)", [id.uuidString, try Self.encode(grant)])
            try audit(.temporaryOverride, state: state, object: try Self.encode(grant),
                      duration: expiry - state.logicalWall, id: id)
            return grant
        }
    }

    /// Audits parent mode changes under the same temporaryOverride capability as relief.
    public func recordParentalAction(operation: String, object: String, durationMilliseconds: Int64 = 0,
                                     credential: Data) throws {
        try adminAuthorizer.authorize(operation: .temporaryOverride, credential: credential)
        guard !operation.isEmpty, operation.utf8.count <= 100, !object.isEmpty, object.utf8.count <= 1_000,
              (0...Self.maximumDuration).contains(durationMilliseconds) else { throw LedgerError.invalidInput("invalid parental action") }
        try prepare()
        try mutate { state in
            try database.execute("INSERT INTO parental_audit_logs(operation,object,day,logical_wall_ms,observed_wall_ms,duration_ms,action_id) VALUES(?,?,?,?,?,?,?)",
                [operation, object, String(state.day), String(state.logicalWall), String(state.lastClock.wallMilliseconds),
                 String(durationMilliseconds), UUID().uuidString])
        }
    }

    /// Durable grant history, including expired grants; use report authorization when configured.
    public func grantHistory(credential: Data? = nil) throws -> [TemporaryGrant] {
        try authorizeReport(credential)
        guard !unavailable else { throw LedgerError.closed }
        return try database.rows("SELECT payload FROM temporary_grants ORDER BY rowid").map {
            guard let payload = $0[0] else { throw LedgerError.corruptDatabase }
            return try Self.decode(TemporaryGrant.self, payload)
        }
    }

    // MARK: Quiz rounds and rewards

    /// The app supplies its bundled question bank at issuance (a trusted app boundary).
    /// Persist the exact validated questions; submission never trusts a decoded answer key.
    public func startQuizRound(childID: UUID, questions: [QuizQuestion]) throws -> QuizRound {
        try prepare()
        return try mutate { state in
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard state.restRemaining == 0 else { throw LedgerError.resting }
            guard let profile = state.profiles[childID.uuidString], profile.isEnabled else {
                throw LedgerError.invalidInput("unknown or disabled child")
            }
            guard let rules = state.configuration.quizRules else { throw LedgerError.invalidInput("quiz disabled") }
            guard questions.count == rules.questionsPerRound,
                  Set(questions.map(\.id)).count == questions.count else {
                throw LedgerError.invalidInput("round question count or identity mismatch")
            }
            for question in questions {
                guard !question.id.isEmpty, !question.prompt.isEmpty, (2...10).contains(question.options.count),
                      question.grade == profile.curriculum.grade,
                      profile.curriculum.subjects.isEmpty || profile.curriculum.subjects.contains(question.subject),
                      Set(question.options.map(\.id)).count == question.options.count,
                      question.options.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty }),
                      question.options.contains(where: { $0.id == question.answerID }) else {
                    throw LedgerError.invalidInput("invalid question structure or curriculum")
                }
            }
            let round = QuizRound(id: UUID(), childID: childID, questions: questions)
            let stored = StoredQuizRound(round: round, day: state.day, configuration: state.configuration,
                                         curriculum: profile.curriculum, restID: state.restID)
            try database.execute("INSERT INTO quiz_rounds(id,payload) VALUES(?,?)", [round.id.uuidString, try Self.encode(stored)])
            return round
        }
    }

    public func submitQuizRound(_ round: QuizRound, answers: [String: String]) throws -> QuizOutcome {
        try submitQuizRound(id: round.id, childID: round.childID, suppliedRound: round, answers: answers)
    }

    /// Preferred submission API: send identity and choices only, never the question/answer key.
    public func submitQuizRound(id: UUID, childID: UUID, answers: [String: String]) throws -> QuizOutcome {
        try submitQuizRound(id: id, childID: childID, suppliedRound: nil, answers: answers)
    }

    private func submitQuizRound(id: UUID, childID: UUID, suppliedRound: QuizRound?,
                                 answers: [String: String]) throws -> QuizOutcome {
        try prepare()
        return try mutate { state in
            guard let payload = try database.scalar("SELECT payload FROM quiz_rounds WHERE id=?", [id.uuidString]) else {
                throw LedgerError.invalidInput("unknown quiz round")
            }
            let stored = try Self.decode(StoredQuizRound.self, payload)
            let round = stored.round
            guard round.childID == childID, suppliedRound == nil || suppliedRound == round else {
                throw LedgerError.invalidInput("quiz round mismatch")
            }
            guard Set(answers.keys) == Set(round.questions.map(\.id)),
                  round.questions.allSatisfy({ question in question.options.contains { $0.id == answers[question.id] } }) else {
                throw LedgerError.invalidInput("incomplete or invalid answers")
            }
            if let payload = try database.scalar("SELECT payload FROM quiz_outcomes WHERE attempt_id=?", [id.uuidString]) {
                let result = try Self.decode(QuizOutcome.self, payload)
                guard result.childID == childID else { throw LedgerError.corruptDatabase }
                return result
            }
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard state.restRemaining == 0 else { throw LedgerError.resting }
            guard let profile = state.profiles[childID.uuidString], profile.isEnabled else {
                throw LedgerError.invalidInput("unknown or disabled child")
            }
            guard stored.day == state.day, stored.configuration == state.configuration,
                  stored.curriculum == profile.curriculum, stored.restID == state.restID,
                  let rules = state.configuration.quizRules else { throw LedgerError.invalidInput("stale quiz round") }
            var correctCount = 0
            var wrong: [QuizWrongAnswer] = []
            for question in round.questions {
                let chosen = answers[question.id]!
                if chosen == question.answerID {
                    correctCount += 1
                } else {
                    wrong.append(QuizWrongAnswer(questionID: question.id, prompt: question.prompt,
                        chosenOptionID: chosen, correctOptionID: question.answerID,
                        explanation: question.explanation, day: state.day, childID: childID, attemptID: id))
                }
            }
            let passed = Double(correctCount) >= Double(round.questions.count) * rules.passRatio
            var reward: Int64 = 0
            var deniedReason: String?
            if passed {
                state.quizPassedToday[childID.uuidString] = true
                state.restNeedingQuiz[childID.uuidString] = false
                let amount = Int64(rules.rewardMinutes) * 60_000
                if state.recoveryQuarantinedDay == state.day {
                    deniedReason = "recovery-quarantine"
                } else if state.quizRewardCountToday[childID.uuidString, default: 0] >= rules.personalDailyRewards {
                    deniedReason = "personal-daily-cap"
                } else if state.familyQuizRewardsToday >= rules.familyDailyRewards {
                    deniedReason = "family-daily-cap"
                } else if amount > rules.maxFamilyDailyRewardMilliseconds - state.familyQuizRewardMilliseconds {
                    deniedReason = "family-daily-duration-cap"
                } else if amount > rules.familyAbsoluteTotalMilliseconds - state.configuration.dailyLimitMilliseconds
                            - state.familyBonusMilliseconds - state.familyQuizRewardMilliseconds {
                    deniedReason = "family-absolute-total-cap"
                } else {
                    reward = amount
                    state.quizRewardCountToday[childID.uuidString, default: 0] += 1
                    state.familyQuizRewardsToday += 1
                    state.familyQuizRewardMilliseconds += reward
                    state.personalQuizRewardMilliseconds[childID.uuidString, default: 0] += reward
                    try database.execute("INSERT INTO quiz_rewards(attempt_id,child,day,minutes) VALUES(?,?,?,?)",
                        [id.uuidString, childID.uuidString, String(state.day), String(reward)])
                }
            }
            let outcome = QuizOutcome(attemptID: id, childID: childID, correctCount: correctCount,
                total: round.questions.count, passed: passed, rewardMinutes: reward, rewardDeniedReason: deniedReason)
            try database.execute("INSERT INTO quiz_attempts(attempt_id,child,day,correct,total,passed,rewarded_minutes,wrongs) VALUES(?,?,?,?,?,?,?,?)",
                [id.uuidString, childID.uuidString, String(state.day), String(correctCount),
                 String(round.questions.count), passed ? "1" : "0", String(reward), try Self.encode(wrong)])
            try database.execute("INSERT INTO quiz_outcomes(attempt_id,payload) VALUES(?,?)", [id.uuidString, try Self.encode(outcome)])
            return outcome
        }
    }

    /// Reserves the minimum of requested, short-lease cap, all budgets and continuous remainder.
    /// The lease begins paused. Start/stop accounting with setPlaybackActivity, not media position.
    public func reservePlayback(eventID: String, requestedMilliseconds: Int64) throws -> PlaybackLease {
        // Renewal event IDs belong exclusively to this ledger, not callers.
        guard !eventID.isEmpty, eventID.utf8.count <= 200, !eventID.hasPrefix("renew:") else {
            throw LedgerError.invalidInput("invalid lease request")
        }
        try Self.validateRequestedMilliseconds(requestedMilliseconds)
        try prepare()
        return try mutate { state in
            try reserve(&state, eventID: eventID, requestedMilliseconds: requestedMilliseconds)
        }
    }

    private func reserve(_ state: inout LedgerState, eventID: String,
                         requestedMilliseconds: Int64) throws -> PlaybackLease {
        guard state.clockTrusted else { throw LedgerError.clockUntrusted }
        if let active = state.active {
            if active.lease.eventID == eventID && active.requestedMilliseconds == requestedMilliseconds {
                return active.lease
            }
            throw LedgerError.leaseAlreadyActive
        }
        guard try database.scalar("SELECT event_id FROM usage_events WHERE event_id=?", [eventID]) == nil else {
            throw LedgerError.eventConflict
        }
        guard !state.viewers.isEmpty else { throw LedgerError.noActiveViewers }
        guard state.restRemaining == 0 else { throw LedgerError.resting }
        guard state.recoveryQuarantinedDay != state.day else { throw LedgerError.budgetExhausted }
        let config = state.configuration
        // A live day exemption (parental relief) bypasses the daily caps, personal
        // caps and schedule/bedtime blocks — never the continuous limit or rest.
        let exempt = Self.isDayExempt(state)
        var available = min(requestedMilliseconds, config.maximumLeaseMilliseconds,
            Self.familyRemaining(state), Self.continuousRemaining(state))
        // Civil boundaries follow the proven calendar, never the duration clock
        // retained during recovery. Even exemptions cannot straddle midnight.
        let calendarWall = try Self.calendarWall(state)
        available = min(available, Self.untilNextDay(calendarWall, timeZone: config.timeZoneIdentifier))
        if !exempt {
            // Workday/weekend windows and the bedtime block are family-level hard
            // limits; leases may not start outside them or straddle their edge.
            let schedule = try Self.scheduleRemaining(calendarWall, config: config)
            if schedule.blocked { throw LedgerError.scheduleBlocked }
            if let scheduleRemaining = schedule.remainingMilliseconds {
                available = min(available, scheduleRemaining)
            }
        }
        for id in state.viewers {
            available = min(available, try Self.personalRemaining(state, id: id))
        }
        // Quiz gates are family rules: before the first watch of the day and after
        // a completed rest. A parental quiz-skip or day exemption waives them.
        if !Self.pendingQuizViewerIDs(state).isEmpty { throw LedgerError.quizRequired }
        guard available > 0 else { throw LedgerError.budgetExhausted }
        let lease = PlaybackLease(id: UUID(), eventID: eventID, viewerIDs: state.viewers,
            reservedMilliseconds: available,
            expiresAtMonotonicMilliseconds: state.lastClock.monotonicMilliseconds + available,
            continuityID: state.lastClock.continuityID)
        state.active = ActiveLease(lease: lease, requestedMilliseconds: requestedMilliseconds,
                                   lastTick: state.lastClock.monotonicMilliseconds)
        try database.execute("INSERT INTO usage_events(event_id,lease_id,request,status) VALUES(?,?,?,'active')",
            [eventID, lease.id.uuidString, try Self.encode(lease)])
        return lease
    }

    public func setPlaybackActivity(leaseID: UUID, activity: PlaybackActivity) throws {
        try prepare()
        try mutate { state in
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard var active = state.active, active.lease.id == leaseID else {
                throw try leaseFailure(leaseID)
            }
            active.activity = activity
            active.lastTick = state.lastClock.monotonicMilliseconds
            state.active = active
        }
    }

    /// Idempotent for the same lease. Late or prior-lifetime leases remain frozen, never refunded.
    public func settlePlayback(leaseID: UUID) throws -> UsageReceipt {
        try prepare()
        return try mutate { state in try settle(&state, leaseID: leaseID) }
    }

    /// Settles the measured segment and reserves its successor without a suspension or paused gap.
    /// Retry only while that exact successor remains active; a terminal renewal stays terminal.
    public func renewPlayback(leaseID: UUID, requestedMilliseconds: Int64, minimumSuccessorMilliseconds: Int64 = 0) throws -> PlaybackRenewal {
        try Self.validateRequestedMilliseconds(requestedMilliseconds)
        guard (0...500).contains(minimumSuccessorMilliseconds) else {
            throw LedgerError.invalidInput("invalid renderer safety margin")
        }
        // Persist expiry/clock anomalies even if the renewal below must reject the lease.
        try prepare()
        return try mutate { state in
            let eventID = "renew:" + leaseID.uuidString
            if let stored = try database.scalar("SELECT receipt FROM usage_events WHERE lease_id=? AND status='settled'", [leaseID.uuidString]) {
                let previous = try Self.decode(StoredUsageReceipt.self, stored)
                guard previous.renewalRequestedMilliseconds == requestedMilliseconds else {
                    throw LedgerError.invalidLease
                }
                if let nextID = try database.scalar("SELECT lease_id FROM usage_events WHERE event_id=?", [eventID]) {
                    guard state.clockTrusted, let active = state.active,
                          active.lease.id.uuidString == nextID, active.lease.eventID == eventID else {
                        throw LedgerError.invalidLease
                    }
                    return PlaybackRenewal(receipt: previous.receipt, nextLease: active.lease)
                }
                return PlaybackRenewal(receipt: previous.receipt, nextLease: nil)
            }
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard let active = state.active, active.lease.id == leaseID else {
                throw try leaseFailure(leaseID)
            }
            let receipt = try settle(&state, leaseID: leaseID,
                                     renewalRequestedMilliseconds: requestedMilliseconds)
            // prepare deliberately kept an exactly-at-midnight active lease on its old day.
            // With it now settled, maintain projects that day's totals before rolling over.
            let sample = state.lastClock
            try Self.maintain(&state, now: sample, db: database)
            do {
                let next = try reserve(&state, eventID: eventID, requestedMilliseconds: requestedMilliseconds)
                if next.reservedMilliseconds <= minimumSuccessorMilliseconds {
                    // This successor has never been returned or played. Do not mint a
                    // sub-renderer-latency lease that will inevitably expire during stop.
                    try database.execute("DELETE FROM usage_events WHERE lease_id=? AND status='active'", [next.id.uuidString])
                    state.active = nil
                    let remaining = state.configuration.continuousLimitMilliseconds - state.continuousActual - state.continuousFrozen
                    if remaining <= minimumSuccessorMilliseconds, state.restRemaining == 0 {
                        state.restRemaining = state.configuration.restMilliseconds
                        state.restID = UUID()
                        state.restStartedLogicalWall = state.logicalWall
                    }
                    return PlaybackRenewal(receipt: receipt, nextLease: nil)
                }
                state.active?.activity = active.activity
                return PlaybackRenewal(receipt: receipt, nextLease: next)
            } catch LedgerError.budgetExhausted {
                return PlaybackRenewal(receipt: receipt, nextLease: nil)
            } catch LedgerError.resting {
                return PlaybackRenewal(receipt: receipt, nextLease: nil)
            } catch LedgerError.scheduleBlocked {
                return PlaybackRenewal(receipt: receipt, nextLease: nil)
            } catch LedgerError.quizRequired {
                return PlaybackRenewal(receipt: receipt, nextLease: nil)
            }
        }
    }

    private func settle(_ state: inout LedgerState, leaseID: UUID,
                        renewalRequestedMilliseconds: Int64? = nil) throws -> UsageReceipt {
        if let receipt = try database.scalar("SELECT receipt FROM usage_events WHERE lease_id=? AND status='settled'", [leaseID.uuidString]) {
            return try Self.decode(UsageReceipt.self, receipt)
        }
        guard state.clockTrusted else { throw LedgerError.clockUntrusted }
        guard let active = state.active, active.lease.id == leaseID else {
            throw try leaseFailure(leaseID)
        }
        let actual = active.actualMilliseconds
        let receipt = UsageReceipt(eventID: active.lease.eventID, leaseID: leaseID,
            actualMilliseconds: actual, viewerIDs: active.lease.viewerIDs, day: state.day)
        state.familyActual += actual
        state.continuousActual += actual
        for id in active.lease.viewerIDs { state.personalActual[id.uuidString, default: 0] += actual }
        state.active = nil
        Self.startRestIfNeeded(&state)
        let stored = StoredUsageReceipt(receipt: receipt,
                                        renewalRequestedMilliseconds: renewalRequestedMilliseconds)
        try database.execute("UPDATE usage_events SET status='settled',receipt=? WHERE lease_id=? AND status='active'",
                             [try Self.encode(stored), leaseID.uuidString])
        try database.execute("UPDATE watch_sessions SET status='settled',actual_ms=? WHERE lease_id=?", [String(actual), leaseID.uuidString])
        return receipt
    }

    /// Read-only reporting over the durable projections. The parental UI gates
    /// access; the ledger itself only serves already-persisted rows.
    public func report(lastDays: Int, childID: UUID? = nil, credential: Data? = nil) throws -> FamilyReport {
        try authorizeReport(credential)
        try prepare()
        return try mutate { state in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: state.configuration.timeZoneIdentifier)!
            // Failed observations never replace lastClock/anchor. Reports may use
            // that last proven calendar even while playback is clock-blocked.
            let reportWall = try? Self.lastCalendarWall(state)
            let generatedDay = reportWall.map { Self.day($0, offset: state.configuration.timeZoneIdentifier) } ?? state.day
            let date = reportWall.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                ?? calendar.date(from: DateComponents(year: Int(state.day / 10_000),
                    month: Int(state.day / 100 % 100), day: Int(state.day % 100)))!
            let start = calendar.date(byAdding: .day, value: -max(1, min(90, lastDays)), to: date)!
            let since = Self.day(Int64(start.timeIntervalSince1970 * 1_000), offset: state.configuration.timeZoneIdentifier)
            let dayFilter = "day>\(since) AND day<=\(generatedDay)"
            var dayRows: [Int64: FamilyReport.DayUsage] = [:]
            for row in try database.rows("SELECT day,actual_ms,frozen_ms FROM family_daily_usage WHERE \(dayFilter)") {
                guard let d = row[0].flatMap(Int64.init),
                      let a = row[1].flatMap(Int64.init),
                      let f = row[2].flatMap(Int64.init) else { continue }
                dayRows[d] = .init(day: d, familyActualMilliseconds: a,
                                   familyFrozenMilliseconds: f, personalMilliseconds: [:])
            }
            for row in try database.rows("SELECT day,profile_id,actual_ms FROM child_daily_usage WHERE \(dayFilter)") {
                guard let d = row[0].flatMap(Int64.init), let profileID = row[1],
                      let a = row[2].flatMap(Int64.init), dayRows[d] != nil else { continue }
                if childID == nil || childID?.uuidString == profileID { dayRows[d]?.personalMilliseconds[profileID] = a }
            }
            var attempts: [FamilyReport.QuizAttemptSummary] = []
            var wrongs: [QuizWrongAnswer] = []
            let childFilter = childID.map { " AND child='\($0.uuidString)'" } ?? ""
            for row in try database.rows("SELECT attempt_id,child,day,correct,total,passed,rewarded_minutes,wrongs FROM quiz_attempts WHERE \(dayFilter)" + childFilter + " ORDER BY day,attempt_id") {
                guard let id = row[0].flatMap(UUID.init(uuidString:)),
                      let childID = row[1].flatMap(UUID.init(uuidString:)),
                      let d = row[2].flatMap(Int64.init),
                      let correct = row[3].flatMap(Int.init),
                      let total = row[4].flatMap(Int.init),
                      let passed = row[5].flatMap(Int.init),
                      let rewarded = row[6].flatMap(Int64.init) else { continue }
                attempts.append(.init(attemptID: id, childID: childID, day: d, correct: correct,
                                      total: total, passed: passed == 1, rewardedMinutes: rewarded))
                if let payload = row[7], let data = payload.data(using: .utf8),
                   let list = try? JSONDecoder().decode([QuizWrongAnswer].self, from: data) {
                    wrongs.append(contentsOf: list.map { item in
                        var item = item; item.childID = childID; item.attemptID = id; return item
                    })
                }
            }
            var auditRows: [FamilyReport.AuditRow] = []
            for row in try database.rows("SELECT operation,object,day,duration_ms,action_id FROM parental_audit_logs WHERE \(dayFilter) ORDER BY id") {
                guard let operation = row[0], let object = row[1],
                      let d = row[2].flatMap(Int64.init) else { continue }
                auditRows.append(.init(operation: operation, object: object, day: d,
                                       durationMilliseconds: row[3].flatMap(Int64.init), id: row[4].flatMap(UUID.init(uuidString:))))
            }
            return FamilyReport(generatedDay: generatedDay,
                                days: dayRows.values.sorted { $0.day < $1.day },
                                quizAttempts: attempts, wrongAnswers: wrongs, audit: auditRows)
        }
    }

    public struct FamilyReport: Codable, Sendable {
        public struct DayUsage: Codable, Sendable {
            public let day: Int64
            public let familyActualMilliseconds: Int64
            public let familyFrozenMilliseconds: Int64
            public var personalMilliseconds: [String: Int64]
        }
        public struct QuizAttemptSummary: Codable, Sendable {
            public let attemptID: UUID
            public let childID: UUID
            public let day: Int64
            public let correct: Int
            public let total: Int
            public let passed: Bool
            public let rewardedMinutes: Int64
        }
        public struct AuditRow: Codable, Sendable {
            public let operation: String
            public let object: String
            public let day: Int64
            public let durationMilliseconds: Int64?
            public let id: UUID?
        }
        public let generatedDay: Int64
        public let days: [DayUsage]
        public let quizAttempts: [QuizAttemptSummary]
        public let wrongAnswers: [QuizWrongAnswer]
        public let audit: [AuditRow]
    }

    /// Maintains the authoritative clock/rest/accounting state, then projects it
    /// without reserving playback, consuming quiz qualification or granting credit.
    public func playbackAvailability() throws -> PlaybackAvailability {
        try prepare()
        return try mutate { state in
            try Self.validate(state.configuration)
            let wall = try Self.lastCalendarWall(state)
            let exempt = Self.isDayExempt(state)
            let family = Self.familyRemaining(state)
            let personal = try state.viewers.map { try Self.personalRemaining(state, id: $0) }.min() ?? 0
            let available = min(family, personal)
            let continuous = Self.continuousRemaining(state)
            let quiz = !Self.pendingQuizViewerIDs(state).isEmpty
            let schedule = try Self.scheduleRemaining(wall, config: state.configuration)
            let scheduleBlocked = !exempt && schedule.blocked
            let reason: PlaybackAvailability.BlockedReason
            // Same policy ordering as reserve; active-lease/event-ID errors are
            // intentionally not playback policy gates. Quiz precedes quota there.
            if !state.clockTrusted { reason = .clockUntrusted }
            else if state.viewers.isEmpty { reason = .noViewers }
            else if state.restRemaining > 0 { reason = .resting }
            else if state.recoveryQuarantinedDay == state.day { reason = .recoveryQuarantine }
            else if scheduleBlocked { reason = .scheduleBlocked }
            else if quiz { reason = .quizRequired }
            else if available == 0 || continuous == 0 { reason = .budgetExhausted }
            else { reason = .ready }
            let opening = state.clockTrusted && scheduleBlocked
                ? try Self.nextScheduleOpening(wall, config: state.configuration) : nil
            return PlaybackAvailability(blockedReason: reason,
                familyRemainingMs: family, limitingPersonalRemainingMs: personal,
                availableRemainingMs: available, continuousRemainingMs: continuous,
                restRemainingMs: state.restRemaining,
                nextScheduleOpeningWallMilliseconds: opening,
                calendarWallMilliseconds: wall, timeZoneIdentifier: state.configuration.timeZoneIdentifier,
                quizRequired: quiz, isScheduleBlocked: scheduleBlocked,
                canStartQuiz: state.clockTrusted && !state.viewers.isEmpty && state.restRemaining == 0
                    && quiz && state.recoveryQuarantinedDay != state.day,
                isDayExempt: exempt)
        }
    }

    public func snapshot() throws -> LedgerSnapshot {        try prepare()
        return try mutate { state in
            var personal: [UUID: Int64] = [:]
            var frozen: [UUID: Int64] = [:]
            for profile in state.profiles.values {
                personal[profile.id] = state.personalActual[profile.id.uuidString, default: 0]
                frozen[profile.id] = Self.personalFrozen(state, id: profile.id)
            }
            return LedgerSnapshot(configuration: state.configuration,
                // Children are listed alphabetically in every parent-facing
                // page; UUID is only a deterministic tiebreaker for equal names.
                profiles: state.profiles.values.sorted { ($0.displayName, $0.id.uuidString) < ($1.displayName, $1.id.uuidString) },
                activeViewerIDs: state.viewers, day: state.day,
                familyActualMilliseconds: state.familyActual, personalActualMilliseconds: personal,
                familyFrozenMilliseconds: Self.familyFrozen(state), personalFrozenMilliseconds: frozen,
                continuousActualMilliseconds: state.continuousActual,
                continuousFrozenMilliseconds: state.continuousFrozen,
                remainingRestMilliseconds: state.restRemaining, clockIsTrusted: state.clockTrusted,
                clockRecoveryReason: state.clockRecoveryReason,
                recoveryQuarantineActive: state.recoveryQuarantinedDay == state.day,
                activeLease: state.active?.lease, frozenReservations: state.frozen,
                checkpoint: state.checkpoint,
                grants: state.grants,
                familyBonusMilliseconds: state.familyBonusMilliseconds + state.familyQuizRewardMilliseconds,
                dayExemptionActive: !state.viewers.isEmpty && state.viewers.allSatisfy { Self.hasGrant(.dayExemption, childID: $0, state: state) },
                quizSkipActive: !state.viewers.isEmpty && state.viewers.allSatisfy { Self.hasGrant(.skipQuiz, childID: $0, state: state) },
                parentalBonusMilliseconds: state.familyBonusMilliseconds,
                familyQuizRewardMilliseconds: state.familyQuizRewardMilliseconds,
                familyRecoveryFrozenMilliseconds: state.familyRecoveryFrozen,
                familyCarriedActualMilliseconds: state.familyReportBaseline,
                personalCarriedActualMilliseconds: Dictionary(uniqueKeysWithValues: state.personalReportBaseline.compactMap { key, value in
                    UUID(uuidString: key).map { ($0, value) }
                }),
                pendingQuizViewerIDs: Self.pendingQuizViewerIDs(state))
        }
    }

    /// Starting a full family rest early never grants quota or clears a running rest.
    /// Used after the renderer stops just before a continuous-limit safety margin.
    public func requestFamilyRest() throws {
        try prepare()
        try mutate { state in
            guard state.clockTrusted else { throw LedgerError.clockUntrusted }
            guard state.active == nil else { throw LedgerError.leaseAlreadyActive }
            guard state.restRemaining == 0,
                  state.continuousActual + state.continuousFrozen > 0 else { return }
            state.restRemaining = state.configuration.restMilliseconds
            state.restID = UUID()
            state.restStartedLogicalWall = state.logicalWall
        }
    }

    private func leaseFailure(_ id: UUID) throws -> LedgerError {
        let status = try database.scalar("SELECT status FROM usage_events WHERE lease_id=?", [id.uuidString])
        return status == "frozen" ? .leaseExpired : .invalidLease
    }
    private func audit(_ operation: LedgerAdminOperation, state: LedgerState, object: String = "family",
                       duration: Int64 = 0, id: UUID = UUID()) throws {
        try database.execute("INSERT INTO parental_audit_logs(operation,object,day,logical_wall_ms,observed_wall_ms,duration_ms,action_id) VALUES(?,?,?,?,?,?,?)",
            [operation.rawValue, object, String(state.day), String(state.logicalWall), String(state.lastClock.wallMilliseconds),
             String(duration), id.uuidString])
    }
    private func authorizeReport(_ credential: Data?) throws {
        if reportRequiresAuthorization || credential != nil {
            guard let credential else { throw LedgerError.unauthorized }
            try adminAuthorizer.authorize(operation: .configureFamily, credential: credential)
        }
    }
    private func prepare() throws {
        let now = clock.now()
        try mutate { state in try Self.maintain(&state, now: now, db: database) }
    }
    private func mutate<T>(minimumRevision: Int64? = nil, _ body: (inout LedgerState) throws -> T) throws -> T {
        guard !unavailable else { throw LedgerError.closed }
        do { return try Self.transaction(db: database, store: checkpointStore, minimumRevision: minimumRevision, body) }
        catch let error as LedgerError {
            if error == .checkpointMismatch || error == .securityStoreUnavailable { unavailable = true }
            throw error
        }
    }
    private static func transaction<T>(db: LedgerDatabase, store: any LedgerCheckpointStore,
                                        minimumRevision: Int64? = nil,
                                        _ body: (inout LedgerState) throws -> T) throws -> T {
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        do {
            var state = try readState(db)
            let previous = state.checkpoint
            let stored: LedgerCheckpoint?
            do { stored = try store.load() } catch { throw LedgerError.securityStoreUnavailable }
            guard stored == previous else { throw LedgerError.checkpointMismatch }
            let previousPayload = try encode(state)
            let changesBefore = db.totalChanges
            let result = try body(&state)
            if try encode(state) == previousPayload && changesBefore == db.totalChanges {
                try db.execute("COMMIT"); committed = true
                return result
            }
            let revision = max(previous.revision, minimumRevision ?? previous.revision)
            guard revision < Int64.max else { throw LedgerError.corruptDatabase }
            state.checkpoint = LedgerCheckpoint(databaseID: previous.databaseID,
                revision: revision + 1, commitToken: UUID())
            try project(state, db: db)
            try db.execute("UPDATE ledger_state SET payload=? WHERE id=1", [try encode(state)])
            try db.execute("COMMIT")
            committed = true
            do { try store.compareAndSwap(expected: previous, new: state.checkpoint) }
            catch { throw LedgerError.securityStoreUnavailable }
            return result
        } catch {
            if !committed { try? db.execute("ROLLBACK") }
            throw error
        }
    }

    private static func maintain(_ state: inout LedgerState, now: LedgerClockSample,
                                 db: LedgerDatabase) throws {
        // Most anomalies remain latched. Older exact-timeval bootChanged locks
        // get one compatibility attempt, only with unquarantined kernel evidence.
        // Set the latch BEFORE checking: failed attempts cannot retry after edits.
        let recoveringLegacyBootChange = state.clockRecoveryReason == .bootChanged
            && !state.kernelBootChangeRequiresParent
        if recoveringLegacyBootChange { state.kernelBootChangeRequiresParent = true }
        if let reason = state.clockRecoveryReason,
           !(recoveringLegacyBootChange && state.recoveryQuarantinedDay == nil
             && kernelBootMarkersWithinBudget(state.clockAnchor, state.lastClock, now)) {
            try distrust(&state, reason: reason, db: db)
            return
        }
        if !state.clockTrusted, state.recoveryQuarantinedDay != nil {
            try distrust(&state, reason: .restoredBackup, db: db)
            return
        }
        let samples = [state.clockAnchor, state.lastClock, now]
        guard samples.allSatisfy(isValidSample) else {
            try distrust(&state, reason: .invalidSample, db: db)
            return
        }
        let recovering = !state.clockTrusted || recoveringLegacyBootChange
        // Include anchor→last as well as both →now comparisons. A fixed anchor
        // prevents small process-by-process drift from replenishing the budget.
        for (previous, current) in [(state.clockAnchor, state.lastClock), (state.clockAnchor, now), (state.lastClock, now)] {
            if let reason = continuityFailure(from: previous, to: current, requireBoot: recovering) {
                try distrust(&state, reason: reason, db: db)
                return
            }
        }
        guard state.lastClock.monotonicMilliseconds >= state.clockAnchor.monotonicMilliseconds,
              now.monotonicMilliseconds >= state.lastClock.monotonicMilliseconds else {
            try distrust(&state, reason: .monotonicRollback, db: db)
            return
        }
        let elapsed = now.monotonicMilliseconds - state.lastClock.monotonicMilliseconds
        let monotonicFromAnchor = now.monotonicMilliseconds - state.clockAnchor.monotonicMilliseconds
        let wallFromAnchor = now.wallMilliseconds - state.clockAnchor.wallMilliseconds
        let wallFromLast = now.wallMilliseconds - state.lastClock.wallMilliseconds
        let priorElapsed = state.lastClock.monotonicMilliseconds - state.clockAnchor.monotonicMilliseconds
        let priorWall = state.lastClock.wallMilliseconds - state.clockAnchor.wallMilliseconds
        // The total anchor is fixed across process restarts, so repeated small wall
        // edits cannot erase cumulative drift. Wall time NEVER selects a timebase.
        guard abs(wallFromAnchor - monotonicFromAnchor) <= clockDriftBudgetMilliseconds,
              abs(wallFromLast - elapsed) <= clockDriftBudgetMilliseconds,
              abs(priorWall - priorElapsed) <= clockDriftBudgetMilliseconds else {
            try distrust(&state, reason: .wallDrift, db: db)
            return
        }
        guard state.logicalWall >= 0, state.logicalWall <= maximumWallMilliseconds - elapsed else {
            try distrust(&state, reason: .invalidSample, db: db)
            return
        }
        if recovering {
            // Proven legacy recovery (including bounded kernel-marker false
            // alarms): keep all debits/rest, discard the untrusted interval, never
            // revive/refund a prior lease, and never replace the total anchor.
            if state.active != nil { try freeze(&state, db: db) }
            state.lastClock = now
            state.clockTrusted = true
            state.clockRecoveryReason = nil
            try alignCalendarAccounting(&state, calendarWall: try calendarWall(state), db: db)
            return
        }
        // Capture before migration/freeze: a newly started rest cannot consume
        // elapsed time from before its frozen debit existed.
        let canAdvanceRest = state.restRemaining > 0 && state.active == nil
        if !state.calendarAccountingAligned {
            // First align at the LAST proven sample, not now. Proven same-boot
            // downtime after it may then cross a real midnight and reset normally.
            try alignCalendarAccounting(&state, calendarWall: try calendarWall(state), db: db)
        }
        state.logicalWall += elapsed
        if now.continuityID != state.lastClock.continuityID {
            if state.active != nil { try freeze(&state, db: db) }
        }
        if canAdvanceRest {
            state.restRemaining = max(0, state.restRemaining - elapsed)
            if state.restRemaining == 0 {
                state.continuousActual = 0; state.continuousFrozen = 0
                // All profiles share the completed rest, including viewers switched away.
                if state.configuration.quizRules?.quizAfterRest == true {
                    for id in state.profiles.keys { state.restNeedingQuiz[id] = true }
                }
            }
        }
        if var active = state.active {
            if now.monotonicMilliseconds > active.lease.expiresAtMonotonicMilliseconds {
                // We cannot prove the renderer stopped at expiry, so no late settlement/refund.
                try freeze(&state, db: db)
            } else {
                if active.activity == .playing {
                    active.actualMilliseconds += now.monotonicMilliseconds - active.lastTick
                }
                active.lastTick = now.monotonicMilliseconds
                guard active.actualMilliseconds <= active.lease.reservedMilliseconds else {
                    throw LedgerError.corruptDatabase
                }
                state.active = active
            }
        }
        state.lastClock = now
        // Expired relief never lingers: prune grants and flags on every tick.
        if state.dayExemptUntilLogicalWall > 0, state.logicalWall >= state.dayExemptUntilLogicalWall {
            state.dayExemptUntilLogicalWall = 0
        }
        if state.quizSkipUntilLogicalWall > 0, state.logicalWall >= state.quizSkipUntilLogicalWall {
            state.quizSkipUntilLogicalWall = 0
        }
        state.grants.removeAll { state.logicalWall >= $0.expiresAtLogicalWall }
        let today = day(try calendarWall(state), offset: state.configuration.timeZoneIdentifier)
        if today > state.day {
            // Exactly-at-boundary settlements still belong to the lease's previous day.
            if state.active == nil {
                try project(state, db: db)
                state.day = today; state.familyActual = 0; state.personalActual = [:]
                state.familyReportBaseline = 0; state.personalReportBaseline = [:]
                state.familyFrozenCarry = 0; state.personalFrozenCarry = [:]
                state.familyBonusMilliseconds = 0; state.personalBonus = [:]
                state.dayExemptUntilLogicalWall = 0; state.quizSkipUntilLogicalWall = 0
                state.grants = []
                state.quizPassedToday = [:]
                state.quizRewardCountToday = [:]
                state.familyQuizRewardsToday = 0
                state.familyQuizRewardMilliseconds = 0; state.personalQuizRewardMilliseconds = [:]
                state.familyRecoveryFrozen = 0; state.personalRecoveryFrozen = [:]
                state.recoveryQuarantinedDay = nil
                // A pending after-rest gate survives midnight; yesterday's pass does not.
            }
        }
    }
    /// Reposition calendar attribution without granting a new allowance. This is
    /// deliberately NOT rollover: neither confirmation nor migration proves a
    /// waited midnight. Publish the old day first, then carry only its budget debit.
    private static func alignCalendarAccounting(_ state: inout LedgerState, calendarWall: Int64,
                                                db: LedgerDatabase) throws {
        if state.active != nil { try freeze(&state, db: db) }
        let today = day(calendarWall, offset: state.configuration.timeZoneIdentifier)
        if today > state.day {
            try project(state, db: db)
            state.familyReportBaseline = state.familyActual
            state.personalReportBaseline = state.personalActual
            for item in state.frozen where item.day == state.day {
                state.familyFrozenCarry += item.milliseconds
                for id in item.viewerIDs { state.personalFrozenCarry[id.uuidString, default: 0] += item.milliseconds }
            }
            // Moving the attribution day may never unlock a quarantined restore.
            if state.recoveryQuarantinedDay != nil { state.recoveryQuarantinedDay = today }
            state.day = today
        }
        state.calendarAccountingAligned = true
        // Existing grant history remains immutable. Effective relief can only be
        // shortened to the newly confirmed midnight, never extended by recovery.
        let midnightDeadline = state.logicalWall + untilNextDay(calendarWall, timeZone: state.configuration.timeZoneIdentifier)
        state.grants = state.grants.compactMap { grant in
            let expiry = min(grant.expiresAtLogicalWall, midnightDeadline)
            guard expiry > state.logicalWall else { return nil }
            return TemporaryGrant(id: grant.id, kind: grant.kind, bonusMilliseconds: grant.bonusMilliseconds,
                viewerIDs: grant.viewerIDs, expiresAtLogicalWall: expiry, note: grant.note,
                issuedAtLogicalWall: grant.issuedAtLogicalWall)
        }
        if state.dayExemptUntilLogicalWall > 0 {
            state.dayExemptUntilLogicalWall = min(state.dayExemptUntilLogicalWall, midnightDeadline)
        }
        if state.quizSkipUntilLogicalWall > 0 {
            state.quizSkipUntilLogicalWall = min(state.quizSkipUntilLogicalWall, midnightDeadline)
        }
    }

    private static func distrust(_ state: inout LedgerState, reason: LedgerClockRecoveryReason,
                                 db: LedgerDatabase) throws {
        if state.active != nil { try freeze(&state, db: db) }
        state.clockTrusted = false
        state.clockRecoveryReason = reason
        if reason == .bootChanged { state.kernelBootChangeRequiresParent = true }
        // Keep both good samples: failed observations cannot move either anchor.
    }

    private static func kernelBootMarkersWithinBudget(_ samples: LedgerClockSample...) -> Bool {
        let values = samples.compactMap { SystemLedgerClock.kernelBootTimeMicroseconds($0.bootSessionID) }
        guard values.count == samples.count, let minimum = values.min(), let maximum = values.max() else { return false }
        // Microsecond precision: 2 seconds + 1 us must not round down and pass.
        return maximum - minimum <= clockDriftBudgetMilliseconds * 1_000
    }

    private static func bootMarkersMatch(_ previous: LedgerClockSample, _ now: LedgerClockSample) -> Bool {
        guard let boot = previous.bootSessionID, let current = now.bootSessionID else { return false }
        if boot == current { return true } // UUID and other opaque identities stay exact.
        // Tolerance is never enough by itself: maintain also proves timebase,
        // monotonic ordering and all three fixed-anchor wall/monotonic intervals.
        return kernelBootMarkersWithinBudget(previous, now)
    }

    private static func continuityFailure(from previous: LedgerClockSample, to now: LedgerClockSample,
                                          requireBoot: Bool) -> LedgerClockRecoveryReason? {
        if previous.bootSessionID != nil, now.bootSessionID != nil, !bootMarkersMatch(previous, now) {
            return .bootChanged
        }
        guard let source = previous.monotonicSource, let currentSource = now.monotonicSource else {
            // Old clients may still use the original initializer within one process.
            // This exception never proves an upgrade/restart or unlocks a persisted false.
            if !requireBoot, previous.monotonicSource == nil, now.monotonicSource == nil,
               previous.continuityID == now.continuityID { return nil }
            return .legacyContinuityUnverifiable
        }
        guard source == currentSource else { return .sourceChanged }
        if previous.bootSessionID != nil, now.bootSessionID != nil {
            return bootMarkersMatch(previous, now) ? nil : .bootChanged
        }
        if !requireBoot, previous.continuityID == now.continuityID { return nil }
        return .bootIdentityUnavailable
    }

    private static func freeze(_ state: inout LedgerState, db: LedgerDatabase) throws {
        guard let active = state.active else { return }
        state.frozen.append(FrozenReservation(leaseID: active.lease.id,
            eventID: active.lease.eventID, viewerIDs: active.lease.viewerIDs,
            milliseconds: active.lease.reservedMilliseconds, day: state.day))
        state.continuousFrozen += active.lease.reservedMilliseconds
        state.active = nil
        try db.execute("UPDATE usage_events SET status='frozen' WHERE lease_id=?", [active.lease.id.uuidString])
        startRestIfNeeded(&state)
    }
    private static func startRestIfNeeded(_ state: inout LedgerState) {
        if state.continuousActual + state.continuousFrozen >= state.configuration.continuousLimitMilliseconds,
           state.restRemaining == 0 {
            state.restRemaining = state.configuration.restMilliseconds
            state.restID = UUID(); state.restStartedLogicalWall = state.logicalWall
        }
    }
    /// Pure projection shared by snapshot and reserve after calendar maintenance.
    /// It only identifies quiz requirements; rest, trust, quota and other gates
    /// remain independently enforced by reserve.
    private static func pendingQuizViewerIDs(_ state: LedgerState) -> [UUID] {
        guard let rules = state.configuration.quizRules else { return [] }
        return state.viewers.filter { id in
            guard !hasGrant(.dayExemption, childID: id, state: state),
                  !hasGrant(.skipQuiz, childID: id, state: state) else { return false }
            return (rules.quizBeforeFirstWatch && state.quizPassedToday[id.uuidString] != true)
                || (rules.quizAfterRest && state.restNeedingQuiz[id.uuidString] == true)
        }
    }
    private static func hasGrant(_ kind: TemporaryGrant.Kind, childID: UUID, state: LedgerState) -> Bool {
        state.grants.contains { $0.kind == kind && state.logicalWall < $0.expiresAtLogicalWall
            && ($0.isFamilyWide || $0.viewerIDs.contains(childID)) }
    }
    private static func isDayExempt(_ state: LedgerState) -> Bool {
        !state.viewers.isEmpty && state.viewers.allSatisfy { hasGrant(.dayExemption, childID: $0, state: state) }
    }
    // Shared spendable-balance arithmetic. reserve has no active lease; the child
    // projection also includes measured, not-yet-settled playback exactly once.
    private static func familyRemaining(_ state: LedgerState) -> Int64 {
        let allowance = isDayExempt(state) ? Int64.max / 4
            : state.configuration.dailyLimitMilliseconds + state.familyBonusMilliseconds + state.familyQuizRewardMilliseconds
        return max(0, allowance - state.familyActual - familyFrozen(state) - (state.active?.actualMilliseconds ?? 0))
    }
    private static func personalRemaining(_ state: LedgerState, id: UUID) throws -> Int64 {
        guard let profile = state.profiles[id.uuidString], profile.isEnabled else {
            throw LedgerError.invalidInput("inactive profile")
        }
        let allowance = hasGrant(.dayExemption, childID: id, state: state) ? Int64.max / 4
            : profile.dailyLimitMilliseconds + state.personalBonus[id.uuidString, default: 0]
                + state.personalQuizRewardMilliseconds[id.uuidString, default: 0]
        let active = state.active.flatMap { $0.lease.viewerIDs.contains(id) ? $0.actualMilliseconds : nil } ?? 0
        return max(0, allowance - state.personalActual[id.uuidString, default: 0] - personalFrozen(state, id: id) - active)
    }
    private static func continuousRemaining(_ state: LedgerState) -> Int64 {
        max(0, state.configuration.continuousLimitMilliseconds - state.continuousActual
            - state.continuousFrozen - (state.active?.actualMilliseconds ?? 0))
    }
    private static func familyFrozen(_ state: LedgerState) -> Int64 {
        state.familyRecoveryFrozen + state.familyFrozenCarry
            + state.frozen.filter { $0.day == state.day }.reduce(0) { $0 + $1.milliseconds }
    }
    private static func personalFrozen(_ state: LedgerState, id: UUID) -> Int64 {
        state.personalRecoveryFrozen[id.uuidString, default: 0] + state.personalFrozenCarry[id.uuidString, default: 0]
            + state.frozen.filter { $0.day == state.day && $0.viewerIDs.contains(id) }.reduce(0) { $0 + $1.milliseconds }
    }
    private static func day(_ wall: Int64, offset: String) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: offset)!
        let parts = calendar.dateComponents([.year, .month, .day],
            from: Date(timeIntervalSince1970: Double(wall) / 1_000))
        return Int64(parts.year! * 10_000 + parts.month! * 100 + parts.day!)
    }
    private static func untilNextDay(_ wall: Int64, timeZone: String) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let date = Date(timeIntervalSince1970: Double(wall) / 1_000)
        let end = calendar.dateInterval(of: .day, for: date)!.end
        return max(1, Int64((end.timeIntervalSince1970 * 1_000).rounded()) - wall)
    }

    /// Date/time policy follows the validated clock, not the accounting timeline
    /// retained during recovery. Advance the fixed trusted anchor monotonically;
    /// never read Date() here or use an unchecked wall-clock adjustment.
    private static func calendarWall(_ state: LedgerState) throws -> Int64 {
        guard state.clockTrusted else { throw LedgerError.clockUntrusted }
        return try lastCalendarWall(state)
    }

    private static func lastCalendarWall(_ state: LedgerState) throws -> Int64 {
        guard isValidSample(state.clockAnchor), isValidSample(state.lastClock),
              state.lastClock.monotonicMilliseconds >= state.clockAnchor.monotonicMilliseconds else {
            throw LedgerError.clockUntrusted
        }
        let elapsed = state.lastClock.monotonicMilliseconds - state.clockAnchor.monotonicMilliseconds
        guard state.clockAnchor.wallMilliseconds >= 0,
              state.clockAnchor.wallMilliseconds <= maximumWallMilliseconds - elapsed else {
            throw LedgerError.clockUntrusted
        }
        return state.clockAnchor.wallMilliseconds + elapsed
    }

    /// Pure local-minute predicate shared by lease edges and next-opening search.
    /// Configuration is validated before either entry point uses it.
    private static func scheduleAllows(_ date: Date, schedule: FamilySchedule, calendar: Calendar) throws -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            throw LedgerError.invalidInput("unreadable schedule calendar")
        }
        let minuteOfDay = hour * 60 + minute
        let window = (2...6).contains(weekday) ? schedule.weekday : schedule.weekend
        if let window, minuteOfDay < window.startMinuteOfDay || minuteOfDay >= window.endMinuteOfDay {
            return false
        }
        if let bedtime = schedule.bedtimeWindow {
            let inBedtime = bedtime.start > bedtime.end
                ? (minuteOfDay >= bedtime.start || minuteOfDay < bedtime.end)
                : (minuteOfDay >= bedtime.start && minuteOfDay < bedtime.end)
            if inBedtime { return false }
        }
        return true
    }

    /// A bounded set of local civil-time edges, not elapsed hours from midnight.
    /// Include both occurrences of repeated minutes and the clock transition itself:
    /// a fall-back jump can reopen a window even before its second start edge.
    private static func scheduleEdges(on date: Date, schedule: FamilySchedule, calendar: Calendar) throws -> [Date] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw LedgerError.invalidInput("unreadable schedule calendar")
        }
        let weekday = calendar.component(.weekday, from: start)
        let window = (2...6).contains(weekday) ? schedule.weekday : schedule.weekend
        var minutes: Set<Int> = [0, 1440]
        if let window { minutes.formUnion([window.startMinuteOfDay, window.endMinuteOfDay]) }
        if let bedtime = schedule.bedtimeWindow { minutes.formUnion([bedtime.start, bedtime.end]) }
        var edges: Set<Date> = [start, end]
        for minute in minutes where minute > 0 && minute < 1440 {
            let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
            for occurrence in [Calendar.RepeatedTimePolicy.first, .last] {
                guard let edge = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components,
                    matchingPolicy: .nextTime, repeatedTimePolicy: occurrence, direction: .forward) else {
                    throw LedgerError.invalidInput("unreadable schedule edge")
                }
                // Missing spring-forward minutes resolve to the first existing
                // instant after the gap; always recheck the policy at that instant.
                if edge >= start && edge <= end { edges.insert(edge) }
            }
        }
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-1)),
           transition >= start && transition < end { edges.insert(transition) }
        return edges.sorted()
    }

    /// Returns whether the local minute is blocked and the next real blocking
    /// edge. Both this gate and the child-facing opening search use the same
    /// civil-time construction, including 23/25-hour days and repeated minutes.
    private static func scheduleRemaining(_ wall: Int64, config: FamilyConfiguration)
        throws -> (blocked: Bool, remainingMilliseconds: Int64?) {
        try validate(config)
        guard let schedule = config.schedule else { return (false, nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: config.timeZoneIdentifier)!
        let date = Date(timeIntervalSince1970: Double(wall) / 1_000)
        guard try scheduleAllows(date, schedule: schedule, calendar: calendar) else { return (true, nil) }
        for edge in try scheduleEdges(on: date, schedule: schedule, calendar: calendar) where edge > date {
            if try !scheduleAllows(edge, schedule: schedule, calendar: calendar) {
                return (false, max(1, Int64((edge.timeIntervalSince1970 * 1_000).rounded()) - wall))
            }
        }
        // reserve independently caps every lease at the next civil midnight.
        return (false, nil)
    }

    private static func nextScheduleOpening(_ wall: Int64, config: FamilyConfiguration) throws -> Int64? {
        try validate(config)
        guard let schedule = config.schedule else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: config.timeZoneIdentifier)!
        let date = Date(timeIntervalSince1970: Double(wall) / 1_000)
        let start = calendar.startOfDay(for: date)
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                throw LedgerError.invalidInput("unreadable schedule calendar")
            }
            for edge in try scheduleEdges(on: day, schedule: schedule, calendar: calendar) where edge > date {
                if try scheduleAllows(edge, schedule: schedule, calendar: calendar) {
                    return Int64((edge.timeIntervalSince1970 * 1_000).rounded())
                }
            }
        }
        return nil
    }
    private static func validateRequestedMilliseconds(_ milliseconds: Int64) throws {
        guard milliseconds > 0, milliseconds <= maximumDuration else {
            throw LedgerError.invalidInput("invalid lease request")
        }
    }
    private static func isValidSample(_ sample: LedgerClockSample) -> Bool {
        sample.wallMilliseconds >= 0 && sample.wallMilliseconds <= maximumWallMilliseconds
            && sample.monotonicMilliseconds >= 0 && sample.monotonicMilliseconds <= Int64.max / 4
            && !sample.continuityID.isEmpty
            && sample.monotonicSource?.isEmpty != true && sample.bootSessionID?.isEmpty != true
    }
    private static func validate(_ sample: LedgerClockSample) throws {
        guard isValidSample(sample) else { throw LedgerError.clockUntrusted }
    }
    private static func validate(_ config: FamilyConfiguration) throws {
        guard config.dailyLimitMilliseconds > 0, config.dailyLimitMilliseconds <= maximumDuration,
              config.continuousLimitMilliseconds > 0, config.continuousLimitMilliseconds <= maximumDuration,
              config.restMilliseconds > 0, config.restMilliseconds <= maximumDuration,
              config.maximumLeaseMilliseconds > 0, config.maximumLeaseMilliseconds <= 5_000,
              TimeZone(identifier: config.timeZoneIdentifier) != nil else {
            throw LedgerError.invalidInput("invalid family configuration; leases must be at most 5000ms")
        }
        if let schedule = config.schedule {
            for window in [schedule.weekday, schedule.weekend].compactMap({ $0 }) {
                guard (0...1440).contains(window.startMinuteOfDay),
                      (0...1440).contains(window.endMinuteOfDay),
                      window.startMinuteOfDay < window.endMinuteOfDay else {
                    throw LedgerError.invalidInput("invalid schedule window")
                }
            }
            if let bedtime = schedule.bedtimeWindow {
                guard (0...1440).contains(bedtime.start), (0...1440).contains(bedtime.end),
                      bedtime.start != bedtime.end else {
                    throw LedgerError.invalidInput("invalid bedtime window")
                }
            } else if schedule.bedtimeStartMinute != nil || schedule.bedtimeEndMinute != nil {
                throw LedgerError.invalidInput("bedtime requires both start and end")
            }
        }
        if let quiz = config.quizRules {
            guard (1...10).contains(quiz.questionsPerRound),
                  quiz.passRatio > 0, quiz.passRatio <= 1,
                  (1...120).contains(quiz.rewardMinutes),
                  (0...20).contains(quiz.personalDailyRewards),
                  (0...100).contains(quiz.familyDailyRewards), quiz.ruleVersion > 0,
                  (0...maximumDuration).contains(quiz.maxFamilyDailyRewardMilliseconds),
                  (config.dailyLimitMilliseconds...maximumDuration).contains(quiz.familyAbsoluteTotalMilliseconds) else {
                throw LedgerError.invalidInput("invalid quiz rules")
            }
        }
    }
    private static func backfillVersionOne(_ state: LedgerState, db: LedgerDatabase) throws {
        for row in try db.rows("SELECT request,status,receipt FROM usage_events") {
            guard let request = row[0], let status = row[1] else { throw LedgerError.corruptDatabase }
            let lease = try decode(PlaybackLease.self, request)
            let receipt = try row[2].map { try decode(UsageReceipt.self, $0) }
            let frozen = state.frozen.first { $0.leaseID == lease.id }
            let eventDay = receipt?.day ?? frozen?.day ?? state.day
            let actual = receipt?.actualMilliseconds ?? 0
            try db.execute("INSERT OR IGNORE INTO watch_sessions VALUES(?,?,?,?,?,?,?)",
                [lease.id.uuidString, lease.eventID, String(eventDay), String(lease.reservedMilliseconds),
                 try encode(lease.viewerIDs), status, String(actual)])
            if eventDay != state.day {
                let held = frozen?.milliseconds ?? 0
                try db.execute("INSERT INTO family_daily_usage VALUES(?,?,?) ON CONFLICT(day) DO UPDATE SET actual_ms=actual_ms+excluded.actual_ms,frozen_ms=frozen_ms+excluded.frozen_ms",
                    [String(eventDay), String(actual), String(held)])
                for id in lease.viewerIDs {
                    try db.execute("INSERT INTO child_daily_usage VALUES(?,?,?,?) ON CONFLICT(day,profile_id) DO UPDATE SET actual_ms=actual_ms+excluded.actual_ms,frozen_ms=frozen_ms+excluded.frozen_ms",
                        [String(eventDay), id.uuidString, String(actual), String(held)])
                }
            }
        }
    }
    private static func migrateVersionTwo(_ state: inout LedgerState, db: LedgerDatabase) throws {
        let columns = try db.rows("PRAGMA table_info(parental_audit_logs)").compactMap { $0[1] }
        if !columns.contains("duration_ms") { try db.execute("ALTER TABLE parental_audit_logs ADD COLUMN duration_ms INTEGER") }
        if !columns.contains("action_id") { try db.execute("ALTER TABLE parental_audit_logs ADD COLUMN action_id TEXT") }
        // V2 mixed parental and quiz credit. Split using durable rewards, not current policy.
        for row in try db.rows("SELECT child,SUM(minutes),COUNT(*) FROM quiz_rewards WHERE day=\(state.day) GROUP BY child") {
            guard let child = row[0], let amount = row[1].flatMap(Int64.init), amount >= 0,
                  let count = row[2].flatMap(Int.init) else { throw LedgerError.corruptDatabase }
            state.personalQuizRewardMilliseconds[child] = amount
            state.personalBonus[child] = max(0, state.personalBonus[child, default: 0] - amount)
            state.quizRewardCountToday[child] = max(state.quizRewardCountToday[child, default: 0], count)
        }
        state.familyQuizRewardMilliseconds = state.personalQuizRewardMilliseconds.values.reduce(0, +)
        state.familyBonusMilliseconds = max(0, state.familyBonusMilliseconds - state.familyQuizRewardMilliseconds)
        state.familyQuizRewardsToday = max(state.familyQuizRewardsToday, state.quizRewardCountToday.values.reduce(0, +))
        for grant in state.grants {
            try db.execute("INSERT OR IGNORE INTO temporary_grants(id,payload) VALUES(?,?)", [grant.id.uuidString, try encode(grant)])
        }
    }

    private static func createProjectionTables(_ db: LedgerDatabase) throws {
        let definitions = [
            "family_config (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)",
            "child_profiles (id TEXT PRIMARY KEY, payload TEXT NOT NULL)",
            "active_viewers (profile_id TEXT PRIMARY KEY REFERENCES child_profiles(id))",
            "family_daily_usage (day INTEGER PRIMARY KEY, actual_ms INTEGER NOT NULL, frozen_ms INTEGER NOT NULL)",
            "child_daily_usage (day INTEGER NOT NULL, profile_id TEXT NOT NULL, actual_ms INTEGER NOT NULL, frozen_ms INTEGER NOT NULL, PRIMARY KEY(day,profile_id))",
            "watch_sessions (lease_id TEXT PRIMARY KEY, event_id TEXT UNIQUE NOT NULL, day INTEGER NOT NULL, reserved_ms INTEGER NOT NULL, viewers TEXT NOT NULL, status TEXT NOT NULL, actual_ms INTEGER NOT NULL)",
            "rest_sessions (id TEXT PRIMARY KEY, started_logical_wall_ms INTEGER NOT NULL, remaining_ms INTEGER NOT NULL, completed INTEGER NOT NULL)",
            "parental_audit_logs (id INTEGER PRIMARY KEY, operation TEXT NOT NULL, object TEXT NOT NULL, day INTEGER NOT NULL, logical_wall_ms INTEGER NOT NULL, observed_wall_ms INTEGER NOT NULL, duration_ms INTEGER, action_id TEXT)",
            "quiz_rounds (id TEXT PRIMARY KEY, payload TEXT NOT NULL)",
            "quiz_outcomes (attempt_id TEXT PRIMARY KEY, payload TEXT NOT NULL)",
            "temporary_grants (id TEXT PRIMARY KEY, payload TEXT NOT NULL)",
            "quiz_attempts (attempt_id TEXT PRIMARY KEY, child TEXT NOT NULL, day INTEGER NOT NULL, correct INTEGER NOT NULL, total INTEGER NOT NULL, passed INTEGER NOT NULL, rewarded_minutes INTEGER NOT NULL, wrongs TEXT NOT NULL)",
            "quiz_rewards (attempt_id TEXT PRIMARY KEY, child TEXT NOT NULL, day INTEGER NOT NULL, minutes INTEGER NOT NULL)"
        ]
        for definition in definitions { try db.execute("CREATE TABLE IF NOT EXISTS " + definition) }
    }
    /// Transactional audit/report projections; old day/session rows are never cleared at rollover.
    private static func project(_ state: LedgerState, db: LedgerDatabase) throws {
        try db.execute("INSERT INTO family_config VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [try encode(state.configuration)])
        try db.execute("DELETE FROM active_viewers")
        // This is the live projection, not history. Historical daily/session rows remain.
        try db.execute("DELETE FROM child_profiles")
        for profile in state.profiles.values {
            try db.execute("INSERT INTO child_profiles VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [profile.id.uuidString, try encode(profile)])
            try db.execute("INSERT INTO child_daily_usage VALUES(?,?,?,?) ON CONFLICT(day,profile_id) DO UPDATE SET actual_ms=excluded.actual_ms,frozen_ms=excluded.frozen_ms",
                [String(state.day), profile.id.uuidString,
                 String(max(0, state.personalActual[profile.id.uuidString, default: 0] - state.personalReportBaseline[profile.id.uuidString, default: 0])),
                 String(personalFrozen(state, id: profile.id) - state.personalFrozenCarry[profile.id.uuidString, default: 0])])
        }
        for id in state.viewers { try db.execute("INSERT INTO active_viewers VALUES(?)", [id.uuidString]) }
        try db.execute("INSERT INTO family_daily_usage VALUES(?,?,?) ON CONFLICT(day) DO UPDATE SET actual_ms=excluded.actual_ms,frozen_ms=excluded.frozen_ms",
            [String(state.day), String(max(0, state.familyActual - state.familyReportBaseline)),
             String(familyFrozen(state) - state.familyFrozenCarry)])
        if let active = state.active {
            try db.execute("INSERT INTO watch_sessions VALUES(?,?,?,?,?,'active',0) ON CONFLICT(lease_id) DO NOTHING",
                [active.lease.id.uuidString, active.lease.eventID, String(state.day), String(active.lease.reservedMilliseconds), try encode(active.lease.viewerIDs)])
        }
        for item in state.frozen {
            try db.execute("UPDATE watch_sessions SET status='frozen',actual_ms=0 WHERE lease_id=?", [item.leaseID.uuidString])
        }
        if let restID = state.restID, let started = state.restStartedLogicalWall {
            try db.execute("INSERT INTO rest_sessions VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET remaining_ms=excluded.remaining_ms,completed=excluded.completed",
                [restID.uuidString, String(started), String(state.restRemaining), state.restRemaining == 0 ? "1" : "0"])
        }
    }
    private static func readState(_ db: LedgerDatabase) throws -> LedgerState {
        guard let payload = try db.scalar("SELECT payload FROM ledger_state WHERE id=1") else {
            throw LedgerError.corruptDatabase
        }
        return try decode(LedgerState.self, payload)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
        catch { throw LedgerError.corruptDatabase }
    }
}
