import Foundation

public struct QuizOption: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct QuizQuestion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let grade: Int
    public let subject: String
    public let difficulty: String
    public let prompt: String
    public let options: [QuizOption]
    public let answerID: String
    public let explanation: String
    public let sourcePage: Int?
    /// Optional, caller-declared provenance; nil never implies a verified textbook source.
    public let sourceMetadata: QuizSourceMetadata?

    public init(id: String, grade: Int, subject: String, difficulty: String,
                prompt: String, options: [QuizOption], answerID: String,
                explanation: String, sourcePage: Int? = nil, sourceMetadata: QuizSourceMetadata? = nil) {
        self.id = id
        self.grade = grade
        self.subject = subject
        self.difficulty = difficulty
        self.prompt = prompt
        self.options = options
        self.answerID = answerID
        self.explanation = explanation
        self.sourcePage = sourcePage
        self.sourceMetadata = sourceMetadata
    }
}

public struct QuizSourceMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let edition: String?
    public let chapter: String?
    public let reference: String?
    public let stage: String?
    public let system: String?
    public let semester: String?
    public let textbookVersion: String?
    public let knowledgePoints: [String]?
    public let source: String?
    public init(title: String? = nil, edition: String? = nil, chapter: String? = nil, reference: String? = nil,
                stage: String? = nil, system: String? = nil, semester: String? = nil,
                textbookVersion: String? = nil, knowledgePoints: [String]? = nil, source: String? = nil) {
        self.title = title; self.edition = edition; self.chapter = chapter; self.reference = reference
        self.stage = stage; self.system = system; self.semester = semester
        self.textbookVersion = textbookVersion; self.knowledgePoints = knowledgePoints; self.source = source
    }
}

/// Explicit parent-configurable policy. A nil FamilyConfiguration.quizRules disables quizzes.
public struct QuizRules: Codable, Equatable, Sendable {
    public var questionsPerRound: Int
    public var passRatio: Double
    public var rewardMinutes: Int
    public var personalDailyRewards: Int
    public var familyDailyRewards: Int
    public var quizBeforeFirstWatch: Bool
    public var quizAfterRest: Bool
    public var ruleVersion: Int
    public var maxFamilyDailyRewardMilliseconds: Int64
    /// Absolute family daily allowance including base, parental bonus and quiz rewards.
    public var familyAbsoluteTotalMilliseconds: Int64

    public init(questionsPerRound: Int = 5, passRatio: Double = 0.6, rewardMinutes: Int = 10,
                personalDailyRewards: Int = 3, familyDailyRewards: Int = 6,
                quizBeforeFirstWatch: Bool = false, quizAfterRest: Bool = true,
                ruleVersion: Int = 1, maxFamilyDailyRewardMilliseconds: Int64 = 3_600_000,
                familyAbsoluteTotalMilliseconds: Int64 = 86_400_000) {
        self.questionsPerRound = questionsPerRound
        self.passRatio = passRatio
        self.rewardMinutes = rewardMinutes
        self.personalDailyRewards = personalDailyRewards
        self.familyDailyRewards = familyDailyRewards
        self.quizBeforeFirstWatch = quizBeforeFirstWatch
        self.quizAfterRest = quizAfterRest
        self.ruleVersion = ruleVersion
        self.maxFamilyDailyRewardMilliseconds = maxFamilyDailyRewardMilliseconds
        self.familyAbsoluteTotalMilliseconds = familyAbsoluteTotalMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case questionsPerRound, passRatio, rewardMinutes, personalDailyRewards, familyDailyRewards
        case quizBeforeFirstWatch, quizAfterRest, ruleVersion, maxFamilyDailyRewardMilliseconds, familyAbsoluteTotalMilliseconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuizRules()
        questionsPerRound = try c.decodeIfPresent(Int.self, forKey: .questionsPerRound) ?? defaults.questionsPerRound
        passRatio = try c.decodeIfPresent(Double.self, forKey: .passRatio) ?? defaults.passRatio
        rewardMinutes = try c.decodeIfPresent(Int.self, forKey: .rewardMinutes) ?? defaults.rewardMinutes
        personalDailyRewards = try c.decodeIfPresent(Int.self, forKey: .personalDailyRewards) ?? defaults.personalDailyRewards
        familyDailyRewards = try c.decodeIfPresent(Int.self, forKey: .familyDailyRewards) ?? defaults.familyDailyRewards
        quizBeforeFirstWatch = try c.decodeIfPresent(Bool.self, forKey: .quizBeforeFirstWatch) ?? defaults.quizBeforeFirstWatch
        quizAfterRest = try c.decodeIfPresent(Bool.self, forKey: .quizAfterRest) ?? defaults.quizAfterRest
        ruleVersion = try c.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? defaults.ruleVersion
        maxFamilyDailyRewardMilliseconds = try c.decodeIfPresent(Int64.self, forKey: .maxFamilyDailyRewardMilliseconds) ?? defaults.maxFamilyDailyRewardMilliseconds
        familyAbsoluteTotalMilliseconds = try c.decodeIfPresent(Int64.self, forKey: .familyAbsoluteTotalMilliseconds) ?? defaults.familyAbsoluteTotalMilliseconds
    }
}

public struct QuizRound: Codable, Equatable, Sendable {
    public let id: UUID
    public let childID: UUID
    public let questions: [QuizQuestion]
    public init(id: UUID, childID: UUID, questions: [QuizQuestion]) {
        self.id = id; self.childID = childID; self.questions = questions
    }
}

public struct QuizOutcome: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let childID: UUID
    public let correctCount: Int
    public let total: Int
    public let passed: Bool
    /// Historical API name; the value is milliseconds, not minutes.
    public let rewardMinutes: Int64
    public var rewardMilliseconds: Int64 { rewardMinutes }
    public let rewardDeniedReason: String?
}

public struct QuizWrongAnswer: Codable, Equatable, Sendable {
    public let questionID: String
    public let prompt: String
    public let chosenOptionID: String
    public let correctOptionID: String
    public let explanation: String
    public let day: Int64
    public var childID: UUID?
    public var attemptID: UUID?
}
