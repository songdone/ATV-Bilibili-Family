import UIKit

/// A TV-focused gate choice. Focus starts on the primary action, so one Select
/// proceeds. Defaults preserve the clock-recovery entry and its probe identifiers.
final class FamilyClockRecoveryEntryController: UIViewController {
    var onContinue: (() -> Void)?
    var onCancel: (() -> Void)?
    private let explanation: String
    private let heading: String
    private let continueTitle: String
    private let cancelTitle: String
    private let reason: String
    private let continueIdentifier: String
    private let cancelIdentifier: String
    private let continueButton = UIButton(type: .system)
    private var handled = false

    init(message: String, title: String = "确认一次，继续播放",
         continueTitle: String = "验证并继续", cancelTitle: String = "暂不播放",
         reason: String = "clock", continueIdentifier: String = "family-clock-parent-retry",
         cancelIdentifier: String = "family-clock-return-to-source") {
        explanation = message
        heading = title
        self.continueTitle = continueTitle
        self.cancelTitle = cancelTitle
        self.reason = reason
        self.continueIdentifier = continueIdentifier
        self.cancelIdentifier = cancelIdentifier
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        view.accessibilityIdentifier = "family-playback-denial-" + reason
        view.accessibilityValue = reason
        let title = UILabel()
        title.text = heading
        title.font = .systemFont(ofSize: 40, weight: .semibold)
        title.textAlignment = .center
        let message = UILabel()
        message.text = explanation
        message.font = .systemFont(ofSize: 28)
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        message.textAlignment = .center
        continueButton.setTitle(continueTitle, for: .normal)
        continueButton.accessibilityIdentifier = continueIdentifier
        continueButton.addTarget(self, action: #selector(proceed), for: .primaryActionTriggered)
        let cancel = UIButton(type: .system)
        cancel.setTitle(cancelTitle, for: .normal)
        cancel.accessibilityIdentifier = cancelIdentifier
        cancel.addTarget(self, action: #selector(cancelRecovery), for: .primaryActionTriggered)
        let actions = UIStackView(arrangedSubviews: [continueButton, cancel])
        actions.axis = .horizontal
        actions.spacing = 36
        actions.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [title, message, actions])
        stack.axis = .vertical
        stack.spacing = 36
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.65),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            actions.heightAnchor.constraint(equalToConstant: 70)
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [continueButton] }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { cancelRecovery(); return }
        super.pressesBegan(presses, with: event)
    }
    @objc private func proceed() {
        guard !handled else { return }
        handled = true
        onContinue?()
    }
    @objc private func cancelRecovery() {
        guard !handled else { return }
        handled = true
        onCancel?()
    }
}
