import Foundation

public enum LedgerAdminOperation: String, Codable, Sendable {
    case configureFamily, upsertProfile, selectViewers, reanchorClock, temporaryOverride
}

/// A parent-issued, time-boxed relief. All grants are audited; bonus amounts are
/// never counted as watched time. `skipQuiz` is consumed by the quiz gate (P4).
public struct TemporaryGrant: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bonusTime, dayExemption, skipQuiz
    }

    public let id: UUID
    public let kind: Kind
    public let bonusMilliseconds: Int64
    public let viewerIDs: [UUID]
    public let expiresAtLogicalWall: Int64
    public let note: String
    public let issuedAtLogicalWall: Int64?
    /// Empty viewerIDs is an explicitly family-wide legacy grant.
    public var isFamilyWide: Bool { viewerIDs.isEmpty }

    public init(id: UUID = UUID(), kind: Kind, bonusMilliseconds: Int64 = 0,
                viewerIDs: [UUID] = [], expiresAtLogicalWall: Int64, note: String,
                issuedAtLogicalWall: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.bonusMilliseconds = bonusMilliseconds
        self.viewerIDs = viewerIDs
        self.expiresAtLogicalWall = expiresAtLogicalWall
        self.note = note
        self.issuedAtLogicalWall = issuedAtLogicalWall
    }
}

/// The service checks an opaque, operation-scoped credential. No caller-supplied parent Bool.
public protocol LedgerAdminAuthorizing: Sendable {
    func authorize(operation: LedgerAdminOperation, credential: Data) throws
}

public enum LedgerError: Error, Equatable, Sendable {
    case unauthorized, invalidInput(String), database(String), corruptDatabase
    case unsupportedSchema(Int), checkpointMismatch, missingDatabase, securityStoreUnavailable
    case clockUntrusted, noActiveViewers, leaseAlreadyActive, invalidLease, leaseExpired
    case budgetExhausted, resting, eventConflict, closed, ledgerAlreadyOpen, scheduleBlocked
    case quizRequired
}

/// Allowed viewing window in local minutes-of-day. Non-wrapping: start < end.
public struct DailyScheduleWindow: Codable, Equatable, Sendable {
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int
    public init(startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }
}

/// Workday vs weekend allowed windows plus an optional bedtime block that may
/// wrap midnight (start > end, e.g. 22:00–07:00). nil fields mean unrestricted.
/// Optional properties decode as nil from configurations written before this
/// existed, so older ledger payloads keep migrating without loss.
public struct FamilySchedule: Codable, Equatable, Sendable {
    public var weekday: DailyScheduleWindow?
    public var weekend: DailyScheduleWindow?
    public var bedtimeStartMinute: Int?
    public var bedtimeEndMinute: Int?
    public init(weekday: DailyScheduleWindow? = nil, weekend: DailyScheduleWindow? = nil,
                bedtimeStartMinute: Int? = nil, bedtimeEndMinute: Int? = nil) {
        self.weekday = weekday
        self.weekend = weekend
        self.bedtimeStartMinute = bedtimeStartMinute
        self.bedtimeEndMinute = bedtimeEndMinute
    }
    /// nil = bedtime unrestricted; otherwise the (possibly midnight-wrapping) block.
    public var bedtimeWindow: (start: Int, end: Int)? {
        guard let bedtimeStartMinute, let bedtimeEndMinute else { return nil }
        return (bedtimeStartMinute, bedtimeEndMinute)
    }
}

public struct CurriculumProfile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var schoolStage: String
    public var schoolSystem: String
    public var grade: Int
    public var academicYear: String
    public var semester: String
    public var subjects: [String]
    public var subjectTextbookVersions: [String: String]
    public var learnedChapters: [String: [String]]
    public var chapterProgress: [String: [String: Int]]

    public init(schoolStage: String, schoolSystem: String, grade: Int,
                academicYear: String, semester: String, subjects: [String] = [],
                subjectTextbookVersions: [String: String] = [:],
                learnedChapters: [String: [String]] = [:],
                chapterProgress: [String: [String: Int]] = [:]) {
        self.schoolStage = schoolStage; self.schoolSystem = schoolSystem; self.grade = grade
        self.academicYear = academicYear; self.semester = semester; self.subjects = subjects
        self.subjectTextbookVersions = subjectTextbookVersions
        self.learnedChapters = learnedChapters; self.chapterProgress = chapterProgress
    }
}

public struct ViewerProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var avatarSymbol: String
    public var curriculum: CurriculumProfile
    public var dailyLimitMilliseconds: Int64
    public var isEnabled: Bool
    public init(id: UUID = UUID(), displayName: String, avatarSymbol: String = "person",
                curriculum: CurriculumProfile, dailyLimitMilliseconds: Int64,
                isEnabled: Bool = true) {
        self.id = id; self.displayName = displayName; self.avatarSymbol = avatarSymbol
        self.curriculum = curriculum; self.dailyLimitMilliseconds = dailyLimitMilliseconds
        self.isEnabled = isEnabled
    }
}

public struct FamilyConfiguration: Codable, Equatable, Sendable {
    public var dailyLimitMilliseconds: Int64
    public var continuousLimitMilliseconds: Int64
    public var restMilliseconds: Int64
    public var maximumLeaseMilliseconds: Int64
    /// Family-owned IANA timezone, independent of device timezone changes.
    public var timeZoneIdentifier: String
    /// Workday/weekend windows and bedtime block. nil = unrestricted (pre-schedule configs).
    public var schedule: FamilySchedule?
    /// Quiz/reward policy. nil = feature disabled, preserving pre-quiz behavior.
    public var quizRules: QuizRules?
    public init(dailyLimitMilliseconds: Int64 = 7_200_000,
                continuousLimitMilliseconds: Int64 = 2_400_000,
                restMilliseconds: Int64 = 600_000, maximumLeaseMilliseconds: Int64 = 5_000,
                timeZoneIdentifier: String = "Asia/Shanghai",
                schedule: FamilySchedule? = nil, quizRules: QuizRules? = nil) {
        self.dailyLimitMilliseconds = dailyLimitMilliseconds
        self.continuousLimitMilliseconds = continuousLimitMilliseconds
        self.restMilliseconds = restMilliseconds
        self.maximumLeaseMilliseconds = maximumLeaseMilliseconds
        self.timeZoneIdentifier = timeZoneIdentifier
        self.schedule = schedule
        self.quizRules = quizRules
    }
}

public struct LedgerCheckpoint: Codable, Equatable, Sendable {
    public let databaseID: UUID
    public let revision: Int64
    public let commitToken: UUID
    public init(databaseID: UUID, revision: Int64, commitToken: UUID) {
        self.databaseID = databaseID; self.revision = revision; self.commitToken = commitToken
    }
}

/// Store outside SQLite (app: Keychain). CAS must be synchronous, durable and thread safe.
/// An unavailable store must throw, never return nil as a substitute for an error.
public protocol LedgerCheckpointStore: Sendable {
    func load() throws -> LedgerCheckpoint?
    func compareAndSwap(expected: LedgerCheckpoint?, new: LedgerCheckpoint) throws
}

public struct PlaybackLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let eventID: String
    public let viewerIDs: [UUID]
    public let reservedMilliseconds: Int64
    public let expiresAtMonotonicMilliseconds: Int64
    public let continuityID: String
}

public enum PlaybackActivity: String, Codable, Sendable { case playing, paused, buffering }
public struct UsageReceipt: Codable, Equatable, Sendable {
    public let eventID: String
    public let leaseID: UUID
    public let actualMilliseconds: Int64
    public let viewerIDs: [UUID]
    public let day: Int64
}

/// A measured settlement and, if budget/rest policy permits, its immediately playable successor.
public struct PlaybackRenewal: Codable, Equatable, Sendable {
    public let receipt: UsageReceipt
    public let nextLease: PlaybackLease?
}

public struct FrozenReservation: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let eventID: String
    public let viewerIDs: [UUID]
    public let milliseconds: Int64
    public let day: Int64
}

public struct LedgerBackupState: Sendable {
    public let checkpoint: LedgerCheckpoint
    public let day: Int64
    public let hasActiveLease: Bool
    public let clockIsTrusted: Bool
}

/// Why clock continuity needs a parent acknowledgment. Explicit anomalies stay latched.
public enum LedgerClockRecoveryReason: String, Codable, Sendable {
    case legacyContinuityUnverifiable, sourceChanged, bootChanged, bootIdentityUnavailable
    case wallDrift, monotonicRollback, invalidSample, restoredBackup
}

/// Child-safe policy projection for the current viewers, not a playback lease.
/// No identities, individual balances, grants or quiz answers are exposed.
public struct PlaybackAvailability: Equatable, Sendable {
    public enum BlockedReason: String, Codable, Sendable {
        case clockUntrusted, noViewers, resting, scheduleBlocked, budgetExhausted
        case quizRequired, ready, recoveryQuarantine
    }

    /// Policy gates only; .ready does not reserve time or authorize a renderer.
    public let blockedReason: BlockedReason
    /// Spendable daily balances, including earned/parental credit and all carried
    /// and frozen debits. Measured active playback is deducted, not idle time or
    /// the unused part of an active lease. These are NOT watched-time counters.
    public let familyRemainingMs: Int64
    public let limitingPersonalRemainingMs: Int64
    /// min(familyRemainingMs, limitingPersonalRemainingMs), independent of rest,
    /// schedule and continuous limits. Zero when no viewers are selected.
    public let availableRemainingMs: Int64
    public let continuousRemainingMs: Int64
    public let restRemainingMs: Int64
    /// The next schedule-only opening when currently schedule-blocked; nil when
    /// unrestricted, exempt, clock-untrusted, or no opening exists in eight days.
    /// Other gates (rest, budget, quiz) still apply at that time.
    public let nextScheduleOpeningWallMilliseconds: Int64?
    /// Fixed trusted anchor + proven monotonic elapsed time. While clock-blocked
    /// this stays at the last proven instant, never the untrusted device clock.
    public let calendarWallMilliseconds: Int64
    public let timeZoneIdentifier: String
    /// Unmet quiz gate, even when a higher-priority gate currently blocks viewing.
    public let quizRequired: Bool
    public let isScheduleBlocked: Bool
    /// Quiz may earn more time even when the current daily balance is zero.
    public let canStartQuiz: Bool
    /// All selected viewers have live daily/schedule relief. Daily balances then
    /// use reserve's Int64.max / 4 allowance, less debits; display as exempt,
    /// not as an enormous minute count. Continuous/rest protection still applies.
    public let isDayExempt: Bool
}

public struct LedgerSnapshot: Sendable {
    public let configuration: FamilyConfiguration
    public let profiles: [ViewerProfile]
    public let activeViewerIDs: [UUID]
    public let day: Int64
    public let familyActualMilliseconds: Int64
    public let personalActualMilliseconds: [UUID: Int64]
    public let familyFrozenMilliseconds: Int64
    public let personalFrozenMilliseconds: [UUID: Int64]
    public let continuousActualMilliseconds: Int64
    public let continuousFrozenMilliseconds: Int64
    public let remainingRestMilliseconds: Int64
    public let clockIsTrusted: Bool
    public let clockRecoveryReason: LedgerClockRecoveryReason?
    public let recoveryQuarantineActive: Bool
    public let activeLease: PlaybackLease?
    public let frozenReservations: [FrozenReservation]
    public let checkpoint: LedgerCheckpoint
    public let grants: [TemporaryGrant]
    public let familyBonusMilliseconds: Int64
    public let dayExemptionActive: Bool
    public let quizSkipActive: Bool
    public let parentalBonusMilliseconds: Int64
    public let familyQuizRewardMilliseconds: Int64
    public let familyRecoveryFrozenMilliseconds: Int64
    /// Historical watched time still debited from today's allowance after clock
    /// recovery. Subtract from actual for today's display; never subtract from quota.
    public let familyCarriedActualMilliseconds: Int64
    public let personalCarriedActualMilliseconds: [UUID: Int64]
    /// Current selected viewers whose quiz gate is unmet, in activeViewerIDs order.
    /// Excludes recipients of live quiz-skip/day-exemption relief; reading does not
    /// consume qualification or relief. An empty list does not waive other gates.
    public let pendingQuizViewerIDs: [UUID]
}
