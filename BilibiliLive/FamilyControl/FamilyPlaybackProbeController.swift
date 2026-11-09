#if DEBUG && targetEnvironment(simulator)
import AVKit
import FamilyCore
import UIKit

/// Simulator-only integration probe. Uses the real Keychain, SQLite and player
/// gate in an explicitly isolated test namespace; it never changes a household.
final class FamilyPlaybackProbeController: CommonPlayerViewController {
    private var didSchedulePause = false
    private var resultObserver: NSObjectProtocol?
    private var probePlayer: AVPlayer?
    private var pausedUsage: Int64?
    private var failure: String?
    private let resultLabel = UILabel()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard resultObserver == nil else { return }
        resultObserver = NotificationCenter.default.addObserver(forName: PlaybackCoordinator.deniedNotification,
            object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    let reason = note.userInfo?["reason"] as? String
                    if reason != "quota" && reason != "resting" { self?.failure = reason }
                    await self?.finish()
                }
            }
        Task {
            while UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await prepareProbe()
        }
    }

    private func prepareProbe() async {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--family-preview"),
                  let storeIndex = arguments.firstIndex(of: "--family-test-store"), storeIndex + 1 < arguments.count,
                  UUID(uuidString: arguments[storeIndex + 1]) != nil else {
                throw LedgerError.invalidInput("probe arguments")
            }
            // Media is only required for the playback probe, not the quiz-gate probe.
            let mediaIndex = arguments.firstIndex(of: "--family-probe-media")
            let mediaPath = mediaIndex.flatMap {
                $0 + 1 < arguments.count && FileManager.default.fileExists(atPath: arguments[$0 + 1])
                    ? arguments[$0 + 1] : nil
            }
            let environment = FamilyEnvironment.shared
            await environment.start()
            guard let ledger = environment.ledger else { throw LedgerError.closed }
            try await environment.auth.setup(pin: "647291")
            let rules = try await environment.auth.authenticate(pin: "647291", context: .configureRules)
            try await ledger.configureFamily(FamilyConfiguration(dailyLimitMilliseconds: 60_000,
                continuousLimitMilliseconds: 12_000, restMilliseconds: 10_000), credential: rules.credential)
            let profileToken = try await environment.auth.authenticate(pin: "647291", context: .manageProfiles)
            let child = ViewerProfile(displayName: "Synthetic playback probe",
                curriculum: CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
                    academicYear: "2026-2027", semester: "全年", subjects: ["数学"],
                    subjectTextbookVersions: ["数学": "general_knowledge"], learnedChapters: ["数学": ["*"]]),
                dailyLimitMilliseconds: 60_000)
            try await ledger.upsertProfile(child, credential: profileToken.credential)
            let session = try await environment.auth.authenticate(pin: "647291", context: .manageSession)
            try await ledger.selectViewers([child.id], credential: session.credential)
            // Quiz-gate probe: enable first-watch quiz, expect the gate denial,
            // then open the real quiz screen backed by the bundled 80-question bank.
            if arguments.contains("--family-probe-quiz") {
                let rulesToken = try await environment.auth.authenticate(pin: "647291", context: .configureRules)
                try await ledger.configureFamily(FamilyConfiguration(dailyLimitMilliseconds: 60_000,
                    continuousLimitMilliseconds: 12_000, restMilliseconds: 10_000,
                    quizRules: QuizRules(questionsPerRound: 5, passRatio: 0.6, rewardMinutes: 10,
                        personalDailyRewards: 3, familyDailyRewards: 6,
                        quizBeforeFirstWatch: true, quizAfterRest: true)), credential: rulesToken.credential)
                do {
                    _ = try await ledger.reservePlayback(eventID: "gated-\(UUID().uuidString)",
                        requestedMilliseconds: 5_000)
                    showResult("PROBE FAILED: gate did not deny")
                    return
                } catch let error as LedgerError where error == .quizRequired {
                    // Verified by the ledger; keep the test overlay out of the quiz UI.
                }
                await environment.refresh()
                guard let viewer = FamilyEnvironment.shared.snapshot?.activeViewerIDs.first else {
                    showResult("PROBE FAILED: no viewer"); return
                }
                present(FamilyQuizViewController(environment: FamilyEnvironment.shared, childID: viewer) { [weak self] in
                    Task { @MainActor in await self?.verifyQuizReward(childID: viewer) }
                }, animated: true)
                return
            }
            guard let mediaPath else {
                showResult("PROBE FAILED: probe media missing"); return
            }
            let plugin = URLPlayPlugin()
            addPlugin(plugin: plugin)
            plugin.play(urlString: URL(fileURLWithPath: mediaPath).absoluteString)
        } catch { showResult("PROBE FAILED: \(error)") }
    }

    private func verifyQuizReward(childID: UUID) async {
        do {
            let environment = FamilyEnvironment.shared
            guard let ledger = environment.ledger else { throw LedgerError.closed }
            let token = try await environment.auth.authenticate(pin: "647291", context: .configureRules)
            let report = try await ledger.report(lastDays: 1, childID: childID, credential: token.credential)
            guard report.quizAttempts.count == 1, let attempt = report.quizAttempts.first,
                  attempt.passed, attempt.rewardedMinutes == 600_000 else {
                throw LedgerError.invalidInput("expected one successful credited attempt")
            }
            let state = try await ledger.snapshot()
            guard state.familyQuizRewardMilliseconds == 600_000,
                  state.familyActualMilliseconds == 0 else {
                throw LedgerError.invalidInput("quiz reward missing or charged as viewing")
            }
            let lease = try await ledger.reservePlayback(eventID: UUID().uuidString, requestedMilliseconds: 1_000)
            _ = try await ledger.settlePlayback(leaseID: lease.id)
            showResult("QUIZ VERIFIED correct=\(attempt.correct)/\(attempt.total) reward=600000 playable=true")
        } catch { showResult("QUIZ FAILED: \(error)") }
    }

    override func playerDidStart(player: AVPlayer) {
        probePlayer = player
        guard !didSchedulePause else { return }
        didSchedulePause = true
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let player else { return }
            player.pause()
            // Let a complete lease renewal settle the pre-pause interval first.
            try? await Task.sleep(nanoseconds: 5_250_000_000)
            if let ledger = FamilyEnvironment.shared.ledger {
                self.pausedUsage = try? await ledger.snapshot().familyActualMilliseconds
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let ledger = FamilyEnvironment.shared.ledger,
               let snapshot = try? await ledger.snapshot(), let before = self.pausedUsage {
                if snapshot.familyActualMilliseconds != before {
                    self.failure = "paused usage grew unexpectedly"
                }
            }
            player.play()
        }
    }

    private func finish() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let ledger = FamilyEnvironment.shared.ledger, let state = try? await ledger.snapshot() else {
            showResult("PROBE FAILED: snapshot unavailable"); return
        }
        let actual = state.familyActualMilliseconds
        let stopped = probePlayer?.rate == 0 && probePlayer?.currentItem == nil
        if failure == nil, didSchedulePause, stopped, actual >= 10_000, actual <= 12_000,
           state.familyFrozenMilliseconds == 0, state.remainingRestMilliseconds > 0,
           state.personalActualMilliseconds.values.allSatisfy({ $0 == actual }) {
            showResult("PROBE PASSED actual=\(actual) rest=\(state.remainingRestMilliseconds)")
        } else {
            showResult("PROBE FAILED actual=\(actual) rest=\(state.remainingRestMilliseconds) frozen=\(state.familyFrozenMilliseconds) stopped=\(stopped) \(failure ?? "")")
        }
    }

    private func showResult(_ text: String) {
        resultLabel.text = text
        resultLabel.accessibilityIdentifier = "family-playback-probe-result"
        resultLabel.numberOfLines = 0
        resultLabel.textColor = .white
        resultLabel.backgroundColor = .black
        resultLabel.font = .systemFont(ofSize: 32)
        resultLabel.frame = CGRect(x: 60, y: 80, width: 1600, height: 160)
        // Policy denial may present an alert; expose evidence above that presentation.
        (view.window ?? view).addSubview(resultLabel)
    }

    deinit {
        if let resultObserver { NotificationCenter.default.removeObserver(resultObserver) }
    }
}
#endif
