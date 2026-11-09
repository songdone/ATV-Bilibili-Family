#if DEBUG && targetEnvironment(simulator)
import AVKit
import FamilyCore

final class FamilyAdultProbeController: CommonPlayerViewController {
    private var started = false
    private var checked = false
    private let resultLabel = UILabel()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { @MainActor in
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(nanoseconds: 100_000_000) }
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--family-probe-media"), index + 1 < args.count,
                  !FamilyModeState.childActive else { result("ADULT FAILED configuration"); return }
            let plugin = URLPlayPlugin()
            addPlugin(plugin: plugin)
            plugin.play(urlString: URL(fileURLWithPath: args[index + 1]).absoluteString)
        }
    }

    override func playerDidStart(player: AVPlayer) {
        guard !checked else { return }
        checked = true
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let environment = FamilyEnvironment.shared
                await environment.start()
                let pipAllowed = children.compactMap({ $0 as? AVPlayerViewController }).first?.allowsPictureInPicturePlayback == true
                guard let ledger = environment.ledger, !(player is FamilyPlayer), player.rate > 0, pipAllowed else {
                    throw LedgerError.invalidInput("adult blocked: ledger=\(environment.ledger != nil) controlled=\(player is FamilyPlayer) rate=\(player.rate) pip=\(pipAllowed) external=\(player.allowsExternalPlayback)")
                }
                // Preserve the system's AVPlayer default; route support varies by
                // simulator/device. A plain player must accept an explicit setting.
                player.allowsExternalPlayback = true
                guard player.allowsExternalPlayback else { throw LedgerError.invalidInput("adult external setting rejected") }
                let before = try await ledger.snapshot()
                guard before.familyActualMilliseconds == 0, before.activeLease == nil else {
                    throw LedgerError.invalidInput("adult playback charged child ledger")
                }
                try await environment.auth.setup(pin: "647291")
                let token = try await environment.auth.authenticate(pin: "647291", context: .manageProfiles)
                let profile = ViewerProfile(displayName: "Synthetic mode switch", curriculum:
                    CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4,
                        academicYear: "2026-2027", semester: "全年"), dailyLimitMilliseconds: 60_000)
                try await ledger.upsertProfile(profile, credential: token.credential)
                let viewers = try await environment.auth.authenticate(pin: "647291", context: .manageSession)
                try await ledger.selectViewers([profile.id], credential: viewers.credential)
                let mode = try await environment.auth.authenticate(pin: "647291", context: .temporaryOverride)
                try await environment.setChildMode(true, authorization: mode)
                player.play() // An old adult player has had its item removed and cannot revive.
                try await Task.sleep(nanoseconds: 300_000_000)
                let after = try await ledger.snapshot()
                guard FamilyModeState.childActive, player.currentItem == nil, player.timeControlStatus != .playing,
                      after.familyActualMilliseconds == 0 else {
                    throw LedgerError.invalidInput("mode revoke: child=\(FamilyModeState.childActive) itemNil=\(player.currentItem == nil) status=\(player.timeControlStatus.rawValue) usage=\(after.familyActualMilliseconds)")
                }
                result("ADULT VERIFIED originalPlayer=true pip=true external=true uncharged=true modeRevoked=true")
            } catch { result("ADULT FAILED \(error)") }
        }
    }

    private func result(_ text: String) {
        resultLabel.text = text
        resultLabel.accessibilityIdentifier = "family-adult-probe-result"
        resultLabel.font = .systemFont(ofSize: 30)
        resultLabel.textColor = .white; resultLabel.backgroundColor = .black
        resultLabel.numberOfLines = 0
        resultLabel.frame = CGRect(x: 60, y: 80, width: 1600, height: 200)
        (view.window ?? view).addSubview(resultLabel)
    }
}
#endif
