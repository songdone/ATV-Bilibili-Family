import FamilyCore
import UIKit

private func familyReportDuration(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds) / 1_000
    return "\(seconds / 60)分\(seconds % 60)秒"
}

private func familyReportDate(_ day: Int64) -> String {
    let value = String(day)
    guard value.count == 8 else { return value }
    return "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
}

private func familyReportLine(_ value: String, limit: Int = 24) -> String {
    let line = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}

/// One capability and one disposable report for the whole report navigation stack.
/// Child pages never retain their own copies of private rows or alert payloads.
@MainActor
private final class FamilyNativeReportSession: NSObject {
    let environment: FamilyEnvironment
    private let authorize: FamilyAuthorize
    private let validateAccess: () async throws -> Void
    private(set) var report: UsageLedger.FamilyReport?
    private(set) var names = [String: String]()
    private(set) var message = "验证家长权限后查看近14天报告"
    private var token: ParentalAuthorization?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var validationTimer: Timer?
    private let pages = NSHashTable<FamilyNativeReportsPage>.weakObjects()

    init(environment: FamilyEnvironment, authorize: @escaping FamilyAuthorize,
         validateAccess: @escaping () async throws -> Void) {
        self.environment = environment
        self.authorize = authorize
        self.validateAccess = validateAccess
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(hidePrivateData),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hidePrivateData),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        loadTask?.cancel()
        validationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func register(_ page: FamilyNativeReportsPage) { pages.add(page) }

    func clear(_ text: String) {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        validationTimer?.invalidate()
        validationTimer = nil
        token = nil
        report = nil
        names.removeAll()
        message = text
        notifyPages()
    }

    @objc private func hidePrivateData() { clear("报告已隐藏，请重新验证家长权限") }

    private func notifyPages() {
        for page in pages.allObjects {
            if report == nil { page.clearReportDetails() }
            if page.isViewLoaded { page.reloadSettings() }
        }
    }

    func requestReport() {
        guard UIApplication.shared.applicationState == .active else { return }
        clear("等待家长验证，报告内容已清空")
        let requestID = generation
        authorize(.configureRules) { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestID,
                      UIApplication.shared.applicationState == .active else { return }
                self.load(token, requestID: requestID)
            }
        }
    }

    private func load(_ token: ParentalAuthorization, requestID: UUID) {
        self.token = token
        message = "正在读取近14天报告"
        notifyPages()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await environment.auth.validate(token, for: .configureRules)
                guard !Task.isCancelled, generation == requestID else { return }
                guard !environment.isMaintaining, let ledger = environment.ledger else { throw LedgerError.closed }
                let result = try await ledger.report(lastDays: 14, credential: token.credential)
                try await environment.auth.validate(token, for: .configureRules)
                guard !Task.isCancelled, generation == requestID else { return }
                guard UIApplication.shared.applicationState == .active,
                      !environment.isMaintaining, environment.ledger === ledger else {
                    clear("报告已隐藏，请重新验证家长权限")
                    return
                }
                names = Dictionary(uniqueKeysWithValues: (environment.snapshot?.profiles ?? []).map {
                    ($0.id.uuidString, $0.displayName)
                })
                report = result
                message = ""
                notifyPages()
                validationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.validateThen {} }
                }
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                clear(error is ParentalAuthError ? "家长授权已结束，请重新验证" : "暂时无法读取报告，请稍后重试")
            }
        }
    }

    func validateThen(_ action: @escaping () -> Void) {
        guard report != nil else { return }
        let requestID = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The fetch token expires after 60 seconds. Viewing an already
                // fetched report follows the parent session, without refreshing
                // its idle deadline on passive timer polls.
                try await validateAccess()
                guard generation == requestID else { return }
                guard UIApplication.shared.applicationState == .active,
                      environment.ledger != nil, !environment.isMaintaining else {
                    clear("报告已隐藏，请重新验证家长权限")
                    return
                }
                action()
            } catch {
                guard generation == requestID else { return }
                clear("家长授权已结束，请重新验证")
            }
        }
    }

    func childName(_ id: String?) -> String {
        guard let id else { return "未关联孩子" }
        return names[id] ?? "已删除档案"
    }

    var childIDs: [String] {
        guard let report else { return [] }
        var ids = Set(names.keys)
        report.days.forEach { ids.formUnion($0.personalMilliseconds.keys) }
        ids.formUnion(report.quizAttempts.map { $0.childID.uuidString })
        ids.formUnion(report.wrongAnswers.compactMap { $0.childID?.uuidString })
        return ids.sorted()
    }
}

final class FamilyNativeReportsPage: FamilySettingsPage {
    private enum Route {
        case summary, children, child(String), dates, date(Int64), attempts(String?), wrongs(String?), audit

        var title: String {
            switch self {
            case .summary: return "使用报告 · 近14天"
            case .children: return "按孩子查看"
            case .child: return "孩子用量详情"
            case .dates: return "按日期查看"
            case .date: return "每日用量详情"
            case .attempts: return "答题记录"
            case .wrongs: return "错题列表"
            case .audit: return "家长操作审计"
            }
        }
    }

    private let session: FamilyNativeReportSession
    private let route: Route
    private var requestedInitialReport = false

    init(environment: FamilyEnvironment, authorize: @escaping FamilyAuthorize,
         validateAccess: @escaping () async throws -> Void) {
        session = FamilyNativeReportSession(environment: environment, authorize: authorize,
                                            validateAccess: validateAccess)
        route = .summary
        super.init(nibName: nil, bundle: nil)
        title = route.title
        session.register(self)
    }

    private init(session: FamilyNativeReportSession, route: Route) {
        self.session = session
        self.route = route
        super.init(nibName: nil, bundle: nil)
        title = route.title
        session.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .summary = route, !requestedInitialReport {
            requestedInitialReport = true
            // Merely passing this category with the remote must not open a PIN
            // dialog. The explicit "验证并读取报告" row starts authorization.
        } else if session.report != nil {
            session.validateThen {}
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller.isBeingDismissed {
                session.clear("报告已关闭，请重新验证家长权限")
                return
            }
            ancestor = controller.parent
        }
        if case .summary = route, isMovingFromParent {
            session.clear("报告已关闭，请重新验证家长权限")
        }
    }

    fileprivate func clearReportDetails() {
        if let alert = presentedViewController as? UIAlertController {
            alert.title = "报告已隐藏"
            alert.message = nil
            alert.view.isHidden = true
            alert.dismiss(animated: false)
        }
    }

    override func reloadSettings() {
        guard let report = session.report else {
            render([SectionModel(title: "使用报告", items: [
                row("报告状态", session.message),
                row("验证并读取报告", "近14天") { [weak self] in self?.session.requestReport() }
            ])])
            return
        }
        switch route {
        case .summary: renderSummary(report)
        case .children: renderChildren(report)
        case .child(let id): renderChild(id, report: report)
        case .dates: renderDates(report)
        case .date(let day): renderDate(day, report: report)
        case .attempts(let child): renderAttempts(report, child: child)
        case .wrongs(let child): renderWrongs(report, child: child)
        case .audit: renderAudit(report)
        }
    }

    private func open(_ route: Route) {
        session.validateThen { [weak self] in
            guard let self, self.navigationController?.topViewController === self else { return }
            self.navigationController?.pushViewController(FamilyNativeReportsPage(session: self.session, route: route), animated: true)
        }
    }

    private func detail(_ content: @escaping (UsageLedger.FamilyReport) -> (String, String)?) {
        session.validateThen { [weak self] in
            guard let self, let report = self.session.report,
                  self.viewIfLoaded?.window != nil,
                  self.navigationController?.topViewController === self,
                  let (title, message) = content(report) else { return }
            self.showMessage(title: title, message: message)
        }
    }

    private func statistics(_ attempts: [UsageLedger.FamilyReport.QuizAttemptSummary]) -> [CellModel] {
        let correct = attempts.reduce(0) { $0 + $1.correct }
        let total = attempts.reduce(0) { $0 + $1.total }
        let rate = total == 0 ? "暂无答题" : String(format: "%.1f%%（%d/%d）", Double(correct) * 100 / Double(total), correct, total)
        // rewardedMinutes is a historical API name; the persisted unit is milliseconds.
        let reward = attempts.reduce(Int64(0)) { $0 + $1.rewardedMinutes }
        return [row("答题次数", "\(attempts.count)次"), row("答题正确率", rate), row("实际获得奖励", familyReportDuration(reward))]
    }

    private func renderSummary(_ report: UsageLedger.FamilyReport) {
        let actual = report.days.reduce(Int64(0)) { $0 + $1.familyActualMilliseconds }
        let frozen = report.days.reduce(Int64(0)) { $0 + $1.familyFrozenMilliseconds }
        let personal = report.days.reduce(Int64(0)) { $0 + $1.personalMilliseconds.values.reduce(0, +) }
        let summary = [
            row("家庭实际观看 · 近14天", familyReportDuration(actual)),
            row("家庭冻结预留 · 近14天", familyReportDuration(frozen)),
            row("个人实际观看合计 · 近14天", familyReportDuration(personal)),
            row("统计口径", "查看说明") { [weak self] in self?.explainTotals() }
        ]
        let navigation = [
            row("按孩子查看", "\(session.childIDs.count)个档案") { [weak self] in self?.open(.children) },
            row("按日期查看", "\(report.days.count)天有记录") { [weak self] in self?.open(.dates) }
        ]
        let learning = statistics(report.quizAttempts) + [
            row("查看答题记录", "\(report.quizAttempts.count)条") { [weak self] in self?.open(.attempts(nil)) },
            row("错题列表", "\(report.wrongAnswers.count)条") { [weak self] in self?.open(.wrongs(nil)) }
        ]
        render([
            SectionModel(title: "近14天概览", items: summary),
            SectionModel(title: "用量明细", items: navigation),
            SectionModel(title: "答题统计与奖励", items: learning),
            SectionModel(title: "家长操作", items: [
                row("审计详情", "\(report.audit.count)条") { [weak self] in self?.open(.audit) },
                row("重新读取报告", "重新验证") { [weak self] in self?.session.requestReport() }
            ])
        ])
    }

    private func explainTotals() {
        detail { _ in ("统计口径", "实际观看只统计账本确认的用量，冻结预留不等于已经观看。多人同看时，家庭用量计一次，每个孩子分别计入个人用量，因此个人合计可能高于家庭用量。\n\n当前报告提供家庭每日冻结与个人每日实际用量，不提供个人历史冻结；不会用今天的快照或家庭冻结代替个人历史数据。") }
    }

    private func renderChildren(_ report: UsageLedger.FamilyReport) {
        let items = session.childIDs.enumerated().map { index, id in
            let actual = report.days.reduce(Int64(0)) { $0 + $1.personalMilliseconds[id, default: 0] }
            return row("孩子 \(index + 1) · \(familyReportLine(session.childName(id)))", familyReportDuration(actual)) { [weak self] in
                self?.open(.child(id))
            }
        }
        render([SectionModel(title: "个人实际观看 · 近14天", items: items.isEmpty ? [row("暂无孩子用量", "近14天")] : items)])
    }

    private func renderChild(_ id: String, report: UsageLedger.FamilyReport) {
        let childTitle = "\(familyReportLine(session.childName(id))) · 用量"
        title = childTitle
        navigationItem.title = childTitle
        let actual = report.days.reduce(Int64(0)) { $0 + $1.personalMilliseconds[id, default: 0] }
        let attempts = report.quizAttempts.filter { $0.childID.uuidString == id }
        let days = report.days.filter { $0.personalMilliseconds[id] != nil }.reversed().map { day in
            row("日期 \(familyReportDate(day.day))", familyReportDuration(day.personalMilliseconds[id, default: 0]))
        }
        render([
            SectionModel(title: "孩子概览", items: [
                row("孩子档案", familyReportLine(session.childName(id))) { [weak self] in
                    self?.detail { [weak self] _ in ("孩子档案", self?.session.childName(id) ?? "") }
                },
                row("个人实际观看 · 近14天", familyReportDuration(actual))
            ]),
            SectionModel(title: "答题统计与奖励", items: statistics(attempts) + [
                row("查看孩子答题记录", "\(attempts.count)条") { [weak self] in self?.open(.attempts(id)) },
                row("查看孩子错题", "查看详情") { [weak self] in self?.open(.wrongs(id)) }
            ]),
            SectionModel(title: "每日实际观看", items: days.isEmpty ? [row("暂无观看记录", "近14天")] : days)
        ])
    }

    private func renderDates(_ report: UsageLedger.FamilyReport) {
        let items = report.days.reversed().map { day in
            row("日期 \(familyReportDate(day.day))", familyReportDuration(day.familyActualMilliseconds)) { [weak self] in
                self?.open(.date(day.day))
            }
        }
        render([SectionModel(title: "家庭每日实际观看", items: items.isEmpty ? [row("暂无观看记录", "近14天")] : items)])
    }

    private func renderDate(_ date: Int64, report: UsageLedger.FamilyReport) {
        let dateTitle = "\(familyReportDate(date)) · 用量"
        title = dateTitle
        navigationItem.title = dateTitle
        guard let day = report.days.first(where: { $0.day == date }) else {
            render([SectionModel(title: "每日用量", items: [row("该日期暂无记录")])]); return
        }
        let children = day.personalMilliseconds.sorted { $0.key < $1.key }.enumerated().map { index, item in
            row("孩子 \(index + 1) · \(familyReportLine(session.childName(item.key)))", familyReportDuration(item.value)) { [weak self] in
                self?.open(.child(item.key))
            }
        }
        render([
            SectionModel(title: familyReportDate(date), items: [
                row("家庭实际观看", familyReportDuration(day.familyActualMilliseconds)),
                row("家庭冻结预留", familyReportDuration(day.familyFrozenMilliseconds))
            ]),
            SectionModel(title: "个人实际观看", items: children.isEmpty ? [row("该日暂无个人记录")] : children),
            SectionModel(title: "当日答题", items: statistics(report.quizAttempts.filter { $0.day == date }))
        ])
    }

    private func renderAttempts(_ report: UsageLedger.FamilyReport, child: String?) {
        let attemptTitle = child.map { "\(session.childName($0)) · 答题" } ?? "答题记录"
        title = attemptTitle
        navigationItem.title = attemptTitle
        let items = report.quizAttempts.enumerated().reversed().compactMap { index, attempt -> CellModel? in
            guard child == nil || attempt.childID.uuidString == child else { return nil }
            return row("答题 \(index + 1) · \(familyReportDate(attempt.day))", "\(attempt.correct)/\(attempt.total) · \(attempt.passed ? "通过" : "未通过")") { [weak self] in
                self?.detail { [weak self] current in
                    guard current.quizAttempts.indices.contains(index) else { return nil }
                    let value = current.quizAttempts[index]
                    return ("答题详情", "孩子：\(self?.session.childName(value.childID.uuidString) ?? "")\n日期：\(familyReportDate(value.day))\n正确：\(value.correct)/\(value.total)\n结果：\(value.passed ? "通过" : "未通过")\n实际奖励：\(familyReportDuration(value.rewardedMinutes))")
                }
            }
        }
        render([SectionModel(title: "最近答题 · 近14天", items: items.isEmpty ? [row("暂无答题记录", "近14天")] : items)])
    }

    private func renderWrongs(_ report: UsageLedger.FamilyReport, child: String?) {
        let wrongTitle = child.map { "\(session.childName($0)) · 错题" } ?? "错题列表"
        title = wrongTitle
        navigationItem.title = wrongTitle
        // Index belongs to this immutable report, not questionID: repeated questions
        // and the same question answered by two children must remain separate rows.
        let items = report.wrongAnswers.enumerated().reversed().compactMap { index, wrong -> CellModel? in
            guard child == nil || wrong.childID?.uuidString == child else { return nil }
            return row("错题 \(index + 1) · \(familyReportDate(wrong.day))", familyReportLine(session.childName(wrong.childID?.uuidString), limit: 12)) { [weak self] in
                self?.detail { [weak self] current in
                    guard current.wrongAnswers.indices.contains(index) else { return nil }
                    let value = current.wrongAnswers[index]
                    return ("错题详情", "孩子：\(self?.session.childName(value.childID?.uuidString) ?? "")\n日期：\(familyReportDate(value.day))\n\n\(value.prompt)\n\n你选了：\(value.chosenOptionID)\n正确答案：\(value.correctOptionID)\n\n解析：\(value.explanation)")
                }
            }
        }
        render([SectionModel(title: "最近错题 · 近14天", items: items.isEmpty ? [row("暂无错题记录", "近14天")] : items)])
    }

    private func renderAudit(_ report: UsageLedger.FamilyReport) {
        let labels = ["configureFamily": "调整家庭规则", "upsertProfile": "管理孩子档案", "selectViewers": "切换观看成员",
                      "reanchorClock": "确认家庭时间", "temporaryOverride": "临时授权", "child-mode-change": "切换儿童模式"]
        let items = report.audit.enumerated().reversed().map { index, audit in
            row("审计 \(index + 1) · \(familyReportDate(audit.day))", labels[audit.operation] ?? "家长操作") { [weak self] in
                self?.detail { current in
                    guard current.audit.indices.contains(index) else { return nil }
                    let value = current.audit[index]
                    let duration = value.durationMilliseconds.map(familyReportDuration) ?? "未记录"
                    return ("审计详情", "日期：\(familyReportDate(value.day))\n操作：\(labels[value.operation] ?? "家长操作")\n对象：\(value.object)\n时长：\(duration)")
                }
            }
        }
        render([SectionModel(title: "家长操作 · 近14天", items: items.isEmpty ? [row("暂无家长操作记录", "近14天")] : items)])
    }
}

/// Keep the entire original appreciation image and explanation visible on tvOS.
final class FamilyNativeSupportPage: UIViewController {
    private let session: ParentalSession
    private let imageView = UIImageView()
    private let explanation = UILabel()

    init(session: ParentalSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = "关于与支持"
        NotificationCenter.default.addObserver(self, selector: #selector(hidePrivateImage),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hidePrivateImage),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func text(_ value: String, size: CGFloat, bold: Bool = false) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = value
        return label
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -26),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        let close = UIButton(type: .system)
        close.setTitle("返回家长中心", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 26)
        close.accessibilityIdentifier = "family-support-return"
        close.addTarget(self, action: #selector(closePage), for: .primaryActionTriggered)
        stack.addArrangedSubview(close)
        stack.addArrangedSubview(text("支持项目持续更新", size: 46, bold: true))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        stack.addArrangedSubview(text("ATV-Bilibili Family · \(version)", size: 25))

        let imageRow = UIView()
        let white = UIView()
        white.backgroundColor = .white
        white.layer.cornerRadius = 14
        white.clipsToBounds = true
        imageRow.addSubview(white)
        white.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "开发者赞赏码"
        white.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let ideal = white.widthAnchor.constraint(equalToConstant: 380)
        ideal.priority = .defaultHigh
        // imageRow must join the hierarchy BEFORE activation: the width limits
        // below reach view.safeAreaLayoutGuide, and activating a constraint
        // whose items share no ancestor aborts the process.
        stack.addArrangedSubview(imageRow)
        NSLayoutConstraint.activate([
            white.centerXAnchor.constraint(equalTo: imageRow.centerXAnchor),
            white.topAnchor.constraint(equalTo: imageRow.topAnchor),
            white.bottomAnchor.constraint(equalTo: imageRow.bottomAnchor),
            white.heightAnchor.constraint(equalTo: white.widthAnchor),
            ideal,
            white.widthAnchor.constraint(lessThanOrEqualTo: imageRow.widthAnchor, multiplier: 0.8),
            white.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.45),
            imageView.topAnchor.constraint(equalTo: white.topAnchor, constant: 16),
            imageView.bottomAnchor.constraint(equalTo: white.bottomAnchor, constant: -16),
            imageView.leadingAnchor.constraint(equalTo: white.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: white.trailingAnchor, constant: -16)
        ])

        explanation.font = .systemFont(ofSize: 28)
        explanation.textColor = .label
        explanation.textAlignment = .center
        explanation.numberOfLines = 0
        explanation.text = "如果这个小工具帮上了忙，欢迎请开发者喝杯咖啡。\n打开微信扫一扫，支持开发者。\n完全自愿，不影响任何功能使用。"
        stack.addArrangedSubview(explanation)
        let link = text("开源项目：github.com/songdone/ATV-Bilibili-Family", size: 23)
        link.textColor = .secondaryLabel
        stack.addArrangedSubview(link)
        refreshImage()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshImage()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        imageView.image = nil
    }
    private func refreshImage() {
        guard !session.credential.isEmpty else { imageView.image = nil; return }
        imageView.image = SupportConfig.load().image()
        if imageView.image == nil {
            explanation.text = "此构建未配置微信赞赏码。\n完全自愿，不影响任何功能使用。"
        }
    }
    @objc private func hidePrivateImage() { imageView.image = nil }

    @objc private func closePage() {
        NotificationCenter.default.post(name: .familySettingsReturnToOverview, object: navigationController)
    }
}
