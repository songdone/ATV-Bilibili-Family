import FamilyCore
import UIKit

/// A television keypad styled with the upstream settings row, not iOS form buttons.
final class FamilyPINViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onAuthorized: ((ParentalAuthorization, ParentalSession) -> Void)?
    var onCancel: (() -> Void)?
    private let auth: ParentalAuth
    private let context: ParentalAuthContext
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let digitsLabel = UILabel()
    private let keypad = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "删除", "0", "取消"]
    private var digits = ""
    private var firstPIN: String?
    private var creating = false
    private var busy = true
    private var active = true
    private var delivered = false
    private var visibilityGeneration = UUID()
    private var backgroundObserver: NSObjectProtocol?

    init(auth: ParentalAuth, context: ParentalAuthContext) {
        self.auth = auth; self.context = context
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.80)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.layer.cornerRadius = 20
        blur.clipsToBounds = true
        view.addSubview(blur)
        blur.snp.makeConstraints { $0.center.equalToSuperview(); $0.width.equalTo(860); $0.height.equalTo(810) }
        titleLabel.text = "家长验证"
        titleLabel.font = .systemFont(ofSize: 44, weight: .medium)
        messageLabel.font = .systemFont(ofSize: 26)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 2
        messageLabel.text = "正在检查家长权限…"
        digitsLabel.font = .monospacedSystemFont(ofSize: 40, weight: .regular)
        [titleLabel, messageLabel, digitsLabel].forEach { $0.textAlignment = .center; blur.contentView.addSubview($0) }
        titleLabel.snp.makeConstraints { $0.top.equalToSuperview().offset(52); $0.leading.trailing.equalToSuperview().inset(50) }
        messageLabel.snp.makeConstraints { $0.top.equalTo(titleLabel.snp.bottom).offset(20); $0.leading.trailing.equalToSuperview().inset(42); $0.height.equalTo(68) }
        digitsLabel.snp.makeConstraints { $0.top.equalTo(messageLabel.snp.bottom).offset(14); $0.leading.trailing.equalToSuperview().inset(50) }
        blur.contentView.addSubview(keypad)
        keypad.backgroundColor = .clear
        keypad.clipsToBounds = false
        keypad.register(FamilyPINCell.self, forCellWithReuseIdentifier: "key")
        keypad.dataSource = self; keypad.delegate = self
        keypad.snp.makeConstraints { $0.top.equalTo(digitsLabel.snp.bottom).offset(38); $0.centerX.equalToSuperview(); $0.width.equalTo(584); $0.height.equalTo(352) }
        let footer = UILabel()
        footer.text = "仅用于家庭管理 · 请勿向孩子透露 PIN"
        footer.font = .systemFont(ofSize: 23)
        footer.textColor = .secondaryLabel
        footer.textAlignment = .center
        blur.contentView.addSubview(footer)
        footer.snp.makeConstraints { $0.top.equalTo(keypad.snp.bottom).offset(32); $0.leading.trailing.equalToSuperview().inset(30) }
        updateDigits()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await auth.status()
                guard active else { return }
                if case .notConfigured = status { creating = true }
                titleLabel.text = creating ? "创建六位家长 PIN" : "家长验证"
                messageLabel.text = creating ? "请输入六位数字，下一步再次确认。" : "请输入六位家长 PIN。"
                busy = false
                keypad.reloadData(); setNeedsFocusUpdate(); updateFocusIfNeeded()
            } catch { messageLabel.text = "权限数据不可用，请返回检查。" }
        }
    }

    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let first = keypad.cellForItem(at: IndexPath(item: busy ? 11 : 0, section: 0)) { return [first] }
        return [keypad]
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        active = false; visibilityGeneration = UUID(); digits = ""; firstPIN = nil
        if !delivered { onCancel?() }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { cancel(); return }
        super.pressesBegan(presses, with: event)
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { keys.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "key", for: indexPath) as! FamilyPINCell
        cell.setKey(keys[indexPath.item], enabled: !busy || indexPath.item == 11)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: 176, height: 68) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { 28 }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { 22 }
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { !busy || indexPath.item == 11 }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let key = keys[indexPath.item]
        if key == "取消" { cancel(); return }
        guard !busy else { return }
        if key == "删除" { if !digits.isEmpty { digits.removeLast() }; updateDigits(); return }
        guard digits.count < 6 else { return }
        digits += key; updateDigits()
        guard digits.count == 6 else { return }
        let pin = digits
        digits = ""; updateDigits()
        if creating, firstPIN == nil { firstPIN = pin; messageLabel.text = "请再次输入相同 PIN。"; return }
        if creating, firstPIN != pin { firstPIN = nil; messageLabel.text = "两次输入不同，请重新设置。"; return }
        busy = true
        let generation = visibilityGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                if creating { try await auth.setup(pin: pin); firstPIN = nil; creating = false }
                let token = try await auth.authenticate(pin: pin, context: context)
                // Establish the parent session while the PIN is still in scope.
                // The auth layer scrubs its own copies; never persist or log it.
                let session = try await auth.beginSession(pin: pin)
                guard active, generation == visibilityGeneration else {
                    await auth.endSession(session)
                    return
                }
                delivered = true
                onAuthorized?(token, session)
            } catch {
                guard active, generation == visibilityGeneration else { return }
                busy = false
                if case ParentalAuthError.locked(let seconds) = error { messageLabel.text = "尝试过多，请 \(Int(ceil(seconds))) 秒后重试。" }
                else if case ParentalAuthError.incorrectPIN(let count) = error { messageLabel.text = "PIN 不正确，还可尝试 \(count) 次。" }
                else { messageLabel.text = "无法验证家长权限，请返回后重试。" }
            }
        }
    }
    private func updateDigits() {
        digitsLabel.text = String(repeating: "●  ", count: digits.count) + String(repeating: "○  ", count: 6 - digits.count)
        digitsLabel.accessibilityLabel = "已输入 \(digits.count) 位"
    }
    private func cancel() {
        guard active else { return }
        active = false; visibilityGeneration = UUID(); digits = ""; firstPIN = nil
        onCancel?(); delivered = true
        dismiss(animated: true)
    }
}

private final class FamilyPINCell: SettingsSwitchCell {
    func setKey(_ title: String, enabled: Bool) {
        set(with: SettingsViewController.CellModel(title: title, desp: "", action: nil))
        titleLabel.textAlignment = .center
        titleLabel.snp.remakeConstraints { $0.edges.equalToSuperview().inset(14) }
        titleLabel.font = .systemFont(ofSize: 32)
        accessibilityLabel = title
        accessibilityIdentifier = "family-pin-" + title
        accessibilityTraits = enabled ? [.button] : [.button, .notEnabled]
        alpha = enabled ? 1 : 0.35
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        contentView.layer.borderWidth = 1
    }
}
