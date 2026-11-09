import FamilyCore
import UIKit

/// Child-facing read-only status. Decisions and countdowns come from the settled
/// ledger; watching this page cannot issue a lease, credit or parental capability.
final class FamilyChildPlaybackStatusController: UIViewController {
    var onContinue: (() -> Void)?
    var onQuiz: (() -> Void)?
    var onReturn: (() -> Void)?
    var canRetry = false
    var quizActionIdentifier = "family-child-quiz"
    var prefersQuizFocus = false
    var isContextCurrent: () -> Bool = { false }
    private let heading = UILabel()
    private let countdown = UILabel()
    private let balance = UILabel()
    private let nextWindow = UILabel()
    private let detail = UILabel()
    private let action = UIButton(type: .system)
    private let back = UIButton(type: .system)
    private var refreshTask: Task<Void, Never>?
    private var availability: PlaybackAvailability?
    private var availabilityFetchedAt = Date()
    private var acting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.96)
        view.accessibilityIdentifier = "family-child-status"
        for label in [heading, countdown, balance, nextWindow, detail] {
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        heading.font = .systemFont(ofSize: 44, weight: .semibold)
        heading.text = "稍等一下"
        countdown.font = .monospacedDigitSystemFont(ofSize: 66, weight: .medium)
        countdown.accessibilityIdentifier = "family-child-rest"
        balance.font = .systemFont(ofSize: 32, weight: .medium)
        balance.accessibilityIdentifier = "family-child-remaining"
        nextWindow.font = .systemFont(ofSize: 30)
        nextWindow.accessibilityIdentifier = "family-child-next-window"
        detail.font = .systemFont(ofSize: 26)
        detail.textColor = .secondaryLabel
        detail.accessibilityIdentifier = "family-child-detail"
        detail.text = "正在确认剩余观看时间…"
        action.setTitle("继续观看", for: .normal)
        action.isEnabled = false
        action.addTarget(self, action: #selector(performAction), for: .primaryActionTriggered)
        back.setTitle("返回视频列表", for: .normal)
        back.accessibilityIdentifier = "family-child-return"
        back.addTarget(self, action: #selector(returnToSource), for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [action, back])
        buttons.axis = .horizontal
        buttons.spacing = 40
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [heading, countdown, balance, nextWindow, detail, buttons])
        stack.axis = .vertical
        stack.spacing = 26
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.72),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            buttons.heightAnchor.constraint(equalToConstant: 70)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await PlaybackCoordinator.shared.waitForPendingLedgerOperations()
            while !Task.isCancelled {
                guard let self, self.viewIfLoaded?.window != nil else { return }
                // The ledger API advances the authoritative clock, so polling it
                // every second wrote SQLite+Keychain every second. Query at most
                // every five seconds; tick the visible countdown locally.
                await self.refresh()
                for _ in 0..<5 {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard !Task.isCancelled, self.viewIfLoaded?.window != nil else { return }
                    await self.tickCountdown()
                }
            }
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }
    deinit { refreshTask?.cancel() }
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        prefersQuizFocus && action.isEnabled ? [action] : [back]
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { returnToSource(); return }
        super.pressesBegan(presses, with: event)
    }

    private func refresh() async {
        guard UIApplication.shared.applicationState == .active else { return }
        guard isContextCurrent() else { showUnavailable("观看安排已更新，请返回视频列表重新打开。"); return }
        do {
            let environment = FamilyEnvironment.shared
            guard !environment.isMaintaining, let ledger = environment.ledger else { throw LedgerError.closed }
            let state = try await ledger.playbackAvailability()
            guard !Task.isCancelled, isContextCurrent(), viewIfLoaded?.window != nil,
                  UIApplication.shared.applicationState == .active else { return }
            let firstRender = availability == nil
            availability = state
            availabilityFetchedAt = Date()
            render(state)
            if firstRender && prefersQuizFocus {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        } catch {
            guard !Task.isCancelled else { return }
            showUnavailable("暂时读不到观看安排，请让家长帮忙看看。")
        }
    }

    /// Update the rest countdown without touching the ledger. Asking again only
    /// when the local countdown reaches zero keeps the transition immediate.
    private func tickCountdown() async {
        guard let state = availability, state.restRemainingMs > 0 else { return }
        let elapsed = Int64(max(0, Date().timeIntervalSince(availabilityFetchedAt)) * 1_000)
        let remaining = max(0, state.restRemainingMs - elapsed)
        if remaining > 0 {
            countdown.text = "还要休息 \(Self.duration(remaining, roundUp: true))"
        } else if state.blockedReason == .resting {
            await refresh()
        }
    }

    private func render(_ state: PlaybackAvailability) {
        view.accessibilityValue = state.blockedReason.rawValue
        if [.clockUntrusted, .noViewers, .recoveryQuarantine].contains(state.blockedReason) {
            showUnavailable(state.blockedReason == .noViewers
                ? "还没有选择观看的孩子，请让家长帮忙。"
                : "观看记录需要家长确认，暂时不能继续。")
            return
        }
        balance.text = state.isDayExempt ? "今天由家长特别安排观看"
            : "今天还能看 \(Self.duration(state.availableRemainingMs, roundUp: false))"
        countdown.isHidden = state.restRemainingMs == 0
        countdown.text = state.restRemainingMs > 0 ? "还要休息 \(Self.duration(state.restRemainingMs, roundUp: true))" : nil
        var notes: [String] = []
        if state.restRemainingMs > 0 {
            heading.text = "休息一下吧"
            notes.append("离开屏幕，活动一下身体、看看远处。")
        } else if state.isScheduleBlocked {
            heading.text = "还没到观看时间"
        } else if state.availableRemainingMs == 0 {
            heading.text = "今天的观看时间用完了"
        } else if state.quizRequired {
            heading.text = "答完题，就可以继续啦"
        } else {
            heading.text = "可以继续观看了"
        }
        if state.isScheduleBlocked {
            nextWindow.isHidden = false
            nextWindow.text = state.nextScheduleOpeningWallMilliseconds.map { "下次观看时段：\(Self.opening($0, state: state))" }
                ?? "最近没有可观看的时段，请让家长帮忙。"
            notes.append("还要等到观看时段。")
        } else {
            nextWindow.isHidden = true
        }
        if !state.isDayExempt && state.availableRemainingMs == 0 {
            notes.append(state.canStartQuiz ? "可以先答题；能否获得奖励以家长安排为准。" : "今天没有剩余观看时间了，明天再来吧。")
        } else if state.quizRequired {
            notes.append(state.restRemainingMs > 0 ? "休息结束后，还需要先答题。" : "完成后会再检查剩余时间和观看时段。")
        } else if state.blockedReason == .ready {
            notes.append("这次最多连续看 \(Self.duration(state.continuousRemainingMs, roundUp: false))，然后要休息。")
        }
        detail.text = notes.joined(separator: "\n")
        if state.blockedReason == .ready && canRetry {
            action.setTitle("继续观看", for: .normal)
            action.accessibilityIdentifier = "family-child-continue"
            action.isEnabled = !acting
        } else if state.canStartQuiz {
            action.setTitle("去答题", for: .normal)
            action.accessibilityIdentifier = quizActionIdentifier
            action.isEnabled = !acting
        } else {
            action.setTitle(state.restRemainingMs > 0 ? "休息结束后再继续" : "暂时不能继续", for: .normal)
            action.accessibilityIdentifier = "family-child-wait"
            action.isEnabled = false
        }
    }

    private func showUnavailable(_ message: String) {
        availability = nil
        heading.text = "暂时不能继续"
        countdown.isHidden = true
        nextWindow.isHidden = true
        balance.text = "剩余时间暂时无法确认"
        detail.text = message
        action.isEnabled = false
        action.setTitle("暂时不能继续", for: .normal)
    }

    @objc private func performAction() {
        guard !acting else { return }
        acting = true
        action.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.acting = false }
            await self.refresh()
            guard self.isContextCurrent(), let state = self.availability else { return }
            if state.blockedReason == .ready && self.canRetry { self.onContinue?() }
            else if state.canStartQuiz { self.onQuiz?() }
        }
    }
    @objc private func returnToSource() { onReturn?() }

    private static func duration(_ ms: Int64, roundUp: Bool) -> String {
        let seconds = roundUp ? (max(0, ms) + 999) / 1_000 : max(0, ms) / 1_000
        if seconds == 0 && ms > 0 { return "不足 1 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
    private static func opening(_ milliseconds: Int64, state: PlaybackAvailability) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: state.timeZoneIdentifier) ?? .gmt
        let now = Date(timeIntervalSince1970: Double(state.calendarWallMilliseconds) / 1_000)
        let target = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        if calendar.isDate(now, inSameDayAs: target) { return "今天 " + formatter.string(from: target) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(tomorrow, inSameDayAs: target) {
            return "明天 " + formatter.string(from: target)
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: target)
    }
}
