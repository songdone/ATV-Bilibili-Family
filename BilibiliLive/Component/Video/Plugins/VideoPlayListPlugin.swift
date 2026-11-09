//
//  VideoPlayListPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/26.
//

import AVKit

class VideoPlayListPlugin: NSObject, CommonPlayerPlugin {
    private let nextActionIdentifierPrefix = "play.next"
    private weak var playerVC: AVPlayerViewController?
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration = UUID()
    private let modeGeneration = FamilyPlayer.onMain { PlaybackCoordinator.shared.modeGeneration }
    private let childMode = FamilyModeState.childActive
    @MainActor private var isActive: Bool {
        PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: childMode)
            && (playerVC?.parent as? CommonPlayerViewController)?.isPlaybackContextCurrent == true
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        navigationGeneration = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        FamilyPlayer.onMain { sequenceProvider?.invalidatePendingAdvances() }
        self.playerVC = nil
        onPlayEnd = nil
        onPlayNextWithInfo = nil
        onShowCurrentDetail = nil
    }
    var onPlayEnd: (() -> Void)?
    var onPlayNextWithInfo: ((PlayInfo) -> Void)?
    var onShowCurrentDetail: ((PlayInfo) -> Void)?

    let sequenceProvider: VideoSequenceProvider?

    init(sequenceProvider: VideoSequenceProvider?) {
        self.sequenceProvider = sequenceProvider
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerWillStart(player: AVPlayer) {
        guard let playerVC, let sequenceProvider else { return }
        let menuState = MainActor.assumeIsolated { () -> (PlayInfo?, PlayInfo?) in
            guard sequenceProvider.count > 0 else { return (nil, nil) }
            return (sequenceProvider.peekPrevious(), sequenceProvider.peekNext())
        }
        let next = menuState.1
        var actions = playerVC.infoViewActions.filter {
            !$0.identifier.rawValue.hasPrefix(nextActionIdentifierPrefix)
        }

        if let next {
            let nextAction = UIAction(title: "下一条",
                                      image: UIImage(systemName: "forward.end.fill"),
                                      identifier: .init(rawValue: "\(nextActionIdentifierPrefix).\(next.sequenceKey)"))
            { [weak self] _ in
                self?.navigationTask?.cancel()
                self?.navigationTask = Task { @MainActor [weak self] in
                    _ = await self?.playNext()
                }
            }
            actions.append(nextAction)
        }

        playerVC.infoViewActions = actions
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let loopImage = UIImage(systemName: "infinity")
        let loopAction = UIAction(title: "循环播放", image: loopImage, state: Settings.loopPlay ? .on : .off) {
            action in
            action.state = (action.state == .off) ? .on : .off
            Settings.loopPlay = action.state == .on
        }
        var actions = [UIMenuElement](arrayLiteral: loopAction)
        let currentInfo = sequenceProvider.map { provider in
            MainActor.assumeIsolated { provider.current() }
        } ?? nil
        if let currentInfo, let onShowCurrentDetail {
            let detailAction = UIAction(title: "查看详情", image: UIImage(systemName: "info.circle")) { _ in
                onShowCurrentDetail(currentInfo)
            }
            actions.append(detailAction)
        }

        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") })
        {
            var child = setting.children
            child.append(contentsOf: actions)
            if let index = current.firstIndex(of: setting) {
                current[index] = setting.replacingChildren(child)
            }
            return []
        }
        return actions
    }

    func playerDidEnd(player: AVPlayer) {
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self, weak player] in
            guard let self, !Task.isCancelled, self.isActive, let player, self.playerVC?.player === player else { return }
            let advanced = await playNext()
            guard !Task.isCancelled, isActive, playerVC?.player === player else { return }
            if !advanced {
                if Settings.loopPlay {
                    sequenceProvider?.reset()
                    let loopAdvanced = await playNext()
                    guard !Task.isCancelled, isActive, playerVC?.player === player else { return }
                    if !loopAdvanced {
                        player.currentItem?.seek(to: .zero, completionHandler: nil)
                        player.play()
                    }
                    return
                }
                onPlayEnd?()
            }
        }
    }

    @discardableResult
    @MainActor private func playNext() async -> Bool {
        let generation = navigationGeneration
        guard !Task.isCancelled, isActive else { return false }
        if let next = await sequenceProvider?.moveNext(isCurrent: { [weak self] in
            guard let self else { return false }
            return generation == self.navigationGeneration && self.isActive
        }) {
            guard generation == navigationGeneration, isActive, !Task.isCancelled else { return false }
            onPlayNextWithInfo?(next)
            return true
        }
        return false
    }
}
