//
//  CommonPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import FamilyCore
import UIKit

class CommonPlayerViewController: UIViewController {
    private let playerVC = AVPlayerViewController()
    private var activePlugins = [CommonPlayerPlugin]()
    private var observations = Set<NSKeyValueObservation>()
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playToEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var familyObservers = [NSObjectProtocol]()
    private var familyBlocked = false
    private var familyMessage: String?
    private var familyReason: String?
    private var hasShownFamilyMessage = false
    private var clockRecoverySession: ParentalSession?
    private var clockRecoveryGeneration = UUID()
    private var isAuthorizingClock = false
    private var clockRecoveryTask: Task<Void, Never>?
    private var childQuizGeneration = UUID()
    private var childQuizTask: Task<Void, Never>?
    private var isPresentingChildQuiz = false
    private var isReplacingAfterChildQuiz = false
    private var childGateGeneration = UUID()
    private var isReplacingAfterChildGate = false
    private var usesChildPlaybackStatus = false
    private let playbackModeGeneration = FamilyPlayer.onMain { PlaybackCoordinator.shared.modeGeneration }
    private let childPlaybackGeneration = FamilyPlayer.onMain { PlaybackCoordinator.shared.childPlaybackGeneration }
    private let playbackIsChild = FamilyModeState.childActive
    var isPlaybackContextCurrent: Bool {
        !familyBlocked && PlaybackCoordinator.shared.isModeCurrent(playbackModeGeneration, child: playbackIsChild)
            && (!playbackIsChild || childPlaybackGeneration == PlaybackCoordinator.shared.childPlaybackGeneration)
    }
    /// A retry must build a new source container. The revoked instance stays blocked.
    var supportsFamilyClockRetry: Bool { false }
    func makeFamilyClockRetryPlayer() -> CommonPlayerViewController? { nil }
    /// Generic gate-retry aliases retain existing source/probe overrides.
    var supportsFamilyGateRetry: Bool { supportsFamilyClockRetry }
    func makeFamilyGateRetryPlayer() -> CommonPlayerViewController? { makeFamilyClockRetryPlayer() }
    func familyPlaybackWasRevoked(at seconds: Int?) {}
    var canLoadFamilyPlayback: Bool {
        isPlaybackContextCurrent && (!playbackIsChild || showsPlaybackControls)
    }
    private var isEnd = false
    private var isRestoringFromPip = false
    /// 新 AVPlayerItem ready 后是否自动 play。换 CDN host 等场景可临时关掉，由调用方按用户暂停状态决定是否续播。
    var autoPlayWhenReady = true
    var showsPlaybackControls = true
    var allowsPictureInPicturePlayback = true

    deinit {
        familyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        FamilyPlayer.onMain {
            endClockRecoverySession()
            invalidateChildQuiz()
            cleanUpPlayerOnExit(force: true)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        // Adult mode restores upstream PiP; child mode keeps first-phase restriction.
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback && !FamilyModeState.childActive
        playerVC.delegate = self
        for name in [PlaybackCoordinator.deniedNotification, PlaybackCoordinator.stoppedNotification] {
            familyObservers.append(NotificationCenter.default.addObserver(forName: name, object: playerVC, queue: .main) { [weak self] note in
                FamilyPlayer.onMain {
                    self?.familyPlaybackStopped(reason: note.userInfo?["reason"] as? String,
                                                message: note.userInfo?["message"] as? String,
                                                playbackSeconds: note.userInfo?["playbackSeconds"] as? Int)
                }
            })
        }

        familyObservers.append(NotificationCenter.default.addObserver(forName: PlaybackCoordinator.modeWillChangeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            FamilyPlayer.onMain {
                guard let self else { return }
                self.invalidateChildQuiz()
                self.invalidateChildGate()
                if self.familyReason == "quizRequired" {
                    self.hasShownFamilyMessage = false
                    self.afterFamilyModalCloses { [weak self] in self?.showFamilyMessageIfNeeded() }
                }
                self.familyBlocked = true
                // AVPlayerViewController has no public stopPiP selector. Removing its
                // player/item and disabling PiP terminates the AVKit playback channel.
                self.playerVC.allowsPictureInPicturePlayback = false
                self.isRestoringFromPip = false
                self.cleanUpPlayerOnExit(force: true)
                PipRecorder.shared.playingPipViewController.removeAll { $0 === self }
            }
        })

        familyObservers.append(NotificationCenter.default.addObserver(forName: PlaybackCoordinator.clockRecoveryNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            FamilyPlayer.onMain {
                guard let self, self.playbackIsChild else { return }
                self.invalidateChildQuiz()
                self.invalidateChildGate()
                if self.familyReason == "quizRequired" {
                    self.hasShownFamilyMessage = false
                    self.afterFamilyModalCloses { [weak self] in self?.showFamilyMessageIfNeeded() }
                }
                self.familyPlaybackStopped(reason: "clock", message: PlaybackCoordinator.Reason.clock.message)
            }
        })
        familyObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            FamilyPlayer.onMain {
                guard let self else { return }
                self.endClockRecoverySession()
                self.invalidateChildQuiz()
                self.invalidateChildGate()
                // Backgrounded confirmations/results cannot resume playback later.
                if self.familyReason == "clock" || self.familyReason == "quizRequired" || self.usesChildPlaybackStatus {
                    self.hasShownFamilyMessage = false
                    if let modal = self.presentedViewController {
                        modal.view.isHidden = true
                        modal.dismiss(animated: false) { [weak self] in self?.showFamilyMessageIfNeeded() }
                    }
                }
            }
        })
        familyObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            FamilyPlayer.onMain { self?.showFamilyMessageIfNeeded() }
        })

        let playerObservation = playerVC.observe(\.player, options: [.old, .new]) { [weak self] vc, obs in
            FamilyPlayer.onMain {
                if let oldPlayer = obs.oldValue ?? nil, oldPlayer !== vc.player {
                    PlaybackCoordinator.shared.stop(player: oldPlayer)
                    self?.activePlugins.forEach { $0.playerDidCleanUp(player: oldPlayer) }
                }
                self?.playerDidChange(player: vc.player)
            }
        }
        observations.insert(playerObservation)
        activePlugins.forEach { $0.playerDidLoad(playerVC: playerVC) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            endClockRecoverySession()
            if !isReplacingAfterChildQuiz { invalidateChildQuiz() }
            if !isReplacingAfterChildGate { invalidateChildGate() }
        }
        activePlugins.forEach { $0.playerDidDismiss(playerVC: playerVC) }
        cleanUpPlayerOnExit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showFamilyMessageIfNeeded()
    }

    private func familyPlaybackStopped(reason: String?, message: String?, playbackSeconds: Int? = nil) {
        guard !familyBlocked else { return }
        familyPlaybackWasRevoked(at: playbackSeconds ?? currentPlaybackTimeInSeconds())
        familyBlocked = true
        familyReason = reason
        familyMessage = message
        usesChildPlaybackStatus = playbackIsChild && ["quota", "resting", "scheduleBlocked", "expired", "interrupted"].contains(reason ?? "")
        cleanUpPlayerOnExit(force: true)
        if reason == "clock" || reason == "quizRequired" || usesChildPlaybackStatus {
            // The revoked AVKit transport must not compete with gate controls.
            playerVC.showsPlaybackControls = false
            playerVC.view.isUserInteractionEnabled = false
        }
        showFamilyMessageIfNeeded()
    }

    private func showFamilyMessageIfNeeded() {
        guard !hasShownFamilyMessage, !isPresentingChildQuiz, let familyMessage,
              viewIfLoaded?.window != nil, !isBeingDismissed,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil else { return }
        hasShownFamilyMessage = true
        if usesChildPlaybackStatus {
            showChildPlaybackStatus()
            return
        }
        if familyReason == "clock" {
            showClockRecoveryEntry()
            return
        }
        if familyReason == "quizRequired" {
            showChildQuizEntry()
            return
        }
        let alertController = UIAlertController(title: "家庭播放控制", message: familyMessage, preferredStyle: .alert)
        alertController.view.accessibilityIdentifier = "family-playback-denial-" + (familyReason ?? "unknown")
        alertController.view.accessibilityValue = familyReason
        alertController.addAction(UIAlertAction(title: "返回", style: .default) { [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        })
        present(alertController, animated: true, completion: nil)
    }

    private func invalidateChildGate() {
        childGateGeneration = UUID()
        isReplacingAfterChildGate = false
    }

    private func childGateIsCurrent(_ generation: UUID) -> Bool {
        generation == childGateGeneration && familyBlocked && playbackIsChild
            && viewIfLoaded?.window != nil && !isBeingDismissed
            && UIApplication.shared.applicationState == .active
            && PlaybackCoordinator.shared.isModeCurrent(playbackModeGeneration, child: true)
            && childPlaybackGeneration == PlaybackCoordinator.shared.childPlaybackGeneration
    }

    private func showChildPlaybackStatus() {
        let generation = childGateGeneration
        let screen = FamilyChildPlaybackStatusController()
        screen.modalPresentationStyle = .overFullScreen
        screen.canRetry = supportsFamilyGateRetry
        screen.isContextCurrent = { [weak self] in self?.childGateIsCurrent(generation) == true }
        screen.onReturn = { [weak self] in
            self?.afterFamilyModalCloses { [weak self] in self?.dismiss(animated: true) }
        }
        screen.onContinue = { [weak self] in
            guard let self, self.childGateIsCurrent(generation) else { return }
            self.afterFamilyModalCloses { [weak self] in
                guard let self, self.childGateIsCurrent(generation),
                      let source = self.presentingViewController,
                      let replacement = self.makeFamilyGateRetryPlayer() else { return }
                self.isReplacingAfterChildGate = true
                source.dismiss(animated: false) { [weak source] in
                    guard let source, source.viewIfLoaded?.window != nil, source.presentedViewController == nil,
                          replacement.canLoadFamilyPlayback, UIApplication.shared.applicationState == .active else { return }
                    source.present(replacement, animated: true)
                }
            }
        }
        screen.onQuiz = { [weak self] in
            guard let self, self.childGateIsCurrent(generation) else { return }
            self.afterFamilyModalCloses { [weak self] in
                guard let self, self.childGateIsCurrent(generation) else { return }
                self.usesChildPlaybackStatus = false
                self.familyReason = "quizRequired"
                self.familyMessage = PlaybackCoordinator.Reason.quizRequired.message
                self.presentChildQuiz()
            }
        }
        present(screen, animated: true)
    }

    private func clockRecoveryIsCurrent(_ generation: UUID) -> Bool {
        // Maintenance blocks playback, not the parent repair that owns it.
        generation == clockRecoveryGeneration && viewIfLoaded?.window != nil
            && !isBeingDismissed && UIApplication.shared.applicationState == .active
            && PlaybackCoordinator.shared.modeGeneration == playbackModeGeneration
            && FamilyModeState.childActive
    }

    private func showClockRecoveryEntry() {
        let generation = clockRecoveryGeneration
        Task { @MainActor [weak self] in
            let environment = FamilyEnvironment.shared
            await environment.refresh()
            guard let self, self.clockRecoveryIsCurrent(generation), self.presentedViewController == nil else { return }
            guard let state = environment.snapshot else {
                self.showClockRecoveryFailure("家庭记录暂时无法读取，不能修复。原有数据未被清空。")
                return
            }
            let message = "\(FamilyClockRecoveryPresenter.reason(for: state))。\n设备时间：\(FamilyClockRecoveryPresenter.currentDateTime())\n\n时间正确时，选择“验证并继续”，输入家长 PIN 即完成修复并继续视频。观看记录、额度和规则不会重置。"
                + (state.recoveryQuarantineActive ? "\n\n" + FamilyClockRecoveryPresenter.quarantineMessage : "")
            let screen = FamilyClockRecoveryEntryController(message: message)
            screen.onContinue = { [weak self] in
                guard let self, self.clockRecoveryIsCurrent(generation) else { return }
                self.afterFamilyModalCloses { [weak self] in self?.presentClockPIN(generation: generation) }
            }
            screen.onCancel = { [weak self] in self?.leaveClockPlayback() }
            self.present(screen, animated: true)
        }
    }

    /// UIAlertAction is already dismissing its alert when called. Complete that
    /// transition before showing a PIN or dismissing the actual player container.
    private func afterFamilyModalCloses(_ action: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            if let modal = self.presentedViewController {
                if modal.isBeingDismissed || modal.isBeingPresented,
                   let transition = modal.transitionCoordinator,
                   transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                       self?.afterFamilyModalCloses(action)
                   }) { return }
                modal.dismiss(animated: true) { [weak self] in
                    guard self?.viewIfLoaded?.window != nil else { return }
                    action()
                }
            } else {
                action()
            }
        }
    }

    private func presentClockPIN(generation: UUID) {
        guard clockRecoveryIsCurrent(generation), !isAuthorizingClock,
              presentedViewController == nil else { return }
        isAuthorizingClock = true
        let environment = FamilyEnvironment.shared
        let pin = FamilyPINViewController(auth: environment.auth, context: .recovery)
        pin.onCancel = { [weak self] in self?.cancelClockRecovery() }
        pin.onAuthorized = { [weak self, weak pin] _, session in
            guard let self, self.clockRecoveryIsCurrent(generation) else {
                Task { await environment.auth.endSession(session) }
                return
            }
            self.clockRecoverySession = session
            pin?.dismiss(animated: true) { [weak self] in
                guard let self, self.clockRecoveryIsCurrent(generation) else {
                    Task { await environment.auth.endSession(session) }
                    return
                }
                self.clockRecoveryTask = Task { @MainActor [weak self] in
                    guard let self, self.clockRecoveryIsCurrent(generation) else { return }
                    do {
                        let token = try await environment.auth.operationAuthorization(session, context: .recovery)
                        guard self.clockRecoveryIsCurrent(generation), !Task.isCancelled else { return }
                        let state = try await environment.confirmClock(authorization: token, isCurrent: { [weak self] in
                            self?.clockRecoveryIsCurrent(generation) == true
                        })
                        guard self.clockRecoveryIsCurrent(generation), !Task.isCancelled else { return }
                        if state.clockIsTrusted && !state.recoveryQuarantineActive && self.supportsFamilyClockRetry {
                            self.retryAfterClockRecovery()
                        } else {
                            self.showClockRecoveryFailure(FamilyClockRecoveryPresenter.resultMessage(for: state))
                        }
                    } catch {
                        guard self.clockRecoveryIsCurrent(generation), !Task.isCancelled else { return }
                        #if DEBUG
                        print("Clock recovery failed: \(error)")
                        #endif
                        self.showClockRecoveryFailure("这次修复未完成，原记录和额度已保留。可以重新验证或返回视频列表。")
                    }
                }
            }
        }
        present(pin, animated: true)
    }

    private func endClockRecoverySession() {
        clockRecoveryGeneration = UUID()
        clockRecoveryTask?.cancel()
        clockRecoveryTask = nil
        let session = clockRecoverySession
        clockRecoverySession = nil
        isAuthorizingClock = false
        if let session {
            let auth = FamilyEnvironment.shared.auth
            Task { await auth.endSession(session) }
        }
    }

    private func cancelClockRecovery() {
        endClockRecoverySession()
        hasShownFamilyMessage = false
        afterFamilyModalCloses { [weak self] in self?.showFamilyMessageIfNeeded() }
    }

    private func showClockRecoveryFailure(_ message: String) {
        endClockRecoverySession()
        let alert = UIAlertController(title: "暂时无法继续播放", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "family-clock-result"
        alert.addAction(UIAlertAction(title: "重新验证", style: .default) { [weak self] _ in self?.cancelClockRecovery() })
        alert.addAction(UIAlertAction(title: "返回视频列表", style: .cancel) { [weak self] _ in self?.leaveClockPlayback() })
        afterFamilyModalCloses { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil,
                  UIApplication.shared.applicationState == .active else { return }
            self.present(alert, animated: true)
        }
    }

    private func leaveClockPlayback() {
        endClockRecoverySession()
        afterFamilyModalCloses { [weak self] in self?.dismiss(animated: true) }
    }

    private func retryAfterClockRecovery() {
        // A successful PIN completes the explicit "verify and continue" action.
        // Only a NEW source container can obtain a new lease; the old one stays blocked.
        guard familyBlocked, familyReason == "clock", playbackIsChild,
              PlaybackCoordinator.shared.isModeCurrent(playbackModeGeneration, child: true),
              presentedViewController == nil,
              let source = presentingViewController,
              let replacement = makeFamilyClockRetryPlayer() else {
            leaveClockPlayback()
            return
        }
        endClockRecoverySession()
        source.dismiss(animated: false) { [weak source] in
            guard let source, source.viewIfLoaded?.window != nil,
                  source.presentedViewController == nil,
                  UIApplication.shared.applicationState == .active,
                  replacement.canLoadFamilyPlayback else { return }
            source.present(replacement, animated: true)
        }
    }

    /// Child-facing gate uses the same focused TV actions as clock recovery.
    private func showChildQuizEntry() {
        let generation = childQuizGeneration
        guard childQuizIsCurrent(generation) else {
            let alert = UIAlertController(title: "请重新打开视频",
                message: "家庭播放状态已改变。本次不会自动继续；请返回视频列表重新打开。", preferredStyle: .alert)
            alert.view.accessibilityIdentifier = "family-quiz-unavailable"
            alert.addAction(UIAlertAction(title: "返回视频列表", style: .cancel) { [weak self] _ in
                self?.leaveQuizPlayback()
            })
            present(alert, animated: true)
            return
        }
        let screen = FamilyChildPlaybackStatusController()
        screen.modalPresentationStyle = .overFullScreen
        screen.quizActionIdentifier = "family-quiz-start"
        screen.prefersQuizFocus = true
        screen.canRetry = supportsFamilyGateRetry
        screen.isContextCurrent = { [weak self] in self?.childQuizIsCurrent(generation) == true }
        screen.onQuiz = { [weak self] in self?.presentChildQuiz() }
        screen.onContinue = { [weak self] in
            self?.afterFamilyModalCloses { [weak self] in self?.retryAfterChildQuiz(generation: generation) }
        }
        screen.onReturn = { [weak self] in self?.leaveQuizPlayback() }
        present(screen, animated: true)
    }

    private func childQuizIsCurrent(_ generation: UUID) -> Bool {
        generation == childQuizGeneration && familyBlocked && familyReason == "quizRequired"
            && playbackIsChild && viewIfLoaded?.window != nil && !isBeingDismissed
            && !isMovingFromParent && navigationController?.isBeingDismissed != true
            && UIApplication.shared.applicationState == .active
            && PlaybackCoordinator.shared.isModeCurrent(playbackModeGeneration, child: true)
            && childPlaybackGeneration == PlaybackCoordinator.shared.childPlaybackGeneration
    }

    private func invalidateChildQuiz() {
        childQuizGeneration = UUID()
        childQuizTask?.cancel()
        childQuizTask = nil
        isPresentingChildQuiz = false
        isReplacingAfterChildQuiz = false
    }

    private func leaveQuizPlayback() {
        invalidateChildQuiz()
        afterFamilyModalCloses { [weak self] in self?.dismiss(animated: true) }
    }

    /// Dismiss the denial before reading the authoritative outstanding viewers.
    private func presentChildQuiz() {
        let generation = childQuizGeneration
        guard childQuizIsCurrent(generation), !isPresentingChildQuiz else { return }
        isPresentingChildQuiz = true
        afterFamilyModalCloses { [weak self] in
            guard let self, self.childQuizIsCurrent(generation) else { return }
            self.childQuizTask = Task { @MainActor [weak self] in
                let environment = FamilyEnvironment.shared
                await environment.refresh()
                guard let self, self.childQuizIsCurrent(generation), !Task.isCancelled,
                      self.presentedViewController == nil else { return }
                guard environment.errorMessage == nil, let state = environment.snapshot else {
                    self.showChildQuizUnavailable("家庭记录暂时无法读取，不能开始答题。请返回后重试；原有额度和规则未改变。", generation: generation)
                    return
                }
                let viewers = state.activeViewerIDs
                guard !viewers.isEmpty, Set(viewers).count == viewers.count,
                      viewers.allSatisfy({ id in state.profiles.contains { $0.id == id && $0.isEnabled } }) else {
                    self.showChildQuizUnavailable("请家长先选择有效的观看成员，再重新打开视频。", generation: generation)
                    return
                }
                let pendingViewers = state.pendingQuizViewerIDs
                if pendingViewers.isEmpty {
                    self.retryAfterChildQuiz(generation: generation)
                    return
                }
                var allPassed = false
                let quiz = FamilyQuizViewController(environment: environment, viewerIDs: pendingViewers, onFinished: { [weak self] in
                    guard let self, self.childQuizIsCurrent(generation) else { return }
                    if allPassed {
                        self.afterFamilyModalCloses { [weak self] in self?.retryAfterChildQuiz(generation: generation) }
                    } else {
                        self.returnToChildQuizGate(generation: generation)
                    }
                })
                quiz.onPassed = { allPassed = true }
                self.present(quiz, animated: true)
            }
        }
    }

    private func returnToChildQuizGate(generation: UUID) {
        guard childQuizIsCurrent(generation) else { return }
        invalidateChildQuiz()
        hasShownFamilyMessage = false
        // Only restore the gate. Failed/cancelled rounds never trigger a factory.
        afterFamilyModalCloses { [weak self] in self?.showFamilyMessageIfNeeded() }
    }

    private func showChildQuizUnavailable(_ message: String, generation: UUID) {
        guard childQuizIsCurrent(generation) else { return }
        let alert = UIAlertController(title: "暂时无法继续", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "family-quiz-unavailable"
        alert.addAction(UIAlertAction(title: "返回答题入口", style: .default) { [weak self] _ in
            self?.returnToChildQuizGate(generation: generation)
        })
        alert.addAction(UIAlertAction(title: "返回视频列表", style: .cancel) { [weak self] _ in
            self?.leaveQuizPlayback()
        })
        present(alert, animated: true)
    }

    private func retryAfterChildQuiz(generation: UUID) {
        guard childQuizIsCurrent(generation), presentedViewController == nil,
              supportsFamilyGateRetry, let source = presentingViewController,
              let replacement = makeFamilyGateRetryPlayer(), replacement !== self else {
            if childQuizIsCurrent(generation) {
                showChildQuizUnavailable("本次答题已通过。请返回视频列表重新打开视频，继续按当前家庭规则检查。", generation: generation)
            }
            return
        }
        // Never revive the revoked player/lease. The new source must reserve through
        // PlaybackCoordinator again (current viewers, quiz, quota, rest and schedule).
        // Keep this generation through dismissal: any intervening background/mode
        // event still cancels the handoff, even if the app is active again afterward.
        isReplacingAfterChildQuiz = true
        source.dismiss(animated: false) { [self, weak source] in
            let shouldContinue = generation == childQuizGeneration && isReplacingAfterChildQuiz
            invalidateChildQuiz()
            guard shouldContinue, let source, source.viewIfLoaded?.window != nil,
                  source.presentedViewController == nil, !source.isBeingDismissed,
                  UIApplication.shared.applicationState == .active,
                  replacement.canLoadFamilyPlayback else { return }
            source.present(replacement, animated: true)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if familyBlocked, familyReason == "clock" || familyReason == "quizRequired" || usesChildPlaybackStatus {
            if let presentedViewController { return [presentedViewController] }
            return []
        }
        return [playerVC.view]
    }

    func addPlugin(plugin: CommonPlayerPlugin) {
        // Preview controllers intentionally have no transport controls. Do not install
        // even their asynchronous loading plugins, so focus/foreground cannot autoplay.
        guard canLoadFamilyPlayback else { return }
        if activePlugins.contains(where: { $0 == plugin }) {
            return
        }
        plugin.addViewToPlayerOverlay(container: playerVC.contentOverlayView!)
        activePlugins.append(plugin)
        plugin.playerDidLoad(playerVC: playerVC)
        if playerVC.transportBarCustomMenuItems.isEmpty == false {
            updateMenus()
        }
    }

    func removePlugin(plugin: CommonPlayerPlugin) {
        let removingPlugins = activePlugins.filter { $0 == plugin }
        removingPlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            removingPlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll { $0 == plugin }
    }

    func removeAllPlugins() {
        PlaybackCoordinator.shared.stop(owner: playerVC)
        guard !activePlugins.isEmpty else { return }
        activePlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            Logger.debug("removeAllPlugins: clean up player: \(player)")
            activePlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll()
    }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}

    func showErrorAlertAndExit(title: String = "播放失败", message: String = "未知错误") {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let actionOk = UIAlertAction(title: "好", style: .default) {
            [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }
        alertController.addAction(actionOk)
        present(alertController, animated: true, completion: nil)
    }

    func updateMenus() {
        var menus = [UIMenuElement]()
        for activePlugin in activePlugins {
            let newMenus = activePlugin.addMenuItems(current: &menus)
            menus.append(contentsOf: newMenus)
        }
        playerVC.transportBarCustomMenuItems = menus
    }

    func denyFamilyPlayback(_ reason: PlaybackCoordinator.Reason) {
        guard FamilyModeState.childActive else { return }
        PlaybackCoordinator.shared.deny(reason, owner: playerVC)
    }

    func stopPlayback() {
        cleanUpPlayerOnExit(force: true)
    }

    func currentPlaybackTimeInSeconds() -> Int? {
        guard let seconds = playerVC.player?.currentTime().seconds,
              seconds.isFinite,
              seconds > 0
        else {
            return nil
        }
        return Int(seconds.rounded(.down))
    }

    private func cleanUpPlayerOnExit(force: Bool = false) {
        let isPictureInPictureRunning = isPlaybackContextCurrent && !playbackIsChild
            && PipRecorder.shared.playingPipViewController.contains { $0 === self }
        let shouldCleanUp = force || ((isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true)
            && !isPictureInPictureRunning)
        guard shouldCleanUp else { return }
        // A closed container cannot be revived by a delayed plugin callback, even
        // when it was closed in adult mode and the user later toggles modes twice.
        familyBlocked = true
        PlaybackCoordinator.shared.stop(owner: playerVC)
        cleanUpObserver()

        let player = playerVC.player
        player?.pause()
        // Plugins may still be preparing the first AVPlayer. Always run their
        // cleanup hook even when playerVC.player has not been installed yet.
        removeAllPlugins()
        player?.replaceCurrentItem(with: nil)
        playerVC.player = nil
    }

    private func cleanUpObserver() {
        rateObserver = nil
        statusObserver = nil
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = nil
    }
}

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        cleanUpObserver()
        if let player {
            guard isPlaybackContextCurrent,
                  PlaybackCoordinator.shared.permitsPlayback(player, owner: playerVC) else {
                PlaybackCoordinator.shared.stop(player: player)
                if FamilyModeState.childActive { PlaybackCoordinator.shared.deny(.uncontrolled, owner: playerVC) }
                return
            }
            activePlugins.forEach { $0.playerDidChange(player: player) }
            rateObserver = player.observe(\.rate, options: [.old, .new]) { [weak self] player, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isPlaybackContextCurrent, self.playerVC.player === player else { return }
                    self.playerRateDidChange(player: player)
                }
            }
            if let playItem = player.currentItem {
                observePlayerItem(playItem)
            }
            updateMenus()
        } else {
            cleanUpObserver()
        }
    }

    private func playerRateDidChange(player: AVPlayer) {
        if player.rate > 0 {
            activePlugins.forEach { $0.playerDidStart(player: player) }
            playerDidStart(player: player)
        } else if player.rate == 0 {
            if !isEnd {
                activePlugins.forEach { $0.playerDidPause(player: player) }
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaybackContextCurrent, let player = self.playerVC.player,
                      player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.isEnd = false
                    self.activePlugins.forEach { $0.playerWillStart(player: player) }
                    self.playerWillStart(player: player)
                    if self.autoPlayWhenReady { player.play() }
                case .failed:
                    self.activePlugins.forEach { $0.playerDidFail(player: player) }
                    self.playerDidFail(player: player)
                default: break
                }
            }
        }
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            guard let self, isPlaybackContextCurrent, let player = playerVC.player,
                  player.currentItem === playerItem else { return }
            isEnd = true
            activePlugins.forEach { $0.playerDidEnd(player: player) }
            playerDidEnd(player: player)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, isPlaybackContextCurrent, let player = playerVC.player,
                  player.currentItem === playerItem else { return }
            activePlugins.forEach { $0.playerDidStall(player: player) }
            playerDidStall(player: player)
        }
    }
}

extension CommonPlayerViewController: AVPlayerViewControllerDelegate {
    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        if let presentedViewController = UIViewController.topMostViewController() as? CommonPlayerViewController,
           presentedViewController.playerVC == playerViewController
        {
            dismiss(animated: true)
            return false
        }
        return false
    }

    @objc func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
        return true
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard isPlaybackContextCurrent, !FamilyModeState.childActive else {
            PlaybackCoordinator.shared.deny(.external, owner: playerViewController)
            return
        }
        isRestoringFromPip = false
        if !PipRecorder.shared.playingPipViewController.contains(where: { $0 === self }) {
            PipRecorder.shared.playingPipViewController.append(self)
        }
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        PipRecorder.shared.playingPipViewController.removeAll { $0.playerVC == playerViewController }
        if !isRestoringFromPip {
            // 用户点 ✕ 关闭 PiP，清理资源
            cleanUpPlayerOnExit(force: true)
        }
        isRestoringFromPip = false
    }

    @objc func playerViewController(_ playerViewController: AVPlayerViewController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
    {
        guard isPlaybackContextCurrent, !FamilyModeState.childActive,
              let containerPlayer = PipRecorder.shared.playingPipViewController.first(where: { $0.playerVC === playerViewController }) else {
            completionHandler(false)
            return
        }
        isRestoringFromPip = true
        let top = UIViewController.topMostViewController()
        if top === containerPlayer { completionHandler(true); return }
        if top is CommonPlayerViewController {
            let parent = top.presentingViewController
            top.dismiss(animated: false) {
                guard containerPlayer.isPlaybackContextCurrent, let parent else {
                    completionHandler(false)
                    return
                }
                parent.present(containerPlayer, animated: false) {
                    completionHandler(containerPlayer.isPlaybackContextCurrent)
                }
            }
        } else {
            top.present(containerPlayer, animated: false) {
                completionHandler(containerPlayer.isPlaybackContextCurrent)
            }
        }
    }

    class PipRecorder {
        static let shared = PipRecorder()
        var playingPipViewController = [CommonPlayerViewController]()
    }
}
