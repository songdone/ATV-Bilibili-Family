//
//  BUpnpPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit

/// Adult-only upstream transport. A remote command must belong to the current
/// player/context, not just observe that the device happens to be adult again.
class BUpnpPlugin: NSObject, CommonPlayerPlugin {
    let duration: Int?
    weak var player: AVPlayer?
    private weak var playerVC: AVPlayerViewController?
    private var observar: Any?
    private let modeGeneration = FamilyPlayer.onMain { PlaybackCoordinator.shared.modeGeneration }

    init(duration: Int?) { self.duration = duration }

    @MainActor private var isActive: Bool {
        guard let player, let playerVC else { return false }
        return PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: false)
            && (playerVC.parent as? CommonPlayerViewController)?.isPlaybackContextCurrent == true
            && playerVC.player === player
    }

    func playerDidLoad(playerVC: AVPlayerViewController) { self.playerVC = playerVC }

    func pause() { FamilyPlayer.onMain { if isActive { player?.pause() } } }
    func resume() { FamilyPlayer.onMain { if isActive { player?.play() } } }
    func seek(to time: TimeInterval) {
        FamilyPlayer.onMain {
            guard isActive, time.isFinite else { return }
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func playerWillStart(player: AVPlayer) {
        FamilyPlayer.onMain {
            self.player = player
            guard isActive else { return }
            BiliBiliUpnpDMR.shared.currentPlugin = self
            guard let duration, observar == nil else { return }
            observar = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self, weak player] time in
                FamilyPlayer.onMain {
                    guard let self, self.isActive, self.player === player, time.seconds.isFinite else { return }
                    BiliBiliUpnpDMR.shared.sendProgress(duration: duration, current: Int(time.seconds))
                }
            }
        }
    }

    private func send(_ status: BiliBiliUpnpDMR.PlayStatus, player: AVPlayer) {
        FamilyPlayer.onMain {
            guard isActive, self.player === player else { return }
            BiliBiliUpnpDMR.shared.sendStatus(status: status)
        }
    }

    func playerDidStart(player: AVPlayer) { send(.playing, player: player) }
    func playerDidPause(player: AVPlayer) { send(.paused, player: player) }
    func playerDidEnd(player: AVPlayer) { send(.end, player: player) }
    func playerDidFail(player: AVPlayer) { send(.stop, player: player) }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        if let player { playerDidCleanUp(player: player) }
        self.playerVC = nil
    }

    func playerDidCleanUp(player: AVPlayer) {
        FamilyPlayer.onMain {
            guard self.player === player else { return }
            if let observar { player.removeTimeObserver(observar) }
            observar = nil
            if BiliBiliUpnpDMR.shared.currentPlugin === self {
                send(.stop, player: player)
                BiliBiliUpnpDMR.shared.currentPlugin = nil
            }
            self.player = nil
        }
    }
}
