import FamilyCore
import UIKit

typealias FamilyAuthorize = (ParentalAuthContext, @escaping (ParentalAuthorization) -> Void) -> Void

extension Notification.Name {
    static let familySettingsReturnToOverview = Notification.Name("FamilySettingsReturnToOverview")
    static let familySettingsInteraction = Notification.Name("FamilySettingsInteraction")
    /// First-run guidance navigation; the object is a FamilyGuideTarget raw value.
    static let familySettingsNavigate = Notification.Name("FamilySettingsNavigate")
}

/// Destinations the overview's "开始使用" steps can jump to. Raw values must match
/// FamilyControlViewController.Category.
enum FamilyGuideTarget: Int {
    case profiles = 1
    case watch = 2
    case quiz = 3
    case backup = 6
}

/// Reuses the upstream collection layout, section header and focused settings row.
/// Stable model instances keep focus and scroll position when values refresh.
class FamilySettingsPage: SettingsViewController {
    private var stableRows = [String: CellModel]()
    private var renderedTitles = [String]()
    private var lastFocusedTitle: String?
    /// Active text-entry callback, kept so the keyboard's return key can commit
    /// the dialog without relying on focus inside the alert.
    private var pendingTextSave: ((String) -> Void)?
    private weak var pendingTextAlert: UIAlertController?

    override func setupData() { reloadSettings() }
    func reloadSettings() {}

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(redactBeforeBackground),
            name: UIApplication.willResignActiveNotification, object: nil)
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.contentInset = UIEdgeInsets(top: 4, left: 8, bottom: 30, right: 16)
        collectionView.clipsToBounds = false
        collectionView.remembersLastFocusedIndexPath = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redactBeforeBackground() {
        var modal = presentedViewController
        while let current = modal { current.view.isHidden = true; modal = current.presentedViewController }
        if presentedViewController != nil { dismiss(animated: false) }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let title = lastFocusedTitle,
           let model = stableRows[title], let path = dataSource?.indexPath(for: model),
           let cell = collectionView.cellForItem(at: path) { return [cell] }
        return [collectionView]
    }

    func row(_ title: String, _ value: String = "", action: (() -> Void)? = nil) -> CellModel {
        let model = stableRows[title] ?? CellModel(title: title, desp: value, action: nil)
        model.desp = { value }
        model.action = { [weak self] update in
            guard let self else { return }
            self.lastFocusedTitle = title
            NotificationCenter.default.post(name: .familySettingsInteraction, object: self.navigationController)
            action?()
            update()
        }
        stableRows[title] = model
        return model
    }

    func render(_ sections: [SectionModel]) {
        guard isViewLoaded, dataSource != nil else { return }
        let titles = sections.flatMap { [$0.title] + $0.items.map(\.title) }
        sections.flatMap(\.items).forEach { $0.updateAction?() }
        var snapshot = NSDiffableDataSourceSnapshot<SectionModel, CellModel>()
        for section in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items, toSection: section)
        }
        let liveTitles = Set(sections.flatMap(\.items).map(\.title))
        stableRows = stableRows.filter { liveTitles.contains($0.key) }
        dataSource.apply(snapshot, animatingDifferences: false)
        // Stable instances compare equal by title, so a value-only change is
        // invisible to the diff. Reconfigure every item in place after the
        // apply or cells keep showing stale values (focus is preserved).
        var current = dataSource.snapshot()
        let identifiers = current.itemIdentifiers
        if !identifiers.isEmpty {
            current.reconfigureItems(identifiers)
            dataSource.apply(current, animatingDifferences: false)
        }
        renderedTitles = titles
    }

    func choose(title: String, values: [String], selectedIndex: Int?, onSelect: @escaping (Int) -> Void) {
        guard !values.isEmpty else { showMessage(title: title, message: "暂无可选内容。"); return }
        if values.count > 10, let navigationController {
            let page = FamilyChoicePage()
            page.title = title
            page.values = values
            page.selectedIndex = selectedIndex
            page.onSelect = onSelect
            navigationController.pushViewController(page, animated: true)
            return
        }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (index, value) in values.enumerated() {
            let action = UIAlertAction(title: value, style: .default) { _ in onSelect(index) }
            alert.addAction(action)
            if index == selectedIndex { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func editText(title: String, value: String, onSave: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            // The system keyboard's return/确认 key commits the dialog directly:
            // remote users finish typing in one flow, and the alert never turns
            // into a focus dead zone after the keyboard dismisses.
            field.addTarget(self, action: #selector(Self.commitTextEntry(_:)), for: .editingDidEndOnExit)
        }
        let save = UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            self?.pendingTextSave = nil
            self?.pendingTextAlert = nil
            onSave(alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(save)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.pendingTextSave = nil
            self?.pendingTextAlert = nil
        })
        alert.preferredAction = save
        pendingTextSave = onSave
        pendingTextAlert = alert
        present(alert, animated: true)
    }

    /// Return key on the system keyboard: save with the committed text. The
    /// dismissal waits for the next runloop or the system's own return handling
    /// cancels it, leaving the dialog stuck on screen.
    @objc private func commitTextEntry(_ sender: UITextField) {
        guard let onSave = pendingTextSave else { return }
        pendingTextSave = nil
        let text = sender.text ?? ""
        let alert = pendingTextAlert
        pendingTextAlert = nil
        DispatchQueue.main.async {
            alert?.dismiss(animated: true) {
                onSave(text)
            }
        }
    }

    func showMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    func showError(_ error: Error) {
        let message: String
        switch error {
        case ParentalAuthError.authorizationExpired, ParentalAuthError.invalidAuthorization:
            message = "家长授权已结束，请重新验证。已提交的修改会保留，未提交的内容仍在此页面。"
        case LedgerError.leaseAlreadyActive:
            message = "请先停止播放，再修改观看成员或规则。"
        case LedgerError.clockUntrusted:
            message = "家庭时间需要确认，请前往“家庭概览”确认设备时间。"
        case LedgerError.missingDatabase:
            message = "家庭账本文件缺失或没有可用备份。请前往“备份与恢复”检查；如果账本已丢失，请恢复最近备份。"
        case LedgerError.checkpointMismatch:
            message = "备份与当前家庭账本不匹配，未执行恢复。原数据仍在。"
        case LedgerError.securityStoreUnavailable:
            message = "家庭安全存储不可用，本次操作未执行。原数据仍在，请稍后重试。"
        case LedgerError.invalidInput(let reason): message = reason
        default: message = "本次操作未完成，原有数据不会被重置。请稍后重试或检查家庭状态。"
        }
        showMessage(title: "操作未完成", message: message)
    }
}

private final class FamilyChoicePage: FamilySettingsPage {
    var values = [String]()
    var selectedIndex: Int?
    var onSelect: ((Int) -> Void)?
    private var didRequestInitialFocus = false

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard let selectedIndex, values.indices.contains(selectedIndex),
              let dataSource,
              let item = dataSource.snapshot().itemIdentifiers.indices.contains(selectedIndex)
                ? dataSource.snapshot().itemIdentifiers[selectedIndex] : nil,
              let path = dataSource.indexPath(for: item),
              let cell = collectionView.cellForItem(at: path) else {
            return super.preferredFocusEnvironments
        }
        return [cell]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didRequestInitialFocus, let selectedIndex, values.indices.contains(selectedIndex),
              let dataSource else { return }
        didRequestInitialFocus = true
        let path = IndexPath(item: selectedIndex, section: 0)
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func reloadSettings() {
        let items = values.enumerated().map { index, value in
            row(value, index == selectedIndex ? "✓" : "") { [weak self] in
                self?.onSelect?(index)
                self?.navigationController?.popViewController(animated: true)
            }
        }
        render([SectionModel(title: title ?? "选择", items: items)])
    }
}
