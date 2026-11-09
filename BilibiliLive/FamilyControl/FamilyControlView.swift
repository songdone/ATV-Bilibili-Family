import FamilyCore
import SwiftUI
import UIKit

/// Uses the same split navigation and settings cells as the upstream personal page.
final class FamilyControlViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private enum Category: Int, CaseIterable {
        // 主要入口
        case overview, profiles, watch, quiz, reports
        // 更多管理
        case grants, backup, support

        var title: String {
            switch self {
            case .overview: return "家庭概览"
            case .profiles: return "孩子管理"
            case .watch: return "观看时间"
            case .quiz: return "学习奖励"
            case .reports: return "使用报告"
            case .grants: return "临时调整"
            case .backup: return "备份与恢复"
            case .support: return "关于与支持"
            }
        }
    }

    private let environment = FamilyEnvironment.shared
    private let sidebar = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let content = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "person.2.circle.fill"))
    private let heading = UILabel()
    private let subtitle = UILabel()
    private let privacyCover = UIView()
    private var navigations = [Category: UINavigationController]()
    private var currentNavigation: UINavigationController?
    private var selected = Category.overview
    private var menuAuthorization: ParentalAuthorization?
    private var parentSession: ParentalSession?
    private var sessionIdleTimer: Timer?
    private var sessionGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var privacyObservers = [NSObjectProtocol]()
    private var isAuthorizing = false
    private var lastSessionValidation = Date.distantPast
    private var unlocked: Bool { parentSession != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        heading.text = "家长控制"
        heading.font = .systemFont(ofSize: 40, weight: .semibold)
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 2
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        let header = UIView()
        [icon, heading, subtitle].forEach { header.addSubview($0) }
        icon.snp.makeConstraints { $0.leading.top.equalToSuperview(); $0.width.height.equalTo(78) }
        heading.snp.makeConstraints { $0.leading.equalTo(icon.snp.trailing).offset(20); $0.top.equalToSuperview().offset(3); $0.trailing.equalToSuperview() }
        subtitle.snp.makeConstraints { $0.leading.equalTo(heading); $0.top.equalTo(heading.snp.bottom).offset(12); $0.trailing.equalToSuperview() }
        let rail = UIView()
        view.addSubview(rail)
        view.addSubview(content)
        rail.addSubview(header)
        rail.addSubview(sidebar)
        rail.snp.makeConstraints {
            $0.leading.top.equalTo(view.safeAreaLayoutGuide).offset(28)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
            $0.width.equalTo(view.snp.width).multipliedBy(0.25)
        }
        header.snp.makeConstraints { $0.leading.trailing.top.equalToSuperview(); $0.height.equalTo(145) }
        sidebar.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.top.equalTo(header.snp.bottom).offset(24) }
        content.snp.makeConstraints {
            $0.leading.equalTo(rail.snp.trailing).offset(56)
            $0.trailing.equalTo(view.safeAreaLayoutGuide).offset(-36)
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(10)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
        }
        sidebar.backgroundColor = .clear
        sidebar.clipsToBounds = false
        sidebar.remembersLastFocusedIndexPath = true
        sidebar.register(BLSettingLineCollectionViewCell.self, forCellWithReuseIdentifier: "category")
        sidebar.delegate = self
        sidebar.dataSource = self
        privacyCover.backgroundColor = .black
        view.addSubview(privacyCover)
        privacyCover.snp.makeConstraints { $0.edges.equalToSuperview() }
        privacyCover.isHidden = true
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            privacyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockForBackground() }
            })
        }
        privacyObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.privacyCover.isHidden = true }
        })
        privacyObservers.append(NotificationCenter.default.addObserver(forName: .familySettingsReturnToOverview, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let navigation = note.object as? UINavigationController,
                      self.currentNavigation === navigation else { return }
                self.navigations.removeValue(forKey: self.selected)
                self.select(.overview)
                self.setNeedsFocusUpdate(); self.updateFocusIfNeeded()
            }
        })
        privacyObservers.append(NotificationCenter.default.addObserver(forName: .familySettingsNavigate, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // First-run guidance rows land on the real target page.
                guard let self, self.unlocked, let raw = note.object as? Int,
                      let category = Category(rawValue: raw) else { return }
                self.select(category)
            }
        })
        privacyObservers.append(NotificationCenter.default.addObserver(forName: .familySettingsInteraction, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let navigation = note.object as? UINavigationController,
                      self.currentNavigation === navigation else { return }
                self.refreshSessionActivity(force: true)
            }
        })
        showLockedPage()
        Task { await environment.refresh() }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.checkAuthorization()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = sidebar.collectionViewLayout as? UICollectionViewFlowLayout {
            let size = CGSize(width: max(220, view.bounds.width * 0.25 - 20), height: 60)
            if layout.itemSize != size { layout.itemSize = size; layout.minimumLineSpacing = 14; layout.invalidateLayout() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            refreshTask?.cancel()
            Task { await environment.auth.revokeAuthorizations() }
        }
    }

    deinit {
        refreshTask?.cancel()
        privacyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.previouslyFocusedView !== context.nextFocusedView, context.nextFocusedView != nil {
            refreshSessionActivity()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !unlocked, let currentNavigation { return [currentNavigation] }
        if unlocked, let index = Category.allCases.firstIndex(of: selected),
           let cell = sidebar.cellForItem(at: IndexPath(item: index, section: 0)) { return [cell] }
        return [sidebar]
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        unlocked ? Category.allCases.count + 2 : 2
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "category", for: indexPath) as! BLSettingLineCollectionViewCell
        let title: String
        if unlocked {
            title = indexPath.item < Category.allCases.count ? Category.allCases[indexPath.item].title
                : indexPath.item == Category.allCases.count ? "锁定家长中心" : "返回客户端"
        } else { title = indexPath.item == 0 ? "家长验证" : "返回客户端" }
        cell.titleLabel.text = title
        cell.titleLabel.font = .systemFont(ofSize: 32)
        cell.accessibilityIdentifier = "family-nav-" + title
        cell.isSelected = unlocked && indexPath.item == Category.allCases.firstIndex(of: selected)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if !unlocked {
            if indexPath.item == 0 { unlock() } else { dismiss(animated: true) }
            return
        }
        if indexPath.item == Category.allCases.count { lock(); return }
        if indexPath.item > Category.allCases.count { dismiss(animated: true); return }
        refreshSessionActivity()
        select(Category.allCases[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard unlocked, let path = context.nextFocusedIndexPath, path.item < Category.allCases.count else { return }
        select(Category.allCases[path.item])
    }

    private var authorize: FamilyAuthorize {
        // Ordinary settings use the parent session; no repeated PIN dialogs.
        // A missing or expired session falls back to one fresh PIN sheet.
        { [weak self] context, action in
            guard let self else { return }
            let generation = self.sessionGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let session = self.parentSession,
                   let token = await self.environment.auth.sessionOperationToken(session, context: context) {
                    guard generation == self.sessionGeneration else { return }
                    self.scheduleSessionExpiry(after: ParentalAuth.sessionIdleLifetime)
                    action(token)
                    return
                }
                guard generation == self.sessionGeneration else { return }
                self.parentSession = nil
                self.authenticate(context, action: action)
            }
        }
    }

    /// High-risk operations (bonus time, restore, mode off, delete child) always
    /// require a fresh PIN even when the parent session is still valid.
    private var highRiskAuthorize: FamilyAuthorize {
        { [weak self] context, action in self?.authenticate(context, action: action) }
    }

    private func authenticate(_ context: ParentalAuthContext, action: @escaping (ParentalAuthorization) -> Void) {
        guard !isAuthorizing, view.window != nil else { return }
        isAuthorizing = true
        let generation = sessionGeneration
        let screen = FamilyPINViewController(auth: environment.auth, context: context)
        screen.onCancel = { [weak self] in self?.isAuthorizing = false }
        screen.onAuthorized = { [weak self, weak screen] token, session in
            guard let self else { return }
            screen?.dismiss(animated: true) { [weak self] in
                guard let self, generation == self.sessionGeneration else { return }
                self.isAuthorizing = false
                self.menuAuthorization = token
                // The PIN controller already established the 10-minute session
                // while the PIN was still in scope; start its idle timer now.
                self.parentSession = session
                self.scheduleSessionExpiry(after: ParentalAuth.sessionIdleLifetime)
                action(token)
                self.updateHeader()
            }
        }
        var presenter: UIViewController = currentNavigation?.topViewController ?? self
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(screen, animated: true)
    }

    private func unlock() {
        authenticate(.manageProfiles) { [weak self] _ in
            guard let self else { return }
            self.sidebar.reloadData()
            self.select(.overview)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    private func checkAuthorization() async {
        // Passive poll: must NOT refresh the session's idle window, otherwise the
        // 10-minute no-operation lockout could never trigger.
        guard !isAuthorizing, let session = parentSession else { return }
        let generation = sessionGeneration
        do {
            let remaining = try await environment.auth.peekSession(session)
            guard generation == sessionGeneration, !isAuthorizing,
                  parentSession?.credential == session.credential else { return }
            scheduleSessionExpiry(after: remaining)
        } catch {
            guard generation == sessionGeneration, !isAuthorizing,
                  parentSession?.credential == session.credential else { return }
            lock()
        }
    }

    /// Remote activity and visible settings pages refresh the 10-minute window.
    /// Focus traversal can be rapid; only hit the secure store a few times a
    /// second at most, while explicit settings interactions stay immediate.
    private func refreshSessionActivity(force: Bool = false) {
        guard let session = parentSession else { return }
        if !force, Date().timeIntervalSince(lastSessionValidation) < 2 { return }
        lastSessionValidation = Date()
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let valid = (try? await self.environment.auth.validateSession(session)) != nil
            guard generation == self.sessionGeneration else { return }
            if valid { self.scheduleSessionExpiry(after: ParentalAuth.sessionIdleLifetime) }
            else { self.lock() }
        }
    }

    private func scheduleSessionExpiry(after seconds: TimeInterval) {
        sessionIdleTimer?.invalidate()
        sessionIdleTimer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    private func lockForBackground() {
        privacyCover.isHidden = false
        // UIKit presentations can sit above the root cover, so hide them immediately.
        var presented = currentNavigation?.presentedViewController ?? presentedViewController
        while let current = presented { current.view.isHidden = true; presented = current.presentedViewController }
        lock()
        Task { await environment.auth.revokeAuthorizations() }
    }

    private func lock() {
        sessionGeneration = UUID()
        menuAuthorization = nil
        let endedSession = parentSession
        parentSession = nil
        if let endedSession {
            let auth = environment.auth
            Task { await auth.endSession(endedSession) }
        }
        sessionIdleTimer?.invalidate()
        sessionIdleTimer = nil
        isAuthorizing = false
        if let modal = currentNavigation?.presentedViewController ?? currentNavigation?.topViewController?.presentedViewController {
            modal.dismiss(animated: false)
        }
        if let modal = presentedViewController { modal.dismiss(animated: false) }
        navigations.removeAll()
        showLockedPage()
        sidebar.reloadData()
    }

    private func showLockedPage() {
        subtitle.text = "PIN 保护 · 家庭设置"
        let page = FamilyLockedPage()
        page.title = "家长验证"
        page.onUnlock = { [weak self] in self?.unlock() }
        replaceContent(makeNavigation(page))
    }

    private func select(_ category: Category) {
        guard unlocked else { return }
        selected = category
        let navigation: UINavigationController
        if let existing = navigations[category] { navigation = existing }
        else {
            let page: UIViewController
            let changed: () -> Void = { [weak self] in self?.updateHeader() }
            switch category {
            case .overview:
                page = FamilyOverviewPage(environment: environment, authorize: authorize,
                    highRiskAuthorize: highRiskAuthorize, onChanged: changed)
            case .profiles:
                page = FamilyProfilesPage(environment: environment, authorize: authorize,
                    highRiskAuthorize: highRiskAuthorize, onChanged: changed)
            case .watch:
                page = FamilyNativeRulesEditor(environment: environment, section: .watch, authorize: authorize, onSaved: changed)
            case .quiz:
                page = FamilyNativeRulesEditor(environment: environment, section: .quiz, authorize: authorize, onSaved: changed)
            case .reports:
                page = FamilyNativeReportsPage(environment: environment, authorize: authorize,
                    validateAccess: { [weak self] in
                        guard let self, let session = self.parentSession,
                              UIApplication.shared.applicationState == .active else {
                            throw ParentalAuthError.invalidAuthorization
                        }
                        let generation = self.sessionGeneration
                        _ = try await self.environment.auth.peekSession(session)
                        guard generation == self.sessionGeneration,
                              self.parentSession?.credential == session.credential else {
                            throw ParentalAuthError.invalidAuthorization
                        }
                    })
            case .grants:
                page = FamilyMaintenancePage(environment: environment, kind: .grants, authorize: highRiskAuthorize)
            case .backup:
                page = FamilyMaintenancePage(environment: environment, kind: .backup,
                    authorize: highRiskAuthorize, clockAuthorize: authorize)
            case .support:
                page = FamilyNativeSupportPage(session: parentSession ?? .placeholder)
            }
            page.title = category.title
            navigation = makeNavigation(page)
            navigations[category] = navigation
        }
        if currentNavigation !== navigation { replaceContent(navigation) }
        sidebar.selectItem(at: IndexPath(item: Category.allCases.firstIndex(of: category)!, section: 0), animated: false, scrollPosition: [])
        updateHeader()
    }

    private func makeNavigation(_ root: UIViewController) -> UINavigationController {
        let controller = UINavigationController(rootViewController: root)
        controller.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: 40, weight: .medium)]
        controller.navigationBar.isTranslucent = true
        controller.navigationBar.setBackgroundImage(UIImage(), for: .default)
        controller.navigationBar.shadowImage = UIImage()
        controller.navigationBar.tintColor = .label
        controller.view.backgroundColor = .clear
        return controller
    }

    private func replaceContent(_ controller: UINavigationController) {
        currentNavigation?.willMove(toParent: nil)
        currentNavigation?.view.removeFromSuperview()
        currentNavigation?.removeFromParent()
        currentNavigation = controller
        addChild(controller)
        content.addSubview(controller.view)
        controller.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        controller.didMove(toParent: self)
    }

    private func updateHeader() {
        guard unlocked else { return }
        let mode = environment.childModeActive ? "儿童模式" : "原客户端模式"
        let names = environment.snapshot.map { state in
            state.profiles.filter { state.activeViewerIDs.contains($0.id) }.map(\.displayName).joined(separator: "、")
        } ?? ""
        subtitle.text = names.isEmpty ? mode : "\(mode)\n\(names)"
    }
}

/// One parent-authorized confirmation surface for overview, backup and playback.
/// It describes the actual clock evidence without exposing account or child data.
@MainActor
enum FamilyClockRecoveryPresenter {
    static let quarantineMessage = "备份恢复后的余额仍在安全隔离中。确认时间只恢复计量，不解冻剩余额度；备份恢复需独立处理，不能通过此入口补发或解锁额度。"

    static func currentDateTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss zzz"
        return formatter.string(from: Date())
    }

    static func status(for state: LedgerSnapshot) -> String {
        if !state.clockIsTrusted { return "需要家长确认" }
        return state.recoveryQuarantineActive ? "计量正常 · 备份余额仍隔离" : "正常"
    }

    static func reason(for state: LedgerSnapshot) -> String {
        switch state.clockRecoveryReason {
        case .legacyContinuityUnverifiable: return "应用升级后，旧计时记录需要一次家长确认"
        case .sourceChanged: return "计时方式已更新，需要确认当前时间"
        case .bootChanged: return "Apple TV 已重新启动，需要确认当前时间"
        case .bootIdentityUnavailable: return "暂时无法确认 Apple TV 是否重启过"
        case .wallDrift: return "设备日期时间与连续计时不一致"
        case .monotonicRollback: return "连续计时发生回退"
        case .invalidSample: return "当前设备时间读数无效"
        case .restoredBackup: return "已恢复备份，需确认时间且余额仍隔离"
        case nil: return state.clockIsTrusted ? "当前时间计量正常" : "时间连续性尚未验证"
        @unknown default: return "时间连续性尚未验证"
        }
    }

    static func present(from presenter: UIViewController, environment: FamilyEnvironment,
                        authorize: @escaping FamilyAuthorize,
                        onCancelled: @escaping () -> Void = {},
                        onConfirmed: @escaping (LedgerSnapshot) -> Void) {
        authorize(.recovery) { [weak presenter] _ in
            Task { @MainActor [weak presenter] in
                await environment.refresh()
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      UIApplication.shared.applicationState == .active else { return }
                guard let state = environment.snapshot else {
                    showFailure(from: presenter, message: "家庭账本不可用，无法确认时间。原有数据和限制没有被重置。")
                    return
                }
                let quarantine = state.recoveryQuarantineActive ? "\n\n" + quarantineMessage : ""
                let alert = UIAlertController(title: "确认设备时间？",
                    message: "\(reason(for: state))\n设备显示：\(currentDateTime())\n\n请核对上面的时间。确认不会清空观看记录、重置额度或更改孩子与规则；无法核实的播放预留和未完成休息仍保留。确认后可重新尝试播放。\(quarantine)",
                    preferredStyle: .alert)
                alert.view.accessibilityIdentifier = "family-clock-confirmation"
                alert.view.accessibilityValue = state.clockRecoveryReason?.rawValue ?? "none"
                let confirm = UIAlertAction(title: "确认当前时间", style: .default) { [weak presenter] _ in
                    // Mint a fresh operation token at the explicit confirmation, not
                    // when the parent started reading this explanation.
                    authorize(.recovery) { [weak presenter] token in
                        Task { @MainActor [weak presenter] in
                            guard let presenter, presenter.viewIfLoaded?.window != nil,
                                  UIApplication.shared.applicationState == .active else { return }
                            do {
                                let result = try await environment.confirmClock(authorization: token)
                                guard presenter.viewIfLoaded?.window != nil,
                                      UIApplication.shared.applicationState == .active else { return }
                                onConfirmed(result)
                            } catch {
                                showFailure(from: presenter, message: errorMessage(for: error))
                            }
                        }
                    }
                }
                confirm.accessibilityIdentifier = "family-clock-confirm"
                alert.addAction(confirm)
                alert.preferredAction = confirm
                let cancel = UIAlertAction(title: "取消", style: .cancel) { _ in onCancelled() }
                cancel.accessibilityIdentifier = "family-clock-cancel"
                alert.addAction(cancel)
                guard presenter.presentedViewController == nil else { return }
                presenter.present(alert, animated: true)
            }
        }
    }

    static func resultMessage(for state: LedgerSnapshot) -> String {
        if !state.clockIsTrusted {
            return "设备时间仍无法验证：\(reason(for: state))。儿童播放保持锁定，原有额度和记录均保留。"
                + (state.recoveryQuarantineActive ? "\n\n" + quarantineMessage : "")
        }
        if state.recoveryQuarantineActive { return "时间计量已确认。\n\n" + quarantineMessage }
        return "时间已确认，观看记录、额度和规则都已保留。现在可以重新尝试播放；原有的限时、休息和答题要求仍然有效。"
    }

    static func showResult(from presenter: UIViewController, state: LedgerSnapshot) {
        let alert = UIAlertController(title: state.clockIsTrusted ? "时间确认结果" : "时间仍需确认",
            message: resultMessage(for: state), preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "family-clock-result"
        alert.view.accessibilityValue = state.clockIsTrusted
            ? (state.recoveryQuarantineActive ? "quarantined" : "trusted") : "untrusted"
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        presentAfterAlertDismissal(alert, from: presenter)
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case ParentalAuthError.authorizationExpired, ParentalAuthError.invalidAuthorization:
            return "家长授权已结束，请重新验证后确认。额度和观看记录未被重置。"
        case LedgerError.clockUntrusted:
            return "当前时间仍无法验证，儿童播放保持锁定。"
        default:
            return "本次时间确认未完成，原有额度、档案和记录不会被重置。请稍后重试。"
        }
    }

    private static func showFailure(from presenter: UIViewController, message: String) {
        let alert = UIAlertController(title: "时间确认未完成", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "family-clock-error"
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        presentAfterAlertDismissal(alert, from: presenter)
    }

    static func presentAfterAlertDismissal(_ alert: UIAlertController, from presenter: UIViewController) {
        guard presenter.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
        if let previous = presenter.presentedViewController as? UIAlertController {
            previous.dismiss(animated: true) { [weak presenter] in
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      UIApplication.shared.applicationState == .active else { return }
                presenter.present(alert, animated: true)
            }
        } else if presenter.presentedViewController == nil {
            presenter.present(alert, animated: true)
        }
    }
}

private final class FamilyLockedPage: FamilySettingsPage {
    var onUnlock: (() -> Void)?
    override func reloadSettings() {
        render([
            SectionModel(title: "家长专属设置") {
                row("家长验证", "首次使用会先设置六位 PIN") { [weak self] in self?.onUnlock?() }
            },
            SectionModel(title: "隐私保护") {
                row("观看规则、孩子档案与学习记录", "验证后查看")
                row("首次使用", "创建六位 PIN")
            }
        ])
    }
}

private final class FamilyOverviewPage: FamilySettingsPage {
    private var environment = FamilyEnvironment.shared
    private var authorize: FamilyAuthorize = { _, _ in }
    private var highRiskAuthorize: FamilyAuthorize = { _, _ in }
    private var onChanged: () -> Void = {}
    convenience init(environment: FamilyEnvironment, authorize: @escaping FamilyAuthorize,
                     highRiskAuthorize: @escaping FamilyAuthorize, onChanged: @escaping () -> Void) {
        self.init()
        self.environment = environment; self.authorize = authorize
        self.highRiskAuthorize = highRiskAuthorize; self.onChanged = onChanged
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await environment.refresh(); reloadSettings(); onChanged() }
    }
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        let titles = dataSource?.snapshot().itemIdentifiers ?? []
        if let first = titles.first, let path = dataSource.indexPath(for: first),
           let cell = collectionView.cellForItem(at: path) { return [cell] }
        return super.preferredFocusEnvironments
    }

    override func reloadSettings() {
        guard let state = environment.snapshot else {
            if environment.ledgerNeedsReset {
                render([SectionModel(title: "家庭账本缺失") {
                    row("账本状态", "需要家长处理")
                    row("账本缺失说明", "查看说明") { [weak self] in
                        self?.showMessage(title: "家庭账本缺失",
                            message: "本机找不到家庭账本文件。重装应用会删除本机账本，历史记录无法自动恢复；之前导出的备份文件会保留。")
                    }
                    row("先尝试恢复备份", "备份与恢复") { [weak self] in
                        NotificationCenter.default.post(name: .familySettingsNavigate,
                            object: FamilyGuideTarget.backup.rawValue)
                    }
                    row("创建新账本", "需要 PIN") { [weak self] in self?.confirmCreateNewLedger() }
                }])
            } else {
                render([SectionModel(title: "家庭数据") { row("账本状态", "暂不可用") }])
            }
            return
        }
        var sections = [SectionModel]()
        if state.profiles.isEmpty {
            // First-run guidance: every step navigates to its real page, and the
            // final row starts child mode right here (session PIN already valid).
            sections.append(SectionModel(title: "开始使用", items: [
                row("第 1 步 · 添加孩子", "填写昵称和年级，随时可改") { [weak self] in
                    NotificationCenter.default.post(name: .familySettingsNavigate,
                        object: FamilyGuideTarget.profiles.rawValue)
                },
                row("第 2 步 · 设置观看时间", "已有默认值，改哪项都立即生效") { [weak self] in
                    NotificationCenter.default.post(name: .familySettingsNavigate,
                        object: FamilyGuideTarget.watch.rawValue)
                },
                row("第 3 步 · 可选开启答题奖励", "不开启也能正常限制时间") { [weak self] in
                    NotificationCenter.default.post(name: .familySettingsNavigate,
                        object: FamilyGuideTarget.quiz.rawValue)
                },
                row("开启儿童模式", "完成上面步骤后即可开启") { [weak self] in self?.switchMode() },
            ]))
        } else {
            let mode = environment.childModeActive ? "已开启" : "未开启"
            let viewers = state.profiles.filter { state.activeViewerIDs.contains($0.id) }
            let names = viewers.map(\.displayName).joined(separator: "、")
            var modeRows = [row("儿童模式", mode) { [weak self] in self?.switchMode() }]
            if viewers.isEmpty {
                modeRows.append(row("选择要观看的孩子", "必须先选择孩子才能开启") { [weak self] in
                    NotificationCenter.default.post(name: .familySettingsNavigate,
                        object: FamilyGuideTarget.profiles.rawValue)
                })
            } else {
                for viewer in viewers where state.profiles.count > 1 {
                    // Multi-child homes switch the current viewer from the overview.
                    let others = state.profiles.filter { $0.id != viewer.id && $0.isEnabled }
                    guard !others.isEmpty else { continue }
                    modeRows.append(row("切换当前观看者", "换成 \(others.map(\.displayName).joined(separator: "、"))") { [weak self] in
                        self?.switchViewer(from: viewer, others: others)
                    })
                    break
                }
                modeRows.append(row("当前观看者", names))
            }
            sections.append(SectionModel(title: "观看模式", items: modeRows))
        }
        let familyRemaining = max(0, state.configuration.dailyLimitMilliseconds + state.familyBonusMilliseconds
            - state.familyActualMilliseconds - state.familyFrozenMilliseconds)
        sections.append(SectionModel(title: "家庭共享时间 · 今天") {
            row("剩余可用", state.dayExemptionActive ? "家长今日豁免" : Self.duration(familyRemaining))
            row("今天已观看", Self.duration(max(0, state.familyActualMilliseconds - state.familyCarriedActualMilliseconds)))
            if state.familyCarriedActualMilliseconds > 0 {
                row("历史结转已用（仍计入今天）", Self.duration(state.familyCarriedActualMilliseconds)) { [weak self] in
                    self?.showMessage(title: "历史结转已用", message: "这部分是之前已使用的时间，在本日额度中继续扣除，防止恢复时多发时间；历史报告仍保留原日期，不重复算作今天观看。下一个正常午夜按规则开始新一天。")
                }
            }
            row("连续观看", "\(Self.duration(state.continuousActualMilliseconds)) / \(Self.duration(state.configuration.continuousLimitMilliseconds))")
            row("休息倒计时", state.remainingRestMilliseconds > 0 ? Self.duration(state.remainingRestMilliseconds) : "无需休息")
            if state.familyFrozenMilliseconds > 0 { row("安全冻结预留", Self.duration(state.familyFrozenMilliseconds)) }
        })
        for (index, profile) in state.profiles.filter({ state.activeViewerIDs.contains($0.id) }).enumerated() {
            sections.append(SectionModel(title: "\(profile.displayName) · 个人使用") {
                row("个人已观看 · \(index + 1)", Self.duration(max(0,
                    state.personalActualMilliseconds[profile.id, default: 0] - state.personalCarriedActualMilliseconds[profile.id, default: 0])))
                row("个人基础额度 · \(index + 1)", Self.duration(profile.dailyLimitMilliseconds))
            })
        }
        sections.append(SectionModel(title: "状态说明") {
            row("时间校验", FamilyClockRecoveryPresenter.status(for: state))
            if !state.clockIsTrusted {
                row("时间异常原因", FamilyClockRecoveryPresenter.reason(for: state))
                row("当前设备日期时间", FamilyClockRecoveryPresenter.currentDateTime())
                row("确认设备时间", "保留额度、档案和记录") { [weak self] in
                    guard let self else { return }
                    FamilyClockRecoveryPresenter.present(from: self, environment: self.environment,
                        authorize: self.authorize) { [weak self] state in
                        guard let self else { return }
                        self.reloadSettings(); self.onChanged()
                        FamilyClockRecoveryPresenter.showResult(from: self, state: state)
                    }
                }
            }
            if state.recoveryQuarantineActive {
                row("备份余额隔离", "确认时间不会解除") { [weak self] in
                    self?.showMessage(title: "备份恢复余额仍隔离", message: FamilyClockRecoveryPresenter.quarantineMessage)
                }
            }
            row("关于当前开发版本", "查看说明") { [weak self] in
                self?.showMessage(title: "当前版本", message: "部分真机验收仍在进行。原客户端功能默认保留；开启儿童模式后才应用家庭限制。奖励、冻结预留与实际观看分开记录。")
            }
        })
        render(sections)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        let identifier: String?
        switch dataSource.itemIdentifier(for: indexPath)?.title {
        case "时间校验": identifier = "family-clock-state"
        case "时间异常原因": identifier = "family-clock-reason"
        case "当前设备日期时间": identifier = "family-clock-current-time"
        case "确认设备时间": identifier = "family-clock-recovery-entry"
        case "备份余额隔离": identifier = "family-clock-quarantine"
        default: identifier = nil
        }
        cell.accessibilityIdentifier = identifier
    }

    private func switchMode() {
        let active = !environment.childModeActive
        let alert = UIAlertController(title: active ? "开启儿童模式？" : "关闭儿童模式？",
            message: active
                ? "开启后，孩子的播放会按家长设置的时间、休息和答题规则执行；不会额外过滤视频列表内容。"
                : "关闭会停止当前播放并恢复原客户端全部功能，不会清空个人与家庭账本。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续", style: .default) { [weak self] _ in
            guard let self else { return }
            // Enabling protection uses the already unlocked parent session;
            // disabling protection still requires a fresh PIN.
            let request: FamilyAuthorize = active ? self.authorize : self.highRiskAuthorize
            request(.temporaryOverride) { [weak self] token in
                guard let self else { return }
                Task {
                    do { try await self.environment.setChildMode(active, authorization: token); self.reloadSettings(); self.onChanged() }
                    catch { self.showError(error) }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
    /// Multi-child homes switch the active viewer straight from the overview;
    /// ordinary session authorization suffices (same level as the profile page).
    private func switchViewer(from current: ViewerProfile, others: [ViewerProfile]) {
        let alert = UIAlertController(title: "切换当前观看者",
            message: "把时间账本切换到 \(others.map(\.displayName).joined(separator: "、"))？\(current.displayName) 的历史记录会保留。",
            preferredStyle: .alert)
        for other in others {
            alert.addAction(UIAlertAction(title: other.displayName, style: .default) { [weak self] _ in
                guard let self else { return }
                self.authorize(.manageSession) { [weak self] token in
                    guard let self else { return }
                    Task {
                        do {
                            guard let ledger = self.environment.ledger else { throw LedgerError.closed }
                            try await ledger.selectViewers([other.id], credential: token.credential)
                            await self.environment.refresh()
                            self.reloadSettings(); self.onChanged()
                        } catch {
                            self.showError(error)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
    private func confirmCreateNewLedger() {
        let alert = UIAlertController(title: "创建新账本？",
            message: "本机账本文件已丢失（例如重装应用）。创建后会从空白状态开始：孩子、规则和本机历史都会清空；之前导出的备份文件会保留。此操作需要家长 PIN。",
            preferredStyle: .alert)
        let cancel = UIAlertAction(title: "取消", style: .cancel)
        alert.addAction(UIAlertAction(title: "创建新账本", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.highRiskAuthorize(.recovery) { [weak self] token in
                guard let self else { return }
                Task {
                    do {
                        try await self.environment.resetMissingLedger(authorization: token)
                        self.reloadSettings()
                        self.onChanged()
                    } catch { self.showError(error) }
                }
            }
        })
        alert.addAction(cancel)
        alert.preferredAction = cancel
        present(alert, animated: true)
    }

    static func duration(_ ms: Int64) -> String { "\(max(0, ms) / 60_000) 分 \(max(0, ms) % 60_000 / 1_000) 秒" }
}

private final class FamilyProfilesPage: FamilySettingsPage {
    private var environment = FamilyEnvironment.shared
    private var authorize: FamilyAuthorize = { _, _ in }
    private var highRiskAuthorize: FamilyAuthorize = { _, _ in }
    private var onChanged: () -> Void = {}
    convenience init(environment: FamilyEnvironment, authorize: @escaping FamilyAuthorize,
                     highRiskAuthorize: @escaping FamilyAuthorize, onChanged: @escaping () -> Void) {
        self.init(); self.environment = environment; self.authorize = authorize
        self.highRiskAuthorize = highRiskAuthorize; self.onChanged = onChanged
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await environment.refresh(); reloadSettings() }
    }
    override func reloadSettings() {
        let profiles = environment.snapshot?.profiles ?? []
        let items = profiles.enumerated().map { index, profile in
            row("\(profile.displayName) · \(index + 1)", "\(profile.curriculum.grade) 年级  \(environment.snapshot?.activeViewerIDs.contains(profile.id) == true ? "✓" : "›")") { [weak self] in
                guard let self else { return }
                let page = FamilyProfileDetailPage()
                page.environment = self.environment; page.profile = profile
                page.authorize = self.authorize; page.highRiskAuthorize = self.highRiskAuthorize
                page.onChanged = self.onChanged
                page.title = profile.displayName
                self.navigationController?.pushViewController(page, animated: true)
            }
        }
        let profileRows = profiles.isEmpty ? [row("尚未添加孩子", "点击添加") { [weak self] in self?.addChild() }] : items
        render([SectionModel(title: "孩子管理", items: profileRows), SectionModel(title: "管理") {
            row("添加孩子", "＋") { [weak self] in self?.addChild() }
            row("多人观看参与者选择", "\(environment.snapshot?.activeViewerIDs.count ?? 0) 位") { [weak self] in
                guard let self else { return }
                self.navigationController?.pushViewController(FamilyNativeParticipantsEditor(environment: self.environment,
                    authorize: self.authorize, onSaved: self.onChanged), animated: true)
            }
        }])
    }

    private func addChild() {
        navigationController?.pushViewController(FamilyNativeProfileEditor(environment: environment, profile: nil,
            authorize: authorize, highRiskAuthorize: highRiskAuthorize, onSaved: onChanged), animated: true)
    }
}

private final class FamilyProfileDetailPage: FamilySettingsPage {
    var environment = FamilyEnvironment.shared
    var profile: ViewerProfile?
    var authorize: FamilyAuthorize = { _, _ in }
    var highRiskAuthorize: FamilyAuthorize = { _, _ in }
    var onChanged: () -> Void = {}
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [weak self] in
            guard let self, let id = self.profile?.id else { return }
            do {
                let state = try await self.environment.refreshVerified()
                self.profile = state.profiles.first { $0.id == id }
                self.reloadSettings()
            } catch { self.showError(error) }
        }
    }
    override func reloadSettings() {
        guard let profile else {
            render([SectionModel(title: "档案") { row("该孩子档案已删除", "返回孩子管理") }])
            return
        }
        render([SectionModel(title: "档案") {
            row("昵称", profile.displayName)
            row("年级", "\(profile.curriculum.grade) 年级")
            row("个人每日额度", FamilyOverviewPage.duration(profile.dailyLimitMilliseconds))
        }, SectionModel(title: "操作") {
            if environment.snapshot?.activeViewerIDs.contains(profile.id) == true {
                row("当前观看者", "✓")
            } else {
                row("切换为当前观看者", "会话有效时免 PIN") { [weak self] in
                    self?.authorize(.manageSession) { [weak self] token in
                        guard let self else { return }
                        Task {
                            do {
                                guard let ledger = self.environment.ledger else { throw LedgerError.closed }
                                try await ledger.selectViewers([profile.id], credential: token.credential)
                                await self.environment.refresh(); self.onChanged()
                                self.navigationController?.popViewController(animated: true)
                            } catch { self.showError(error) }
                        }
                    }
                }
            }
            row("编辑档案", "›") { [weak self] in
                guard let self else { return }
                self.navigationController?.pushViewController(FamilyNativeProfileEditor(environment: self.environment,
                    profile: profile, authorize: self.authorize, highRiskAuthorize: self.highRiskAuthorize,
                    onSaved: self.onChanged), animated: true)
            }
        }])
    }
}

private final class FamilyMaintenancePage: FamilySettingsPage {
    enum Kind { case grants, backup }
    private var environment = FamilyEnvironment.shared
    private var kind = Kind.grants
    private var authorize: FamilyAuthorize = { _, _ in }
    private var clockAuthorize: FamilyAuthorize = { _, _ in }
    convenience init(environment: FamilyEnvironment, kind: Kind, authorize: @escaping FamilyAuthorize,
                     clockAuthorize: FamilyAuthorize? = nil) {
        self.init(); self.environment = environment; self.kind = kind; self.authorize = authorize
        self.clockAuthorize = clockAuthorize ?? authorize
    }
    override func reloadSettings() {
        if kind == .grants {
            render([SectionModel(title: "仅当天有效 · 不重置账本") {
                row("增加观看时间 · 15 分钟", "需要 PIN") { [weak self] in self?.grant(minutes: 15) }
                row("增加观看时间 · 30 分钟", "需要 PIN") { [weak self] in self?.grant(minutes: 30) }
                row("当天解除限制", "保留强制休息") { [weak self] in self?.perform(.temporaryOverride, title: "当天解除限制", message: "仅对当前观看成员有效，连续观看和强制休息不变。") { env, token in
                    guard let ledger = env.ledger else { throw LedgerError.closed }
                    _ = try await ledger.grantDayExemption(credential: token.credential)
                } }
                row("今天跳过答题", "需要 PIN") { [weak self] in self?.perform(.temporaryOverride, title: "今天跳过答题", message: "不增加观看额度，不跳过休息。") { env, token in
                    guard let ledger = env.ledger else { throw LedgerError.closed }
                    _ = try await ledger.grantQuizSkip(credential: token.credential)
                } }
            }])
        } else {
            let latest = environment.latestBackupDate()
            let latestText = latest.map(Self.backupDateText) ?? "暂无可用备份"
            render([SectionModel(title: "时间与数据恢复") {
                row("确认家庭时间计量", "不解除备份余额隔离") { [weak self] in
                    guard let self else { return }
                    FamilyClockRecoveryPresenter.present(from: self, environment: self.environment,
                        authorize: self.clockAuthorize) { [weak self] state in
                        guard let self else { return }
                        self.reloadSettings()
                        FamilyClockRecoveryPresenter.showResult(from: self, state: state)
                    }
                }
                row("导出加密备份", "保存在本机") { [weak self] in self?.exportBackup() }
                row("最近备份", latestText) { [weak self] in
                    guard let self else { return }
                    self.showMessage(title: "备份状态", message: self.latestBackupMessage())
                }
                row("从最近备份恢复", latest == nil ? "暂无可用备份" : "需要 PIN") { [weak self] in
                    guard let self else { return }
                    guard self.environment.latestBackupDate() != nil else {
                        self.showMessage(title: "没有可恢复的备份",
                            message: "还没有导出过备份。请先使用上方“导出加密备份”。备份保存在本机，系统仍可能清理。")
                        return
                    }
                    self.restoreBackup()
                }
            }])
        }
    }
    private func grant(minutes: Int) {
        perform(.temporaryOverride, title: "增加 \(minutes) 分钟", message: "同时增加当前成员个人额度和家庭共享额度；不会跳过休息。") { env, token in
            guard let ledger = env.ledger else { throw LedgerError.closed }
            _ = try await ledger.grantTemporaryBonus(Int64(minutes) * 60_000, credential: token.credential)
        }
    }
    private static func backupDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func latestBackupMessage() -> String {
        guard let date = environment.latestBackupDate() else {
            return "还没有可用备份。请先导出加密备份；备份保存在本机，系统仍可能清理。"
        }
        return "最近一次备份：\(Self.backupDateText(date))。\n备份加密保存在本机，系统仍可能清理，不是异地备份。"
    }

    private func exportBackup() {
        perform(.recovery, title: "导出备份",
                message: "将停止当前播放。备份加密保存在设备本地，仍可能被系统清理，不是异地备份。",
                onSuccess: { [weak self] in
                    guard let self else { return }
                    let alert = UIAlertController(title: "备份已保存",
                        message: self.latestBackupMessage(), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .cancel))
                    FamilyClockRecoveryPresenter.presentAfterAlertDismissal(alert, from: self)
                }) { env, token in
            _ = try await env.exportBackup(authorization: token)
        }
    }

    private func restoreBackup() {
        perform(.recovery, title: "恢复旧备份？",
                message: "保留现有数据目录，恢复后冻结当天剩余额度并要求确认时间。备份之后的新记录不合并到恢复记录。",
                onSuccess: { [weak self] in
                    guard let self else { return }
                    let alert = UIAlertController(title: "恢复完成",
                        message: "已恢复最近一次备份。当天剩余额度已冻结，需要确认设备时间后才能继续。确认时间不会解冻备份余额。",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "现在确认时间", style: .default) { [weak self] _ in
                        guard let self else { return }
                        FamilyClockRecoveryPresenter.present(from: self, environment: self.environment,
                            authorize: self.clockAuthorize) { [weak self] state in
                            guard let self else { return }
                            self.reloadSettings()
                            FamilyClockRecoveryPresenter.showResult(from: self, state: state)
                        }
                    })
                    alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
                    FamilyClockRecoveryPresenter.presentAfterAlertDismissal(alert, from: self)
                }) { env, token in
            try await env.restoreBackup(authorization: token)
        }
    }

    private func perform(_ context: ParentalAuthContext, title: String, message: String,
                         onSuccess: (() -> Void)? = nil,
                         operation: @escaping (FamilyEnvironment, ParentalAuthorization) async throws -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续", style: .default) { [weak self] _ in
            self?.authorize(context) { [weak self] token in
                guard let self else { return }
                Task {
                    do {
                        try await operation(self.environment, token)
                        await self.environment.refresh()
                        self.reloadSettings()
                        if let onSuccess { onSuccess() }
                        else { self.showMessage(title: "已完成", message: "操作已记录。") }
                    } catch { self.showError(error) }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
