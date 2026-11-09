#if DEBUG && targetEnvironment(simulator)
import AVKit
import FamilyCore
import UIKit

/// Uses the real clock, Keychain, SQLite and player gate in an isolated store.
/// The second launch must reuse the first launch's household and billed usage.
final class FamilyClockPlaybackProbeController: UIViewController {
    private let result = UILabel()
    private var started = false
    private let environment = FamilyEnvironment.shared
    private var owner: AVPlayerViewController?
    private var container: CommonPlayerViewController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task {
            while UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await run()
        }
    }

    private func run() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("--family-preview"),
                  let storeIndex = args.firstIndex(of: "--family-test-store"), storeIndex + 1 < args.count,
                  UUID(uuidString: args[storeIndex + 1]) != nil,
                  let mediaIndex = args.firstIndex(of: "--family-probe-media"), mediaIndex + 1 < args.count,
                  FileManager.default.fileExists(atPath: args[mediaIndex + 1]) else {
                throw LedgerError.invalidInput("isolated clock probe arguments")
            }
            let existing = args.contains("--family-clock-existing")
            await environment.start()
            guard let ledger = environment.ledger else { throw LedgerError.closed }
            if existing {
                guard case .configured = try await environment.auth.status() else {
                    throw LedgerError.invalidInput("relaunch lost the PIN record")
                }
            } else {
                try await environment.auth.setup(pin: "647291")
                let rules = try await environment.auth.authenticate(pin: "647291", context: .configureRules)
                try await ledger.configureFamily(FamilyConfiguration(dailyLimitMilliseconds: 60_000,
                    continuousLimitMilliseconds: 60_000, restMilliseconds: 10_000), credential: rules.credential)
                let token = try await environment.auth.authenticate(pin: "647291", context: .manageProfiles)
                let child = ViewerProfile(displayName: "Clock playback fixture",
                    curriculum: CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
                        academicYear: "2026-2027", semester: "全年"), dailyLimitMilliseconds: 60_000)
                try await ledger.upsertProfile(child, credential: token.credential)
            }
            let before = try await ledger.snapshot()
            guard before.clockIsTrusted, before.profiles.count == 1, before.activeViewerIDs.count == 1,
                  before.configuration.dailyLimitMilliseconds == 60_000, before.activeLease == nil,
                  before.familyFrozenMilliseconds == 0 else {
                throw LedgerError.invalidInput("clock or preserved household failed before playback")
            }
            if existing, before.familyActualMilliseconds == 0 {
                throw LedgerError.invalidInput("relaunch lost recorded playback")
            }
            let url = URL(fileURLWithPath: args[mediaIndex + 1])
            try await playAndSettle(url: url)
            let first = try await ledger.snapshot()
            guard first.familyActualMilliseconds > before.familyActualMilliseconds,
                  first.activeLease == nil else {
                throw LedgerError.invalidInput("actual playback was not billed")
            }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let paused = try await ledger.snapshot()
            guard paused.familyActualMilliseconds == first.familyActualMilliseconds else {
                throw LedgerError.invalidInput("paused or stopped player accrued usage")
            }
            try await playAndSettle(url: url)
            let after = try await ledger.snapshot()
            guard after.clockIsTrusted, after.familyActualMilliseconds > first.familyActualMilliseconds,
                  after.familyFrozenMilliseconds == 0, after.activeLease == nil,
                  after.profiles == before.profiles, after.configuration == before.configuration,
                  after.personalActualMilliseconds.values.allSatisfy({ $0 == after.familyActualMilliseconds }) else {
                throw LedgerError.invalidInput("settlement or preserved household failed")
            }
            let data: [String: Any] = ["phase": existing ? "relaunch" : "first",
                "before": before.familyActualMilliseconds, "after": after.familyActualMilliseconds,
                "pausedDelta": paused.familyActualMilliseconds - first.familyActualMilliseconds,
                "clockTrusted": after.clockIsTrusted, "frozen": after.familyFrozenMilliseconds]
            let encoded = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
            show("CLOCK PLAYBACK PASSED " + String(decoding: encoded, as: UTF8.self))
        } catch {
            show("CLOCK PLAYBACK FAILED \(error)")
        }
    }

    private func playAndSettle(url: URL) async throws {
        let playerContainer = CommonPlayerViewController()
        addChild(playerContainer)
        view.addSubview(playerContainer.view)
        playerContainer.view.frame = view.bounds
        playerContainer.didMove(toParent: self)
        container = playerContainer
        guard let playerOwner = playerContainer.children.compactMap({ $0 as? AVPlayerViewController }).first else {
            throw LedgerError.invalidInput("AVKit container missing")
        }
        owner = playerOwner
        guard let ticket = PlaybackCoordinator.shared.beginLoading(owner: playerOwner) else {
            throw LedgerError.invalidInput("beginLoading rejected: current=\(playerContainer.canLoadFamilyPlayback), active=\(UIApplication.shared.applicationState == .active), child=\(FamilyModeState.childActive)")
        }
        guard let player = await PlaybackCoordinator.shared.makePlayer(item: AVPlayerItem(url: url),
            owner: playerOwner, ticket: ticket) else {
            let state = try await environment.ledger?.snapshot()
            throw LedgerError.invalidInput("makePlayer rejected: trusted=\(state?.clockIsTrusted == true), reason=\(String(describing: state?.clockRecoveryReason)), frozen=\(state?.familyFrozenMilliseconds ?? -1)")
        }
        playerOwner.player = player
        player.play()
        for _ in 0..<80 {
            if player.timeControlStatus == .playing { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard player.timeControlStatus == .playing else {
            PlaybackCoordinator.shared.stop(player: player)
            throw LedgerError.invalidInput("AVPlayer did not start")
        }
        try await Task.sleep(nanoseconds: 1_400_000_000)
        player.pause()
        try await Task.sleep(nanoseconds: 250_000_000)
        PlaybackCoordinator.shared.stop(player: player)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        guard let ledger = environment.ledger else { throw LedgerError.closed }
        let settled = try await ledger.snapshot()
        PlaybackCoordinator.shared.stop(player: player)
        await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
        let duplicate = try await ledger.snapshot()
        guard duplicate.familyActualMilliseconds == settled.familyActualMilliseconds else {
            throw LedgerError.invalidInput("duplicate stop billed twice")
        }
        playerOwner.player = nil
        playerContainer.willMove(toParent: nil)
        playerContainer.view.removeFromSuperview()
        playerContainer.removeFromParent()
        owner = nil
        container = nil
    }

    private func show(_ text: String) {
        result.text = text
        result.accessibilityIdentifier = "family-clock-playback-result"
        result.textColor = .white
        result.backgroundColor = .black
        result.numberOfLines = 0
        result.frame = CGRect(x: 60, y: 80, width: 1600, height: 300)
        (view.window ?? view).addSubview(result)
    }
}
#endif
