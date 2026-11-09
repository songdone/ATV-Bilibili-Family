import AVFoundation
import Foundation

/// Only coordinator-created, leased instances are installed in AVKit. All ordinary
/// transport selectors are gated BEFORE calling AVPlayer, including system controls.
/// KVO is defense in depth for internal AVFoundation changes, not a zero-frame guarantee.
final class FamilyPlayer: AVPlayer {
    private var internalTransport = false
    private var invalidated = false
    private var observers = [NSKeyValueObservation]()
    private var lastActivity: AVPlayer.TimeControlStatus?

    /// AVPlayer APIs are nonisolated. Marshal synchronously so a background resume cannot
    /// overtake revocation. Callers must not block main waiting on a player worker queue.
    static func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    override init() {
        super.init()
        super.allowsExternalPlayback = false
        super.usesExternalPlaybackWhileExternalScreenIsActive = false
        actionAtItemEnd = .pause
        observers.append(observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Self.onMain {
                let status = player.timeControlStatus
                guard !self.invalidated, self.lastActivity != status else { return }
                self.lastActivity = status
                PlaybackCoordinator.shared.activityChanged(self, status: status)
            }
        })
        observers.append(observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self, player.rate != 0 else { return }
            Self.onMain {
                guard !PlaybackCoordinator.shared.permitsTransport(self) else { return }
                PlaybackCoordinator.shared.rejectTransport(self)
            }
        })
        observers.append(observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            guard let self, player.isExternalPlaybackActive else { return }
            Self.onMain { PlaybackCoordinator.shared.rejectTransport(self) }
        })
    }

    override var allowsExternalPlayback: Bool {
        get { false }
        set { super.allowsExternalPlayback = false }
    }

    override var usesExternalPlaybackWhileExternalScreenIsActive: Bool {
        get { false }
        set { super.usesExternalPlaybackWhileExternalScreenIsActive = false }
    }

    override func play() {
        Self.onMain { transport(rate: defaultRate) { super.play() } }
    }

    override func playImmediately(atRate rate: Float) {
        Self.onMain { transport(rate: rate) { super.playImmediately(atRate: rate) } }
    }

    override var rate: Float {
        get { super.rate }
        set { Self.onMain { transport(rate: newValue) { super.rate = newValue } } }
    }

    override func setRate(_ rate: Float, time itemTime: CMTime, atHostTime hostClockTime: CMTime) {
        Self.onMain {
            transport(rate: rate) { super.setRate(rate, time: itemTime, atHostTime: hostClockTime) }
        }
    }

    override func pause() {
        Self.onMain { transport(rate: 0) { super.pause() } }
    }

    private func transport(rate: Float, perform: () -> Void) {
        if internalTransport { perform(); return }
        if rate != 0 {
            guard !invalidated, rate.isFinite,
                  Self.onMain({ PlaybackCoordinator.shared.permitsTransport(self) }) else {
                Self.onMain { PlaybackCoordinator.shared.rejectTransport(self) }
                return
            }
        }
        internalTransport = true
        defer { internalTransport = false }
        perform()
    }

    // Items are immutable for an authorization generation. Replacing media must acquire
    // a new coordinator ticket and lease; cleanup can only remove the old item.
    override func replaceCurrentItem(with item: AVPlayerItem?) {
        Self.onMain {
            if internalTransport { super.replaceCurrentItem(with: item); return }
            PlaybackCoordinator.shared.stop(player: self)
        }
    }

    @MainActor
    func installAuthorizedItem(_ item: AVPlayerItem) {
        guard !invalidated else { return }
        internalTransport = true
        super.replaceCurrentItem(with: item)
        internalTransport = false
    }

    @MainActor
    func stopAndClear() {
        guard !invalidated else { return }
        invalidated = true
        internalTransport = true
        super.pause()
        super.rate = 0
        super.cancelPendingPrerolls()
        super.currentItem?.cancelPendingSeeks()
        super.replaceCurrentItem(with: nil)
        internalTransport = false
        observers.removeAll()
    }
}
