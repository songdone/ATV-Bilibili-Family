#if DEBUG && targetEnvironment(simulator)
import AVKit
import FamilyCore
import UIKit

/// Launches a fresh container so the production clock-recovery presentation and
/// retry path run unchanged against a deliberately old, isolated test ledger.
final class FamilyClockRecoveryProbeHost: UIViewController {
    private var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { @MainActor in
            while UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--family-preview"),
                  let storeIndex = arguments.firstIndex(of: "--family-test-store"), storeIndex + 1 < arguments.count,
                  UUID(uuidString: arguments[storeIndex + 1]) != nil,
                  let mediaIndex = arguments.firstIndex(of: "--family-probe-media"), mediaIndex + 1 < arguments.count else { return }
            await FamilyEnvironment.shared.start()
            if arguments.contains("--family-probe-quiz-resume") || arguments.contains("--family-probe-rest-status") || arguments.contains("--family-probe-schedule-status") {
                do {
                    let environment = FamilyEnvironment.shared
                    guard let ledger = environment.ledger else { throw LedgerError.closed }
                    try await environment.auth.setup(pin: "647291")
                    let rules = try await environment.auth.authenticate(pin: "647291", context: .configureRules)
                    let restProbe = arguments.contains("--family-probe-rest-status")
                    let scheduleProbe = arguments.contains("--family-probe-schedule-status")
                    var config = FamilyConfiguration(dailyLimitMilliseconds: 60_000,
                        continuousLimitMilliseconds: restProbe ? 4_000 : 60_000,
                        restMilliseconds: restProbe ? 20_000 : 8_000)
                    if arguments.contains("--family-probe-quiz-resume") {
                        config.quizRules = QuizRules(questionsPerRound: 5, passRatio: 0.6, rewardMinutes: 10,
                            personalDailyRewards: 3, familyDailyRewards: 6,
                            quizBeforeFirstWatch: true, quizAfterRest: false)
                    }
                    if scheduleProbe {
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = TimeZone(identifier: config.timeZoneIdentifier)!
                        let minute = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
                        let start = (minute + 60) % 1440
                        let window = DailyScheduleWindow(startMinuteOfDay: start, endMinuteOfDay: min(start + 30, 1440))
                        config.schedule = FamilySchedule(weekday: window, weekend: window)
                    }
                    try await ledger.configureFamily(config, credential: rules.credential)
                    let token = try await environment.auth.authenticate(pin: "647291", context: .manageProfiles)
                    let child = ViewerProfile(displayName: "Quiz resume fixture",
                        curriculum: CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
                            academicYear: "2026-2027", semester: "全年", subjects: ["数学"],
                            subjectTextbookVersions: ["数学": "general_knowledge"], learnedChapters: ["数学": ["*"]]),
                        dailyLimitMilliseconds: 60_000)
                    try await ledger.upsertProfile(child, credential: token.credential)
                } catch {
                    let failure = UILabel()
                    failure.text = "QUIZ SETUP FAILED \(error)"
                    failure.accessibilityIdentifier = "family-quiz-resume-failure"
                    failure.frame = CGRect(x: 60, y: 80, width: 1600, height: 100)
                    view.addSubview(failure)
                    return
                }
            }
            let player = FamilyClockRecoveryProbePlayer(url: URL(fileURLWithPath: arguments[mediaIndex + 1]))
            present(player, animated: false)
        }
    }
}

private final class FamilyClockRecoveryProbePlayer: CommonPlayerViewController {
    private let mediaURL: URL
    private let resumed: Bool
    private var started = false
    private var measured = false
    private let evidence = UILabel()

    init(url: URL, resumed: Bool = false) {
        mediaURL = url
        self.resumed = resumed
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var supportsFamilyClockRetry: Bool { true }
    override func makeFamilyClockRetryPlayer() -> CommonPlayerViewController? {
        FamilyClockRecoveryProbePlayer(url: mediaURL, resumed: true)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let plugin = URLPlayPlugin()
        addPlugin(plugin: plugin)
        plugin.play(urlString: mediaURL.absoluteString)
    }
    override func playerDidStart(player: AVPlayer) {
        if ProcessInfo.processInfo.arguments.contains("--family-probe-rest-status"), !resumed { return }
        guard !measured else { return }
        measured = true
        Task { @MainActor in
            do {
                guard let ledger = FamilyEnvironment.shared.ledger else { throw LedgerError.closed }
                let before = try await ledger.snapshot()
                try await Task.sleep(nanoseconds: 1_500_000_000)
                player.pause()
                try await Task.sleep(nanoseconds: 250_000_000)
                PlaybackCoordinator.shared.stop(player: player)
                await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
                let after = try await ledger.snapshot()
                guard after.clockIsTrusted, after.familyActualMilliseconds > before.familyActualMilliseconds,
                      after.profiles == before.profiles, after.configuration == before.configuration else {
                    throw LedgerError.invalidInput("retry did not bill real playback")
                }
                show("CLOCK RECOVERY PLAYED before=\(before.familyActualMilliseconds) after=\(after.familyActualMilliseconds)")
            } catch { show("CLOCK RECOVERY FAILED \(error)") }
        }
    }
    private func show(_ text: String) {
        evidence.text = text
        evidence.accessibilityIdentifier = "family-clock-recovery-played"
        evidence.textColor = .white
        evidence.backgroundColor = .black
        evidence.numberOfLines = 0
        evidence.frame = CGRect(x: 60, y: 80, width: 1600, height: 200)
        (view.window ?? view).addSubview(evidence)
    }
}
#endif
