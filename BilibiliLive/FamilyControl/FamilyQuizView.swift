import FamilyCore
import SwiftUI
import UIKit

/// Child-facing quiz screen. Each requested child must pass their own round.
final class FamilyQuizViewController: UIHostingController<FamilyQuizView> {
    var onPassed: (() -> Void)?
    private let onFinished: (() -> Void)?
    private let playbackModeGeneration = PlaybackCoordinator.shared.modeGeneration
    private let childPlaybackGeneration = PlaybackCoordinator.shared.childPlaybackGeneration
    private var lifecycleObservers = [NSObjectProtocol]()
    private var passageInvalidated = false
    private var isFinishing = false
    private var reportedFinish = false

    convenience init(environment: FamilyEnvironment, childID: UUID, onFinished: (() -> Void)? = nil) {
        self.init(environment: environment, viewerIDs: [childID], onFinished: onFinished)
    }

    /// After dismissal: onPassed fires only for an explicit Complete after ALL
    /// requested viewers passed; onFinished then fires for every exit (legacy API).
    /// Menu, load/submit errors and an unpassed round never report onPassed.
    init(environment: FamilyEnvironment, viewerIDs: [UUID], onFinished: (() -> Void)? = nil) {
        self.onFinished = onFinished
        super.init(rootView: FamilyQuizView(environment: environment, viewerIDs: viewerIDs))
        modalPresentationStyle = .overFullScreen
        for name in [UIApplication.willResignActiveNotification, PlaybackCoordinator.modeWillChangeNotification,
                     PlaybackCoordinator.clockRecoveryNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                FamilyPlayer.onMain { self?.passageInvalidated = true }
            })
        }
        rootView.dismissPresented = { [weak self] passed in
            guard let self, !self.isFinishing else { return }
            self.isFinishing = true
            // A SwiftUI dismiss alone does not reliably dismiss a root hosting VC.
            self.dismiss(animated: true) { self.reportFinish(passed: passed) }
        }
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isFinishing && (isBeingDismissed || presentingViewController == nil) {
            reportFinish(passed: false)
        }
    }

    private func reportFinish(passed: Bool) {
        guard !reportedFinish else { return }
        reportedFinish = true
        if passed, !passageInvalidated, UIApplication.shared.applicationState == .active,
           playbackModeGeneration == PlaybackCoordinator.shared.modeGeneration,
           childPlaybackGeneration == PlaybackCoordinator.shared.childPlaybackGeneration {
            onPassed?()
        }
        onFinished?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

struct FamilyQuizView: View {
    @ObservedObject var environment: FamilyEnvironment
    @Environment(\.dismiss) private var dismiss
    @Namespace private var optionFocus
    @FocusState private var focusedOption: String?
    @FocusState private var focusedFinish: Bool
    let viewerIDs: [UUID]
    var onPassed: (() -> Void)?
    var onFinished: (() -> Void)?
    var dismissPresented: ((Bool) -> Void)?
    @State private var passedViewerIDs = Set<UUID>()
    @State private var childIndex = 0
    @State private var round: QuizRound?
    @State private var answers: [String: String] = [:]
    @State private var outcome: QuizOutcome?
    @State private var index = 0
    @State private var message = "正在准备题目…"
    @State private var preparing = false
    @State private var submitting = false
    @State private var finished = false

    init(environment: FamilyEnvironment, childID: UUID, onFinished: (() -> Void)? = nil) {
        self.init(environment: environment, viewerIDs: [childID], onFinished: onFinished)
    }

    init(environment: FamilyEnvironment, viewerIDs: [UUID], onFinished: (() -> Void)? = nil) {
        self.environment = environment
        var seen = Set<UUID>()
        self.viewerIDs = viewerIDs.filter { seen.insert($0).inserted }
        self.onFinished = onFinished
    }

    private var childID: UUID? { viewerIDs.indices.contains(childIndex) ? viewerIDs[childIndex] : nil }
    private var childName: String {
        environment.snapshot?.profiles.first { $0.id == childID }?.displayName ?? "孩子"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("答题闯关").font(.largeTitle.bold())
                Text("\(childName) · 第 \(childIndex + 1) / \(viewerIDs.count) 位").font(.title3)
                if let outcome {
                    outcomeView(outcome)
                } else if let round, index < round.questions.count {
                    questionView(round.questions[index])
                } else if round != nil {
                    Text(submitting ? "正在提交，请稍候…" : message).font(.title2)
                    if !submitting {
                        Button("重试提交（保留本轮答案）") { submit() }
                        Button("返回") { finish() }
                    }
                } else {
                    Text(message).font(.title2).multilineTextAlignment(.center)
                        .accessibilityIdentifier("quiz-preparation-message")
                    if !preparing {
                        Button("重试加载") { Task { await prepare() } }
                            .accessibilityIdentifier("quiz-retry-load")
                        Button("返回") { finish() }
                            .accessibilityIdentifier("quiz-return")
                    }
                }
                Text("通用题库为 AI核对+结构校验，非教师/出版社审定，未逐教材匹配。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(70)
            .frame(maxWidth: .infinity)
        }
        .task(id: childIndex) { await prepare() }
        .onExitCommand { finish() }
    }

    private func questionView(_ question: QuizQuestion) -> some View {
        VStack(spacing: 26) {
            Text("第 \(index + 1) / \(round?.questions.count ?? 0) 题 · \(question.subject)")
                .font(.title3).foregroundStyle(.secondary)
            Text(question.prompt).font(.title2).multilineTextAlignment(.center)
                .accessibilityIdentifier("quiz-question-\(question.id)")
            VStack(spacing: 18) {
                ForEach(question.options) { option in
                    Button(option.text) { choose(question.id, option.id) }
                        .accessibilityIdentifier("quiz-option-\(option.id)")
                        .focused($focusedOption, equals: option.id)
                        .prefersDefaultFocus(option.id == question.options.first?.id, in: optionFocus)
                        .frame(maxWidth: 760)
                        .disabled(submitting)
                }
            }
            .focusScope(optionFocus)
            .id(question.id)
            .task(id: question.id) {
                focusedOption = nil
                try? await Task.sleep(nanoseconds: 150_000_000)
                focusedOption = question.options.first?.id
            }
            Text("提交后可查看每题答案与解析。").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func rewardMessage(_ result: QuizOutcome) -> String {
        if result.rewardMinutes > 0 { return "已记账观看奖励：\(result.rewardMinutes / 60_000) 分钟" }
        guard result.passed else { return "本轮未通过，未获得观看奖励。" }
        let reason: String
        switch result.rewardDeniedReason {
        case "personal-daily-cap": reason = "个人今日奖励次数已用完。"
        case "family-daily-cap": reason = "家庭今日奖励次数已用完。"
        case "family-daily-duration-cap": reason = "家庭今日奖励时长已达上限。"
        case "family-absolute-total-cap": reason = "家庭今日总额度已达上限。"
        case "recovery-quarantine": reason = "备份恢复余额仍在隔离中。"
        case .some: reason = "本轮未增加观看奖励。"
        case .none: reason = "账本记录本轮奖励为 0。"
        }
        return "本轮已通过，\(reason)通过不要求获得奖励；原有可用额度仍可使用，播放仍需满足休息和观看时段等家庭规则。"
    }

    private func outcomeView(_ result: QuizOutcome) -> some View {
        VStack(spacing: 22) {
            Text(result.passed ? "本轮通过" : "本轮未通过，再接再厉。")
                .font(.title.bold())
                .accessibilityIdentifier("quiz-outcome")
            Text("正确 \(result.correctCount) / \(result.total)")
            Text(rewardMessage(result))
                .foregroundStyle(result.rewardMinutes > 0 ? Color.green : Color.secondary)
                .accessibilityIdentifier("quiz-reward")
            if result.passed {
                if childIndex + 1 < viewerIDs.count {
                    Text("还有 \(viewerIDs.count - childIndex - 1) 位孩子需要完成自己的答题。")
                    Button("下一位孩子") {
                        guard !submitting, !finished else { return }
                        resetRound()
                        childIndex += 1
                    }
                    .disabled(submitting)
                    .accessibilityIdentifier("quiz-next-viewer")
                } else {
                    Text("本次安排的每位孩子均已通过；能否播放仍以当前家庭规则为准。")
                    Button("完成") { finish(passed: true) }
                        .disabled(submitting)
                        .accessibilityIdentifier("quiz-complete")
                        .focused($focusedFinish)
                        .task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            focusedFinish = true
                        }
                }
            } else {
                Button("再试一轮") {
                    guard !submitting, !finished else { return }
                    resetRound()
                    Task { await prepare() }
                }
                .disabled(submitting)
                .accessibilityIdentifier("quiz-retry-round")
                Button("返回（未通过）") { finish() }
                    .accessibilityIdentifier("quiz-return")
            }
            Text("每题答案与解析").font(.title2)
            // Validated unique IDs; one report row per question, including correct
            // questions in a passing round (not just failed-round wrong answers).
            if let round {
                ForEach(round.questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(answers[question.id] == question.answerID ? "答对" : "错题")：\(question.prompt)")
                            .font(.headline)
                        Text("你的答案：\(optionText(answers[question.id], question))")
                        Text("正确答案：\(optionText(question.answerID, question))")
                        Text(question.explanation).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(20)
                    .focusable()
                }
            }
        }
    }

    private func optionText(_ id: String?, _ question: QuizQuestion) -> String {
        question.options.first { $0.id == id }?.text ?? "未作答"
    }

    @MainActor private func prepare() async {
        guard !preparing, round == nil, outcome == nil, !finished else { return }
        preparing = true
        message = "正在准备题目…"
        defer { preparing = false }
        do {
            guard let ledger = environment.ledger else { throw LedgerError.closed }
            let snapshot = try await ledger.snapshot()
            guard !finished, !Task.isCancelled else { return }
            guard let childID, let profile = snapshot.profiles.first(where: { $0.id == childID && $0.isEnabled }) else {
                throw LedgerError.invalidInput("没有可答题的孩子，或孩子已停用")
            }
            guard let rules = snapshot.configuration.quizRules else { throw LedgerError.invalidInput("答题规则尚未启用") }
            let bank = try FamilyQuestionBank.load()
            let questions = try bank.makeRound(for: profile, perRound: rules.questionsPerRound)
            let issued = try await ledger.startQuizRound(childID: childID, questions: questions)
            guard !finished, !Task.isCancelled else { return }
            round = issued
        } catch {
            guard !finished, !Task.isCancelled else { return }
            if let failure = error as? FamilyQuestionBank.Failure {
                message = "当前课程暂时无法出题：\(failure.message)\n请家长检查课程配置或题库。不会改用其他年级或教材版本，也不会自动修改答题规则；可选择返回。"
            } else if case LedgerError.invalidInput(let reason) = error {
                message = "无法开始答题：\(reason)\n请家长检查设置；可选择返回。"
            } else if let ledgerError = error as? LedgerError, ledgerError == .resting {
                message = "现在需要先休息，暂时不能答题。可返回视频列表，休息结束后再来。"
            } else if let ledgerError = error as? LedgerError, ledgerError == .clockUntrusted {
                message = "设备时间需要家长确认，暂时不能答题。可选择返回。"
            } else {
                message = "家庭记录或题目暂时无法读取，请稍后重试或返回。"
            }
        }
    }

    private func choose(_ questionID: String, _ optionID: String) {
        guard !finished, !submitting, let round, index < round.questions.count,
              round.questions[index].id == questionID, answers[questionID] == nil,
              round.questions[index].options.contains(where: { $0.id == optionID }) else { return }
        answers[questionID] = optionID
        index += 1
        if index == round.questions.count { submit() }
    }

    private func submit() {
        guard !finished, !submitting, outcome == nil, let round, answers.count == round.questions.count else { return }
        submitting = true
        Task { @MainActor in
            defer { submitting = false }
            do {
                guard let ledger = environment.ledger else { throw LedgerError.closed }
                let result = try await ledger.submitQuizRound(id: round.id, childID: round.childID, answers: answers)
                guard !finished, !Task.isCancelled else { return }
                let correct = round.questions.filter { answers[$0.id] == $0.answerID }.count
                // Fail visibly rather than render a success/reward for inconsistent
                // results. Reward text is based on the actual persisted outcome only.
                guard result.attemptID == round.id, result.childID == round.childID,
                      result.total == round.questions.count, result.correctCount == correct,
                      result.rewardMinutes >= 0, result.passed || result.rewardMinutes == 0,
                      result.rewardMinutes == 0 || result.rewardDeniedReason == nil else {
                    throw LedgerError.invalidInput("账本结果与本轮不一致，不能确认成绩或奖励")
                }
                if result.passed { passedViewerIDs.insert(result.childID) }
                outcome = result
                await environment.refresh()
            } catch {
                guard !finished, !Task.isCancelled else { return }
                message = "提交未确认，可重试；不会另建答题轮次。\n\(Self.submitFailureText(error))"
            }
        }
    }

    private static func submitFailureText(_ error: Error) -> String {
        switch error {
        case LedgerError.invalidInput(let reason):
            return reason
        case LedgerError.resting:
            return "现在需要先休息，暂时不能提交。"
        case LedgerError.clockUntrusted:
            return "设备时间需要家长确认，暂时不能提交。"
        case ParentalAuthError.authorizationExpired, ParentalAuthError.invalidAuthorization:
            return "家长授权已结束，请让家长重新验证后再试。"
        case LedgerError.closed, LedgerError.database, LedgerError.corruptDatabase:
            return "家庭记录暂时无法读取，请稍后重试。"
        default:
            return "家庭记录暂时无法确认，请稍后重试。"
        }
    }

    private func resetRound() {
        round = nil; answers = [:]; outcome = nil; index = 0
        message = "正在准备题目…"
    }

    private func finish(passed: Bool = false) {
        guard !finished else { return }
        // Cancelling even during a pending submission never resumes playback.
        // Persisted late results remain in the ledger, not a UI authorization.
        let allPassed = passed && !submitting && !viewerIDs.isEmpty
            && outcome?.passed == true && Set(viewerIDs).isSubset(of: passedViewerIDs)
        if passed && !allPassed { return }
        finished = true
        if let dismissPresented {
            dismissPresented(allPassed)
        } else {
            dismiss()
            if allPassed { onPassed?() }
            onFinished?()
        }
    }
}
