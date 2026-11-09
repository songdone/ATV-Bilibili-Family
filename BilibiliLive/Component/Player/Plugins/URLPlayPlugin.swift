//
//  URLPlayPlugin.swift
//  BilibiliLive
//

import AVKit
import Foundation

class URLPlayPlugin: NSObject {
    var onPlayFail: (() -> Void)?

    private weak var playerVC: AVPlayerViewController?
    private let referer: String
    private let isLive: Bool
    private var currentUrl: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private let modeGeneration = FamilyPlayer.onMain { PlaybackCoordinator.shared.modeGeneration }
    private let childMode = FamilyModeState.childActive
    private var closed = false

    init(referer: String = "", isLive: Bool = false) {
        self.referer = referer
        self.isLive = isLive
    }

    func play(urlString: String) {
        FamilyPlayer.onMain { startLoad(urlString: urlString) }
    }

    @MainActor
    private func startLoad(urlString: String) {
        guard !closed, PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: childMode) else { return }
        currentUrl = urlString
        loadTask?.cancel()
        generation += 1
        guard let owner = playerVC else { return }
        // Child mode rejects live before any load: its failure/source retry graph is
        // not child-safe yet. Adult mode keeps the original live behavior.
        if isLive, FamilyModeState.childActive {
            PlaybackCoordinator.shared.deny(.live, owner: owner)
            return
        }
        guard let url = URL(string: urlString),
              let ticket = PlaybackCoordinator.shared.beginLoading(owner: owner) else { return }
        let expected = generation
        loadTask = Task { @MainActor [weak self, weak owner] in
            guard let self, let owner, !Task.isCancelled,
                  self.generation == expected, PlaybackCoordinator.shared.isLoading(ticket, owner: owner) else { return }
            let headers = ["User-Agent": Keys.userAgent, "Referer": self.referer]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            guard let player = await PlaybackCoordinator.shared.makePlayer(item: item, owner: owner, ticket: ticket) else { return }
            guard !Task.isCancelled, self.generation == expected, self.playerVC === owner,
                  PlaybackCoordinator.shared.isLoading(ticket, owner: owner) else {
                PlaybackCoordinator.shared.stop(player: player)
                return
            }
            player.automaticallyWaitsToMinimizeStalling = !self.isLive
            owner.player = player
        }
    }
}

extension URLPlayPlugin: CommonPlayerPlugin {
    func playerDidLoad(playerVC: AVPlayerViewController) {
        guard FamilyPlayer.onMain({ !closed && PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: childMode) }) else { return }
        self.playerVC = playerVC
        playerVC.requiresLinearPlayback = isLive
        if isLive, FamilyModeState.childActive {
            FamilyPlayer.onMain { PlaybackCoordinator.shared.deny(.live, owner: playerVC) }
            return
        }
        playerVC.player = nil
        if let currentUrl { play(urlString: currentUrl) }
    }

    func playerDidFail(player: AVPlayer) {
        guard !isLive || !FamilyModeState.childActive else { return }
        FamilyPlayer.onMain {
            guard !closed, let owner = playerVC, owner.player === player,
                  PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: childMode),
                  PlaybackCoordinator.shared.permitsPlayback(player, owner: owner) else { return }
            onPlayFail?()
        }
    }

    func playerDidPause(player: AVPlayer) {
        // Restore upstream live source retry, but never retry a policy/teardown pause.
        if isLive, !FamilyModeState.childActive { playerDidFail(player: player) }
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        closed = true
        onPlayFail = nil
        currentUrl = nil
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        self.playerVC = nil
    }

    func playerDidCleanUp(player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
