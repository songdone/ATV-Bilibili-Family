import AVKit
import FamilyCore
import UIKit

/// Child playback is leased; adult playback keeps independent upstream AVPlayers.
/// Both modes register here so a mode transition can synchronously revoke everything.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()
    static let deniedNotification = Notification.Name("FamilyPlaybackDenied")
    static let stoppedNotification = Notification.Name("FamilyPlaybackStopped")
    static let modeWillChangeNotification = Notification.Name("FamilyPlaybackModeWillChange")
    static let clockRecoveryNotification = Notification.Name("FamilyPlaybackClockRecovery")

    /// Clock recovery invalidates only child containers, including those whose
    /// first asynchronous media request has not installed a loading ticket yet.
    private(set) var childPlaybackGeneration = UUID()

    /// Rotate on EVERY explicit transition, including adult -> child -> adult.
    private(set) var modeGeneration = UUID()
    private var expectedChildMode: Bool?
    private var transitioning = false

    func isModeCurrent(_ generation: UUID, child: Bool) -> Bool {
        !transitioning && generation == modeGeneration && childModeActive == child
            && (expectedChildMode == nil || expectedChildMode == child)
            && (!child || !FamilyEnvironment.shared.isMaintaining)
    }

    /// Enforcement is mode-scoped, never global: adult mode preserves the original
    /// client (live, casting, PiP, previews); child mode is the only ledger path.
    private var childModeActive: Bool { FamilyModeState.childActive }

    enum Reason: String {
        case setup, viewers, clock, ledger, quota, resting, scheduleBlocked, quizRequired, expired, interrupted, live, preview, external, uncontrolled

        var message: String {
            switch self {
            case .setup: return "请先由家长设置家庭 PIN 和观看规则，再开始播放。"
            case .viewers: return "请先由家长选择并锁定有效的观看成员。"
            case .clock: return "设备时间的连续性无法验证，儿童播放已安全停止。家长可在这里确认当前时间后重新尝试，不必前往系统设置。"
            case .ledger: return "家庭账本不可用，播放已锁定。请由家长检查恢复数据。"
            case .quota: return "本次观看已暂停，正在确认今天的剩余时间和休息安排。"
            case .resting: return "休息一下吧，稍后可以查看还要休息多久。"
            case .scheduleBlocked: return "现在不在观看时段，稍后可以查看下次什么时候能看。"
            case .quizRequired: return "需要先完成答题，再按当前观看规则继续。"
            case .expired: return "播放授权未能及时续期，已安全停止。请重新打开视频。"
            case .interrupted: return "播放已因离开前台、系统中断或播放路由变化而停止，请重新打开视频。"
            case .live: return "儿童模式下暂不支持直播，请选择普通视频。"
            case .preview: return "儿童模式已关闭自动视频预览，请打开视频观看。"
            case .external: return "儿童模式暂不支持 DLNA、AirPlay 或画中画播放。"
            case .uncontrolled: return "此播放入口尚未接入家庭控制，已禁止播放。"
            }
        }
    }

    private final class Session {
        let id = UUID()
        let generation: UUID
        weak var owner: AVPlayerViewController?
        var player: AVPlayer?
        var item: AVPlayerItem?
        var ledger: UsageLedger?
        var lease: PlaybackLease?
        var revoked = false
        var renewalTimer: DispatchSourceTimer?
        var deadlineTimer: DispatchSourceTimer?
        init(owner: AVPlayerViewController, generation: UUID) {
            self.owner = owner
            self.generation = generation
        }
    }

    private final class AdultSession {
        let id = UUID()
        let generation: UUID
        weak var owner: AVPlayerViewController?
        weak var player: AVPlayer?
        var madePlayer = false
        init(owner: AVPlayerViewController, generation: UUID) {
            self.owner = owner
            self.generation = generation
        }
    }

    private var adultSessions = [UUID: AdultSession]()
    private var current: Session?
    // One FIFO consumer, not an independent Task per KVO edge. Renewal and activity
    // operations use the same queue; a delayed old callback cannot mutate a new session.
    private var operations = [@MainActor () async -> Void]()
    private var draining = false
    private var lifecycleObservers = [NSObjectProtocol]()
    private let requestedMilliseconds: Int64 = 5_000
    private let stopMarginMilliseconds: Int64 = 100

    private init() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIScene.willDeactivateNotification, AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                FamilyPlayer.onMain { self?.suspend(reason: "system lifecycle") }
            })
        }
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            FamilyPlayer.onMain { self?.suspend(reason: "audio interruption") }
        })
    }

    /// Call synchronously BEFORE publishing the new effective mode. This is NOT a
    /// lifecycle suspension: every controlled/adult player and loading ticket dies.
    func modeWillChange(toChild: Bool) {
        transitioning = true
        modeGeneration = UUID()
        expectedChildMode = toChild
        if let current { revoke(current, reason: nil, denied: false) }
        let adults = Array(adultSessions.values)
        adultSessions.removeAll()
        for session in adults { clearAdult(session) }
        // Also covers containers still awaiting their first plugin/player and PiP
        // containers retained by AVKit. Observers cancel their own asynchronous work.
        NotificationCenter.default.post(name: Self.modeWillChangeNotification, object: nil,
                                        userInfo: ["toChild": toChild])
        transitioning = false
    }

    /// Environment sets isMaintaining before calling this. Unlike a mode change,
    /// clock recovery never stops adult playback, PiP, casting or previews.
    func beginClockRecoveryMaintenance() {
        childPlaybackGeneration = UUID()
        if let current { revoke(current, reason: .clock, denied: false) }
        NotificationCenter.default.post(name: Self.clockRecoveryNotification, object: nil)
    }

    /// Root/background/route changes are policy stops only in CHILD mode. Adult
    /// AVKit retains its upstream PiP, AirPlay and background-resume lifecycle.
    func suspend(reason _: String) {
        guard childModeActive, let current else { return }
        revoke(current, reason: .interrupted, denied: false)
    }

    /// Called before asynchronous media preparation, not just before installing its result.
    func beginLoading(owner: AVPlayerViewController) -> UUID? {
        guard isModeCurrent(modeGeneration, child: childModeActive),
              let container = owner.parent as? CommonPlayerViewController,
              container.canLoadFamilyPlayback else { return nil }
        if !childModeActive {
            adultSessions = adultSessions.filter { $0.value.owner != nil || $0.value.player != nil }
            // Only a SAME-owner source/quality replacement ends the previous ticket.
            // A preview, fullscreen video and PiP may coexist without preempting each other.
            for session in Array(adultSessions.values) where session.owner === owner {
                adultSessions.removeValue(forKey: session.id)
                clearAdult(session)
            }
            let session = AdultSession(owner: owner, generation: modeGeneration)
            adultSessions[session.id] = session
            return session.id
        }
        guard UIApplication.shared.applicationState == .active else {
            deny(.interrupted, owner: owner)
            return nil
        }
        if let old = current {
            // Same-owner quality/CDN switch is not a UI-level stop. The old token still
            // becomes unusable synchronously; settlement precedes the next reservation.
            revoke(old, reason: old.owner === owner ? nil : .interrupted, denied: false)
        }
        let session = Session(owner: owner, generation: modeGeneration)
        current = session
        return session.id
    }

    func isLoading(_ ticket: UUID, owner: AVPlayerViewController) -> Bool {
        if let session = adultSessions[ticket] {
            return session.owner === owner && isModeCurrent(session.generation, child: false)
                && (owner.parent as? CommonPlayerViewController)?.canLoadFamilyPlayback == true
        }
        guard let session = current else { return false }
        return session.id == ticket && session.owner === owner && isCurrent(session)
    }

    func makePlayer(item: AVPlayerItem, owner: AVPlayerViewController, ticket: UUID) async -> AVPlayer? {
        guard isLoading(ticket, owner: owner) else { return nil }
        if let session = adultSessions[ticket] {
            guard !session.madePlayer else { return nil }
            let player = AVPlayer(playerItem: item)
            session.madePlayer = true
            session.player = player
            return player
        }
        guard let session = current, session.id == ticket, session.owner === owner else { return nil }
        return await withCheckedContinuation { continuation in
            enqueue { [self] in
                guard isCurrent(session) else { continuation.resume(returning: nil); return }
                do {
                    let environment = FamilyEnvironment.shared
                    await environment.start()
                    guard isCurrent(session) else { continuation.resume(returning: nil); return }
                    let auth = try await environment.auth.status()
                    guard isCurrent(session) else { continuation.resume(returning: nil); return }
                    guard auth != .notConfigured else { throw Denial(reason: .setup) }
                    guard let ledger = environment.ledger else { throw Denial(reason: .ledger) }
                    // Never authorize from the UI's cached snapshot or isReady flag.
                    let snapshot = try await ledger.snapshot()
                    guard isCurrent(session) else { continuation.resume(returning: nil); return }
                    guard snapshot.clockIsTrusted else { throw Denial(reason: .clock) }
                    let viewers = snapshot.activeViewerIDs
                    guard !viewers.isEmpty, Set(viewers).count == viewers.count,
                          viewers.allSatisfy({ id in snapshot.profiles.contains { $0.id == id && $0.isEnabled } }) else {
                        throw Denial(reason: .viewers)
                    }
                    session.ledger = ledger
                    let lease = try await ledger.reservePlayback(eventID: session.id.uuidString,
                                                                  requestedMilliseconds: requestedMilliseconds)
                    // Retain even a stale result so the queued revocation settles it.
                    session.lease = lease
                    guard isCurrent(session) else { continuation.resume(returning: nil); return }
                    guard lease.viewerIDs == viewers, remaining(lease) > 250 else { throw Denial(reason: .quota) }
                    let player = FamilyPlayer()
                    session.player = player
                    session.item = item
                    player.installAuthorizedItem(item)
                    armTimers(session)
                    continuation.resume(returning: player)
                } catch {
                    if isCurrent(session) { revoke(session, reason: reason(for: error), denied: true) }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func permitsTransport(_ player: FamilyPlayer) -> Bool {
        // A FamilyPlayer never becomes an adult bypass after a mode toggle.
        guard childModeActive else { return false }
        guard let session = current, session.player === player, isCurrent(session),
              let lease = session.lease, session.item === player.currentItem,
              session.item != nil, remaining(lease) > stopMarginMilliseconds else { return false }
        return true
    }

    func rejectTransport(_ player: FamilyPlayer) {
        if let session = current, session.player === player {
            revoke(session, reason: .expired, denied: true)
        } else {
            player.stopAndClear()
        }
    }

    func stop(player: AVPlayer) {
        if let session = current, session.player === player {
            revoke(session, reason: nil, denied: false)
            return
        }
        for session in Array(adultSessions.values) where session.player === player {
            adultSessions.removeValue(forKey: session.id)
        }
        clear(player)
    }

    func stop(owner: AVPlayerViewController) {
        if let session = current, session.owner === owner {
            revoke(session, reason: nil, denied: false)
        }
        for session in Array(adultSessions.values) where session.owner === owner {
            adultSessions.removeValue(forKey: session.id)
            clearAdult(session)
        }
    }

    /// Used by AVKit/plugin callbacks; also rejects an old plain adult instance.
    func permitsPlayback(_ player: AVPlayer, owner: AVPlayerViewController) -> Bool {
        if let family = player as? FamilyPlayer { return permitsTransport(family) }
        return adultSessions.values.contains {
            $0.owner === owner && $0.player === player && isModeCurrent($0.generation, child: false)
        }
    }

    private func clearAdult(_ session: AdultSession) {
        if let player = session.player { clear(player) }
    }

    private func clear(_ player: AVPlayer) {
        if let family = player as? FamilyPlayer { family.stopAndClear(); return }
        player.pause()
        player.rate = 0
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }

    func deny(_ reason: Reason, owner: AVPlayerViewController?) {
        if let session = current, session.owner === owner {
            revoke(session, reason: reason, denied: true)
        } else {
            notify(reason, owner: owner, denied: true)
        }
    }

    func activityChanged(_ player: FamilyPlayer, status: AVPlayer.TimeControlStatus) {
        guard let session = current, session.player === player, isCurrent(session) else { return }
        if status == .playing && !permitsTransport(player) { rejectTransport(player); return }
        let activity: PlaybackActivity
        switch status {
        case .playing: activity = .playing
        case .waitingToPlayAtSpecifiedRate: activity = .buffering
        default: activity = .paused
        }
        enqueue { [self] in
            // Edges already enqueued before revocation must precede its settlement,
            // even if a new session now owns the screen.
            guard let ledger = session.ledger, let lease = session.lease else { return }
            do {
                // Core currently timestamps at actor execution, NOT the KVO event instant.
                // FIFO preserves edges but actor/main-queue latency can over/under-count
                // transitions. Measure on physical tvOS hardware before claiming accuracy.
                try await ledger.setPlaybackActivity(leaseID: lease.id, activity: activity)
                guard isCurrent(session) else { return }
            } catch {
                if isCurrent(session) { revoke(session, reason: reason(for: error), denied: true) }
            }
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        current === session && !session.revoked && session.owner != nil
            && isModeCurrent(session.generation, child: true)
            && UIApplication.shared.applicationState == .active
    }

    private func remaining(_ lease: PlaybackLease) -> Int64 {
        let now = SystemLedgerClock().now()
        guard now.continuityID == lease.continuityID else { return 0 }
        return lease.expiresAtMonotonicMilliseconds - now.monotonicMilliseconds
    }

    private func armTimers(_ session: Session) {
        session.renewalTimer?.cancel()
        session.deadlineTimer?.cancel()
        guard let lease = session.lease else { return }
        let available = remaining(lease)
        guard available > 250 else { revoke(session, reason: .quota, denied: true); return }
        // Renew early; never wait until the exact deadline to settle. The independent
        // main-queue cutoff stays armed while the actor is busy. Main-thread stalls and
        // AVFoundation render latency still require device measurement, not a zero-frame claim.
        let lead = min(1_000, max(150, available / 3))
        let renew = DispatchSource.makeTimerSource(queue: .main)
        renew.schedule(deadline: .now() + .milliseconds(Int(max(1, available - lead))), leeway: .milliseconds(1))
        renew.setEventHandler { [weak self, weak session] in
            FamilyPlayer.onMain {
                guard let self, let session, self.isCurrent(session) else { return }
                self.enqueue { [self] in await self.renew(session) }
            }
        }
        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + .milliseconds(Int(max(1, available - stopMarginMilliseconds))), leeway: .milliseconds(1))
        deadline.setEventHandler { [weak self, weak session] in
            FamilyPlayer.onMain {
                guard let self, let session, self.current === session, session.lease?.id == lease.id else { return }
                self.revoke(session, reason: .expired, denied: true)
            }
        }
        session.renewalTimer = renew
        session.deadlineTimer = deadline
        renew.resume()
        deadline.resume()
    }

    private func renew(_ session: Session) async {
        guard isCurrent(session), let ledger = session.ledger, let lease = session.lease else { return }
        do {
            // Core settles and creates the successor in ONE transaction, carrying activity.
            let renewal = try await ledger.renewPlayback(leaseID: lease.id, requestedMilliseconds: requestedMilliseconds,
                                                          minimumSuccessorMilliseconds: 250)
            session.lease = renewal.nextLease
            guard isCurrent(session) else { return }
            guard renewal.nextLease != nil else { revoke(session, reason: .quota, denied: true); return }
            armTimers(session)
        } catch {
            if isCurrent(session) { revoke(session, reason: reason(for: error), denied: true) }
        }
    }

    private func revoke(_ session: Session, reason: Reason?, denied: Bool) {
        guard !session.revoked else { return }
        session.revoked = true
        let position = session.player?.currentTime().seconds
        let playbackSeconds = position.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil }
        session.renewalTimer?.cancel()
        session.deadlineTimer?.cancel()
        if current === session { current = nil }
        // Invalidate first, then synchronously stop/clear on main, then settle on the FIFO.
        if let family = session.player as? FamilyPlayer {
            family.stopAndClear()
        } else {
            session.player?.pause()
            session.player?.replaceCurrentItem(with: nil)
        }
        enqueue {
            guard let ledger = session.ledger else { return }
            do {
                if let lease = session.lease {
                    try await ledger.setPlaybackActivity(leaseID: lease.id, activity: .paused)
                    _ = try await ledger.settlePlayback(leaseID: lease.id)
                }
            } catch {
                // A late/untrusted/error lease remains conservatively frozen by Core.
                // No refund, new database, or uncontrolled playback fallback is attempted.
            }
            if reason == .quota || reason == .expired || reason == .resting || reason == .scheduleBlocked {
                do {
                    // Notifications describe the cutoff, not the final policy reason.
                    // Only the settled ledger can identify an unplayed safety margin.
                    let snapshot = try await ledger.snapshot()
                    let remainder = snapshot.configuration.continuousLimitMilliseconds
                        - snapshot.continuousActualMilliseconds - snapshot.continuousFrozenMilliseconds
                    if snapshot.clockIsTrusted, snapshot.activeLease == nil,
                       snapshot.remainingRestMilliseconds == 0, (1...250).contains(remainder) {
                        // Start a full rest, without inventing watched time or refunds.
                        try await ledger.requestFamilyRest()
                    }
                } catch {
                    // The status page reads fresh availability and fails closed on error.
                }
            }
            session.lease = nil
        }
        if let reason { notify(reason, owner: session.owner, denied: denied, playbackSeconds: playbackSeconds) }
    }

    /// Fence for snapshot/export/restore after synchronous mode revocation. It
    /// includes settlement queued behind any reserve/renew already in flight.
    func waitForPendingLedgerOperations() async {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume() }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        operations.append(operation)
        guard !draining else { return }
        draining = true
        Task { @MainActor [self] in
            while !operations.isEmpty {
                let next = operations.removeFirst()
                await next()
            }
            draining = false
        }
    }

    private func notify(_ reason: Reason, owner: AVPlayerViewController?, denied: Bool, playbackSeconds: Int? = nil) {
        var info: [String: Any] = ["reason": reason.rawValue, "message": reason.message]
        if let playbackSeconds { info["playbackSeconds"] = playbackSeconds }
        NotificationCenter.default.post(name: denied ? Self.deniedNotification : Self.stoppedNotification,
                                        object: owner, userInfo: info)
    }

    private struct Denial: Error { let reason: Reason }
    private func reason(for error: Error) -> Reason {
        if let denial = error as? Denial { return denial.reason }
        switch error as? LedgerError {
        case .clockUntrusted: return .clock
        case .noActiveViewers: return .viewers
        case .budgetExhausted: return .quota
        case .resting: return .resting
        case .scheduleBlocked: return .scheduleBlocked
        case .quizRequired: return .quizRequired
        case .leaseExpired, .invalidLease: return .expired
        default: return .ledger
        }
    }
}
