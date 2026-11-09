import FamilyCore
import UIKit

// All editors use the original SettingsViewController rows and focus behavior.
// Only drafts live here; operation-scoped authorizations are requested at commit time.
class FamilyNativeEditorPage: FamilySettingsPage {
    var familyEnvironment = FamilyEnvironment.shared
    var requestAuthorization: FamilyAuthorize?
    /// Destructive actions (delete child) always require a fresh PIN, even when
    /// a parent session would suffice for ordinary saves.
    var requestHighRiskAuthorization: FamilyAuthorize?
    var didSave: () -> Void = {}
    /// Called with the authoritative snapshot after a successful save.
    var didCommit: (LedgerSnapshot) -> Void = { _ in }
    /// Called after a failed save with the latest authoritative snapshot (nil
    /// when the ledger cannot be read). Editors use it to stop showing values
    /// that were never stored.
    var didFail: ((LedgerSnapshot?) -> Void)?
    var saving = false
    /// A second edit made while a save is in flight must still be persisted.
    var autoSavePending = false
    var pendingLeave = false
    var operationError: String?
    private var operationErrorTitle = "未生效"
    private var operationErrorSummary = ""

    /// Optional rewards do not block ordinary profile creation. Required quizzes
    /// must have a real, complete pool before a parent can make them a watch gate.
    static func validateRequiredQuiz(_ rules: QuizRules?, profiles: [ViewerProfile]) throws {
        guard let rules, rules.quizBeforeFirstWatch || rules.quizAfterRest else { return }
        let children = profiles.filter(\.isEnabled)
        guard !children.isEmpty else { return }
        let guidance = "请到“孩子管理”→选择孩子→“编辑档案”→选择科目勾选可出题的科目，或关闭强制答题时机。不会跨年级或版本补题。"
        let bank: FamilyQuestionBank
        do { bank = try FamilyQuestionBank.load() }
        catch {
            throw LedgerError.invalidInput("无法启用强制答题。\n\(children.map(\.displayName).joined(separator: "、"))：题库不可用，\(error.localizedDescription)\n\(guidance)")
        }
        var failures = [String]()
        for child in children {
            do {
                let count = try bank.questions(for: child).count
                if count < rules.questionsPerRound {
                    failures.append("\(child.displayName)：每轮需要 \(rules.questionsPerRound) 题，当前匹配 \(count) 题。")
                }
            } catch {
                failures.append("\(child.displayName)：\(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw LedgerError.invalidInput("强制答题所需题库尚未就绪。\n\(failures.joined(separator: "\n"))\n\(guidance)")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSettings()
    }

    func leaveEditor() {
        if (navigationController?.viewControllers.count ?? 0) > 1 {
            navigationController?.popViewController(animated: true)
        } else {
            NotificationCenter.default.post(name: .familySettingsReturnToOverview, object: navigationController)
        }
    }

    func group(_ title: String, _ items: [CellModel]) -> SectionModel {
        SectionModel(title: title, items: items)
    }

    func shortValue(_ value: String) -> String {
        value.count > 24 ? String(value.prefix(23)) + "…" : value
    }

    func information(_ title: String, _ value: String = "查看说明", message: String) -> CellModel {
        row(title, value) { [weak self] in
            self?.showMessage(title: title, message: message)
        }
    }

    func draftDidChange() {}

    /// Rows stay tappable while a write is in flight; the next edit is queued
    /// instead of being silently dropped.
    func toggleRow(_ title: String, _ value: Bool, onChange: @escaping (Bool) -> Void) -> CellModel {
        row(title, value ? "开" : "关") { [weak self] in
            guard let self else { return }
            onChange(!value)
            self.draftDidChange()
            self.reloadSettings()
        }
    }

    func choiceRow<Value: Equatable>(_ title: String, current: Value, values: [Value],
                                    label: @escaping (Value) -> String,
                                    onChange: @escaping (Value) -> Void) -> CellModel {
        // Imported/custom values must remain selectable, without rounding or clamping.
        var choices = values
        if !choices.contains(current) { choices.append(current) }
        let options = choices
        return row(title, shortValue(label(current))) { [weak self] in
            guard let self else { return }
            self.choose(title: title, values: options.map(label), selectedIndex: options.firstIndex(of: current)) { [weak self] index in
                guard let self, options.indices.contains(index) else { return }
                onChange(options[index])
                if options[index] != current { self.draftDidChange() }
                self.reloadSettings()
            }
        }
    }

    func textRow(_ title: String, _ value: String, onChange: @escaping (String) -> Void) -> CellModel {
        row(title, value.isEmpty ? "未填写" : shortValue(value)) { [weak self] in
            guard let self else { return }
            self.editText(title: title, value: value) { [weak self] text in
                guard let self else { return }
                onChange(text)
                self.reloadSettings()
            }
        }
    }

    func durationLabel(_ milliseconds: Int64) -> String {
        let minutes = milliseconds / 60_000
        let remainder = milliseconds % 60_000
        guard remainder != 0 else { return "\(minutes) 分钟" }
        let seconds = remainder / 1_000
        let fraction = remainder % 1_000
        if fraction == 0 { return "\(minutes)分\(seconds)秒" }
        return "\(minutes)分\(seconds).\(String(format: "%03lld", fraction))秒"
    }

    func durationRow(_ title: String, current: Int64, minutes: [Int],
                     onChange: @escaping (Int64) -> Void) -> CellModel {
        choiceRow(title, current: current, values: minutes.map { Int64($0) * 60_000 },
                  label: { [weak self] in self?.durationLabel($0) ?? "\($0) 毫秒" }, onChange: onChange)
    }

    /// Changes apply immediately, so completion is the only action. If a write
    /// is still in flight, completion waits for it instead of dropping the edit.
    func doneSection(_ title: String = "完成") -> SectionModel {
        let status = saving ? "保存中" : operationError == nil ? "已自动保存" : "有未生效的修改"
        return group("操作", [row(title, status) { [weak self] in
            guard let self else { return }
            if self.saving { self.pendingLeave = true } else { self.leaveEditor() }
        }])
    }

    /// Inline feedback that cannot be lost behind a dismissible alert.
    func showInlineError(_ title: String, _ message: String) {
        operationErrorTitle = title
        operationErrorSummary = Self.errorSummary(message)
        operationError = message
        reloadSettings()
        revealInlineError()
    }

    /// The error section is the first section; make sure the parent actually
    /// sees it instead of only hearing that the switch bounced back.
    func revealInlineError() {
        guard operationError != nil, isViewLoaded else { return }
        let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        collectionView.setContentOffset(top, animated: true)
    }

    func errorSections() -> [SectionModel] {
        guard let operationError else { return [] }
        return [group("保存状态", [information(operationErrorTitle, operationErrorSummary, message: operationError)])]
    }

    /// The reason and the fix belong on the row itself: a parent must not have
    /// to open a dialog (or leave the page) to learn why a switch bounced back.
    private static func errorSummary(_ message: String) -> String {
        if message.contains("强制答题所需题库尚未就绪") {
            return "题库未就绪：请勾选答题科目，或关闭强制答题"
        }
        let first = message.split(separator: "\n").first.map(String.init) ?? message
        let clipped = first.count > 26 ? String(first.prefix(25)) + "…" : first
        return clipped
    }

    private func saveFailureMessage(_ error: Error) -> String {
        switch error {
        case LedgerError.invalidInput(let reason): return reason
        case LedgerError.leaseAlreadyActive: return "请先停止播放，再修改观看成员或规则。"
        case LedgerError.clockUntrusted: return "家庭时间需要确认，请前往“家庭概览”处理。"
        case ParentalAuthError.incorrectPIN: return "家长 PIN 不正确，请重试。"
        case ParentalAuthError.locked: return "验证次数过多，请稍后重试。"
        case ParentalAuthError.authorizationExpired, ParentalAuthError.invalidAuthorization, LedgerError.unauthorized:
            return "家长授权已结束，请重新验证。"
        default: return "本次操作未完成，请检查家庭账本后重试。"
        }
    }

    func flushPendingAutoSave() {}

    func commit(_ context: ParentalAuthContext, authorize: FamilyAuthorize? = nil, leaving: Bool = true,
                operation: @escaping (UsageLedger, ParentalAuthorization) async throws -> ((LedgerSnapshot) -> Bool)) {
        if saving { autoSavePending = true; return }
        guard let request = authorize ?? requestAuthorization else { return }
        // Do not mark busy until authorization completes: cancelling PIN leaves the draft usable.
        request(context) { [weak self] authorization in
            guard let self, !self.saving else { return }
            self.saving = true
            self.operationError = nil
            self.reloadSettings()
            // Keep the editor alive until the write and readback finish. A Menu
            // press can pop the page mid-write; the change must still land.
            Task { @MainActor [self] in
                defer {
                    self.saving = false
                    self.reloadSettings()
                    if self.operationError != nil { self.revealInlineError() }
                    if self.autoSavePending {
                        self.autoSavePending = false
                        self.flushPendingAutoSave()
                    }
                }
                var committed = false
                do {
                    await self.familyEnvironment.start()
                    guard !self.familyEnvironment.isMaintaining,
                          let ledger = self.familyEnvironment.ledger else { throw LedgerError.closed }
                    try await self.familyEnvironment.auth.validate(authorization, for: context)
                    // The ledger independently validates the capability immediately before mutation.
                    let confirmsSave = try await operation(ledger, authorization)
                    committed = true
                    let current = try await self.familyEnvironment.refreshVerified()
                    guard confirmsSave(current) else { throw LedgerError.eventConflict }
                    // A second edit made during this write lives only in the draft.
                    // Replacing the draft here would silently discard it before the
                    // queued flush runs, so defer the readback to the final write.
                    let hasQueuedEdit = self.autoSavePending
                    if !hasQueuedEdit { self.didCommit(current) }
                    self.didSave()
                    if hasQueuedEdit {
                        if leaving { self.pendingLeave = true }
                    } else if leaving {
                        self.leaveEditor()
                    } else if self.pendingLeave {
                        self.pendingLeave = false
                        self.leaveEditor()
                    }
                } catch {
                    // A failed readback may follow a durable write; never claim it was rolled back.
                    NSLog("FamilySettings save failed (%@): %@", String(describing: context), String(describing: error))
                    self.operationErrorTitle = committed ? "保存结果无法确认" : "未生效"
                    let message = committed ? "无法确认保存结果，请返回后重新检查。" : self.saveFailureMessage(error)
                    self.pendingLeave = false
                    self.operationErrorSummary = Self.errorSummary(message)
                    self.operationError = message
                    // Adopt the authoritative row rather than leaving an optimistic
                    // value that was never written. Preserve a queued second edit:
                    // the pending flush will retry it, and its own result decides
                    // whether the page rolls back.
                    if !self.autoSavePending {
                        let snapshot = try? await self.familyEnvironment.refreshVerified()
                        // A new edit can arrive while the refresh is in flight;
                        // keep its draft and let the queued flush own the result.
                        if !self.autoSavePending { self.didFail?(snapshot) }
                    }
                    // Auto-save failures stay inline; a blocking alert would hide
                    // the reason and steal focus from the setting being changed.
                    if leaving { self.showMessage(title: self.operationErrorTitle, message: message) }
                }
            }
        }
    }
}

final class FamilyNativeProfileEditor: FamilyNativeEditorPage {
    private var originalID: UUID?
    private var draft = ViewerProfile(displayName: "", curriculum: CurriculumProfile(
        schoolStage: "小学", schoolSystem: "六三", grade: 4,
        academicYear: FamilyNativeProfileEditor.autoAcademicTerm().year,
        semester: FamilyNativeProfileEditor.autoAcademicTerm().semester),
        dailyLimitMilliseconds: 90 * 60_000)
    private var catalog = [FamilyQuestionBank.CatalogItem]()
    private var catalogLoading = true
    private var catalogError: String?

    convenience init(environment: FamilyEnvironment, profile: ViewerProfile?,
                     authorize: @escaping FamilyAuthorize,
                     highRiskAuthorize: @escaping FamilyAuthorize = { _, _ in },
                     onSaved: @escaping () -> Void) {
        self.init()
        familyEnvironment = environment
        requestAuthorization = authorize
        requestHighRiskAuthorization = highRiskAuthorize
        didSave = onSaved
        originalID = profile?.id
        if let profile {
            draft = environment.snapshot?.profiles.first { $0.id == profile.id } ?? profile
        } else {
            // New children start from today's school calendar; nothing for the
            // parent to type beyond a nickname and a grade.
            let term = Self.autoAcademicTerm()
            draft.curriculum.academicYear = term.year
            draft.curriculum.semester = term.semester
        }
        // After the first automatic save this page edits a real profile, and the
        // draft must follow the authoritative row (including server-side selection).
        didCommit = { [weak self] snapshot in
            guard let self, let saved = snapshot.profiles.first(where: { $0.id == self.draft.id }) else { return }
            self.originalID = saved.id
            self.draft = saved
            self.navigationItem.title = "修改孩子"
            self.reloadSettings()
        }
        didFail = { [weak self] snapshot in
            guard let self, let snapshot else { return }
            // Adopt the stored row when it exists; a never-created draft stays
            // editable so the parent can retry without retyping.
            if let saved = snapshot.profiles.first(where: { $0.id == self.draft.id }) {
                self.originalID = saved.id
                self.draft = saved
                self.navigationItem.title = "修改孩子"
            }
            self.reloadSettings()
        }
        navigationItem.title = profile == nil ? "添加孩子" : "修改孩子"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadCatalog()
    }

    private func loadCatalog() {
        catalogLoading = true
        reloadSettings()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.familyEnvironment.start()
            do {
                self.catalog = try await Task.detached(priority: .utility) {
                    try FamilyQuestionBank.load().catalog
                }.value
                self.catalogError = nil
            } catch {
                self.catalog = []
                self.catalogError = "题库目录不可用：\(error.localizedDescription)\n已有教材与章节选择会保留，不会跨年级或版本补题。"
            }
            self.catalogLoading = false
            self.reloadSettings()
        }
    }

    override func reloadSettings() {
        let curriculum = draft.curriculum
        // Every row commits immediately; there is no separate save button.
        var sections = [group("基本信息", [
            textRow("孩子昵称", draft.displayName) { [weak self] in
                guard let self else { return }
                self.draft.displayName = $0
                self.saveProfile(leaving: false)
            },
            choiceRow("头像", current: draft.avatarSymbol,
                      values: ["person", "star", "sun.max", "moon", "leaf", "pawprint"], label: {
                ["person": "人物", "star": "星星", "sun.max": "太阳", "moon": "月亮", "leaf": "叶子", "pawprint": "爪印"][$0] ?? $0
            }) { [weak self] in
                guard let self else { return }
                self.draft.avatarSymbol = $0
                self.saveProfile(leaving: false)
            },
            choiceRow("年级", current: curriculum.grade, values: Array(1...12), label: { "\($0) 年级" }) { [weak self] in
                guard let self else { return }
                self.draft.curriculum.grade = $0
                self.saveProfile(leaving: false)
            },
            toggleRow("启用档案", draft.isEnabled) { [weak self] enabled in
                guard let self else { return }
                if !enabled, self.disablingNeedsConfirmation() {
                    self.confirmDisableProfile()
                    return
                }
                self.draft.isEnabled = enabled
                self.saveProfile(leaving: false)
            },
        ])]
        let familyMinutes = Int((familyEnvironment.snapshot?.configuration.dailyLimitMilliseconds ?? 240 * 60_000) / 60_000)
        var quotaMinutes = Array(stride(from: 15, through: max(15, min(240, familyMinutes)), by: 15))
        if familyMinutes > 0, familyMinutes <= 240, !quotaMinutes.contains(familyMinutes) {
            quotaMinutes.append(familyMinutes)
            quotaMinutes.sort()
        }
        let watched = familyEnvironment.snapshot?.personalActualMilliseconds[draft.id, default: 0] ?? 0
        var quotaRows = [durationRow("个人每日额度", current: draft.dailyLimitMilliseconds,
                                    minutes: quotaMinutes) { [weak self] in
            guard let self else { return }
            self.draft.dailyLimitMilliseconds = $0
            self.saveProfile(leaving: false)
        }]
        quotaRows.append(information("实际可用额度", "取个人与家庭较小值",
            message: "家庭共享每天最多 \(familyMinutes) 分钟；孩子实际可用取个人额度与家庭剩余中的较小值。个人额度高于家庭额度时不会多出时间。"))
        if watched > draft.dailyLimitMilliseconds {
            quotaRows.append(information("今天已看 \(durationLabel(watched))", "已超过新额度",
                message: "降低个人额度不会清空今天已看的时间；保存后孩子的下一次播放检查会立即按新额度停止。"))
        }
        sections.append(group("观看额度", quotaRows))
        // Subjects are a simple checklist; every enabled subject always uses the
        // full general-knowledge bank. No textbook or chapter picking.
        sections.append(group("答题科目 · 可选", [
            row("选择科目", curriculum.subjects.isEmpty ? "未启用" : "\(curriculum.subjects.count) 科 · 全章节") { [weak self] in self?.openSubjects() },
        ]))
        var informationRows = [information("说明", message: "改哪项就立即生效，不需要保存。开启强制答题时，孩子所选科目必须有足够题目。")]
        if catalogLoading {
            informationRows.append(row("题库目录", "加载中"))
        } else if let catalogError {
            informationRows.append(information("题库目录", "不可用 · 查看原因", message: catalogError))
            informationRows.append(row("重试加载题库目录") { [weak self] in self?.loadCatalog() })
        }
        if let error = familyEnvironment.errorMessage {
            informationRows.append(information("家庭账本", "不可用 · 查看原因", message: error))
        }
        sections.append(group("信息", informationRows))
        if originalID != nil {
            sections.append(group("档案管理", [row("删除该孩子", "保留历史") { [weak self] in self?.confirmDelete() }]))
        }
        sections = errorSections() + sections
        sections.append(doneSection())
        render(sections)
    }

    /// Chinese school calendar: Sep–Jan is the first term of year–year+1,
    /// Feb–Jun the second; July/August matches the whole academic year so
    /// quizzes keep working through the summer break.
    static func autoAcademicTerm(from date: Date = Date()) -> (year: String, semester: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        switch month {
        case 9...12: return ("\(year)-\(year + 1)", "上")
        case 1: return ("\(year - 1)-\(year)", "上")
        case 7, 8: return ("\(year - 1)-\(year)", "全年")
        default: return ("\(year - 1)-\(year)", "下")
        }
    }

    private func termLabel(_ curriculum: CurriculumProfile) -> String {
        let year = curriculum.academicYear.isEmpty ? "自动" : curriculum.academicYear
        let semester = ["上": "上学期", "下": "下学期", "全年": "全年"][curriculum.semester] ?? curriculum.semester
        return "\(year) · \(semester)"
    }

    private func openSubjects() {
        guard !saving else { return }
        guard !catalogLoading else {
            showMessage(title: "题库目录", message: "目录正在加载，请稍后再试。")
            return
        }
        let page = FamilyNativeSubjectsPage(curriculum: draft.curriculum, catalog: catalog, catalogError: catalogError) { [weak self] curriculum in
            guard let self else { return }
            self.draft.curriculum.subjects = curriculum.subjects
            self.draft.curriculum.subjectTextbookVersions = curriculum.subjectTextbookVersions
            self.draft.curriculum.learnedChapters = curriculum.learnedChapters
            // Checklist changes are saved immediately; no separate confirmation.
            self.saveProfile(leaving: false)
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// Disabling the last enabled child (or the current viewer) stops playback
    /// immediately, so it must not be a single silent toggle.
    private func disablingNeedsConfirmation() -> Bool {
        guard draft.isEnabled, originalID != nil,
              let snapshot = familyEnvironment.snapshot else { return false }
        let enabled = snapshot.profiles.filter(\.isEnabled)
        let lastEnabled = enabled.count <= 1 && enabled.contains { $0.id == draft.id }
        return lastEnabled || snapshot.activeViewerIDs.contains(draft.id)
    }

    private func confirmDisableProfile() {
        let snapshot = familyEnvironment.snapshot
        let isCurrentViewer = snapshot?.activeViewerIDs.contains(draft.id) == true
        let enabled = snapshot?.profiles.filter(\.isEnabled) ?? []
        let isLastEnabled = enabled.count <= 1 && enabled.contains { $0.id == draft.id }
        var sentences = [String]()
        if isCurrentViewer { sentences.append("停用后会立即退出当前观看者。") }
        if isLastEnabled { sentences.append("这是最后一个启用的孩子，儿童模式将没有可观看的孩子，无法播放。") }
        sentences.append("历史记录会保留。")
        let alert = UIAlertController(title: "停用这个孩子？",
            message: sentences.joined(separator: ""),
            preferredStyle: .alert)
        let cancel = UIAlertAction(title: "取消", style: .cancel)
        let confirm = UIAlertAction(title: "仍要停用", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.draft.isEnabled = false
            self.saveProfile(leaving: false)
        }
        alert.addAction(confirm)
        alert.addAction(cancel)
        alert.preferredAction = cancel
        present(alert, animated: true)
    }

    private func saveProfile(leaving: Bool = true) {
        var edited = draft
        let hasName = !edited.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A brand-new draft without a nickname cannot be stored yet. Only warn on
        // an explicit completion, never on every keystroke.
        guard hasName else {
            if leaving { showMessage(title: "还没填昵称", message: "请先输入孩子昵称。其他选项已经记在草稿里。") }
            return
        }
        // Keep an existing semester even when the optional legacy year is blank.
        let term = Self.autoAcademicTerm()
        if edited.curriculum.academicYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edited.curriculum.academicYear = term.year
        }
        if edited.curriculum.semester.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edited.curriculum.semester = term.semester
        }
        let existingID = originalID
        commit(.manageProfiles, leaving: leaving) { ledger, authorization in
            let latest = try await ledger.snapshot()
            var profile = edited
            if let existingID {
                guard let existing = latest.profiles.first(where: { $0.id == existingID }) else {
                    throw LedgerError.invalidInput("该档案已不存在，请返回检查。")
                }
                profile = existing
            }
            // Merge only editable fields into the freshest profile, preserving progress/schema metadata.
            var curriculum = profile.curriculum
            let editedCurriculum = edited.curriculum
            let primaryLastGrade = ["五四", "五四制", "5_4"].contains(editedCurriculum.schoolSystem) ? 5 : 6
            if existingID == nil || curriculum.grade != editedCurriculum.grade || curriculum.schoolSystem != editedCurriculum.schoolSystem {
                curriculum.schoolStage = editedCurriculum.grade <= primaryLastGrade ? "小学" : editedCurriculum.grade <= 9 ? "初中" : "高中"
            }
            curriculum.schoolSystem = editedCurriculum.schoolSystem
            curriculum.grade = editedCurriculum.grade
            curriculum.academicYear = editedCurriculum.academicYear
            curriculum.semester = editedCurriculum.semester
            curriculum.subjects = editedCurriculum.subjects
            curriculum.subjectTextbookVersions = editedCurriculum.subjectTextbookVersions
            curriculum.learnedChapters = editedCurriculum.learnedChapters
            profile.displayName = edited.displayName
            profile.avatarSymbol = edited.avatarSymbol
            profile.curriculum = curriculum
            profile.dailyLimitMilliseconds = edited.dailyLimitMilliseconds
            profile.isEnabled = edited.isEnabled
            try Self.validateRequiredQuiz(latest.configuration.quizRules, profiles: [profile])
            try await ledger.upsertProfile(profile, credential: authorization.credential)
            // The ledger itself makes the first enabled child the initial
            // viewer (atomic, never overriding an existing choice).
            let savedProfile = profile
            return { $0.profiles.first { $0.id == savedProfile.id } == savedProfile }
        }
    }

    override func flushPendingAutoSave() { saveProfile(leaving: false) }

    private func confirmDelete() {
        guard !saving, let id = originalID else { return }
        let alert = UIAlertController(title: "删除 \(draft.displayName)？", message: "历史账本与学习记录会保留。确认后需要重新输入家长 PIN。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确认删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.commit(.manageProfiles, authorize: self.requestHighRiskAuthorization) { ledger, authorization in
                try await ledger.deleteProfile(id, credential: authorization.credential)
                return { snapshot in !snapshot.profiles.contains { $0.id == id } }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

private final class FamilyNativeSubjectsPage: FamilyNativeEditorPage {
    private var curriculum = CurriculumProfile(schoolStage: "小学", schoolSystem: "六三", grade: 4, academicYear: "", semester: "全年")
    private var catalog = [FamilyQuestionBank.CatalogItem]()
    private var catalogError: String?
    private var apply: ((CurriculumProfile) -> Void)?

    convenience init(curriculum: CurriculumProfile, catalog: [FamilyQuestionBank.CatalogItem],
                     catalogError: String?, onSave: @escaping (CurriculumProfile) -> Void) {
        self.init()
        self.curriculum = curriculum
        self.catalog = catalog
        self.catalogError = catalogError
        apply = onSave
        navigationItem.title = "答题科目"
    }

    override func reloadSettings() {
        // One checklist only. Enabling a subject always means the whole general
        // bank for that grade; there is no textbook or chapter choice.
        let subjects = Set(catalog.filter { $0.grade == curriculum.grade }.map(\.subject))
            .union(curriculum.subjects).sorted()
        let items = subjects.map { subject in
            toggleRow(subject, curriculum.subjects.contains(subject)) { [weak self] enabled in
                guard let self else { return }
                var subjects = Set(self.curriculum.subjects)
                if enabled {
                    subjects.insert(subject)
                    self.curriculum.subjectTextbookVersions[subject] = "general_knowledge"
                    self.curriculum.learnedChapters[subject] = ["*"]
                } else {
                    subjects.remove(subject)
                    // Keep the per-subject chapter record. It is ignored while the
                    // subject is off, and re-enabling restores the full bank below.
                }
                self.curriculum.subjects = subjects.sorted()
                self.apply?(self.curriculum)
            }
        }
        var sections = [group("勾选要考的科目", items.isEmpty
            ? [information("暂无该年级题库", message: "可以先用默认额度观看；导入对应年级题库后再勾选科目。")] : items)]
        sections.append(group("信息", [information("说明", message: "勾选即启用该科目的整套通用题，不需要再选教材和章节。改选后立即生效。")]))
        if let catalogError {
            sections.append(group("信息", [information("题库目录", "不可用 · 查看原因", message: catalogError)]))
        }
        sections.append(doneSection("完成"))
        render(sections)
    }
}

/// Two-step hour/minute picker for schedule boundaries. Every selection is
/// written immediately; an invalid combination is rejected by the parent page
/// and the picker keeps the previous valid value.
private final class FamilyClockChoicePage: FamilyNativeEditorPage {
    private let settingTitle: String
    private var hour: Int
    private var minute: Int
    private let onSelect: (Int) -> Bool
    private var didRequestInitialFocus = false

    init(title: String, current: Int, onSelect: @escaping (Int) -> Bool) {
        settingTitle = title
        hour = min(24, max(0, current / 60))
        minute = max(0, min(59, current % 60))
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var hourTitle: String { String(format: "%02d 时", hour) }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard let dataSource else { return super.preferredFocusEnvironments }
        let snapshot = dataSource.snapshot()
        if let item = snapshot.itemIdentifiers.first(where: { $0.title == hourTitle }),
           let path = dataSource.indexPath(for: item),
           let cell = collectionView.cellForItem(at: path) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didRequestInitialFocus, let dataSource else { return }
        didRequestInitialFocus = true
        let snapshot = dataSource.snapshot()
        guard let item = snapshot.itemIdentifiers.first(where: { $0.title == hourTitle }),
              let path = dataSource.indexPath(for: item) else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func reloadSettings() {
        let hours = (0...24).map { value in
            row(String(format: "%02d 时", value), value == hour ? "✓" : "") { [weak self] in
                guard let self else { return }
                let previousHour = self.hour
                let previousMinute = self.minute
                self.hour = value
                if value == 24 { self.minute = 0 }
                let applied = self.onSelect(self.hour * 60 + self.minute)
                if !applied {
                    self.hour = previousHour
                    self.minute = previousMinute
                }
                self.reloadSettings()
                if !applied {
                    self.setNeedsFocusUpdate()
                    self.updateFocusIfNeeded()
                }
            }
        }
        var minuteValues = hour == 24 ? [0] : [0, 15, 30, 45]
        if hour != 24, !minuteValues.contains(minute) {
            minuteValues.append(minute)
            minuteValues.sort()
        }
        let minutes = minuteValues.map { value in
            row(String(format: "%02d 分", value), value == minute ? "✓" : "") { [weak self] in
                guard let self else { return }
                let previousMinute = self.minute
                self.minute = value
                let applied = self.onSelect(self.hour * 60 + self.minute)
                if !applied {
                    self.minute = previousMinute
                }
                self.reloadSettings()
                if !applied {
                    self.setNeedsFocusUpdate()
                    self.updateFocusIfNeeded()
                }
            }
        }
        let current = String(format: "%02d:%02d", hour, minute)
        render([
            group("小时", hours),
            group("分钟", minutes),
            group("信息", [information("当前选择", current, message: "\(settingTitle)：先选小时，再选分钟。每次选择都会立即生效。")]),
            doneSection("完成")
        ])
    }
}

final class FamilyNativeRulesEditor: FamilyNativeEditorPage {
    enum Section { case watch, quiz }
    private var section: Section = .watch
    private var configuration = FamilyConfiguration()
    private var originalConfiguration = FamilyConfiguration()
    private static let defaultQuiz = QuizRules(quizAfterRest: false, familyAbsoluteTotalMilliseconds: 240 * 60_000)
    private var quiz = FamilyNativeRulesEditor.defaultQuiz
    private var quizEnabled = false
    private var dirty = false
    private var loaded = false
    private var loading = false
    private var loadError: String?
    private var weekdayEnabled = false
    private var weekdayStart = 480
    private var weekdayEnd = 1140
    private var weekendEnabled = false
    private var weekendStart = 480
    private var weekendEnd = 1200
    private var bedtimeEnabled = false
    private var bedtimeStart = 1320
    private var bedtimeEnd = 420

    convenience init(environment: FamilyEnvironment, section: Section,
                     authorize: @escaping FamilyAuthorize, onSaved: @escaping () -> Void) {
        self.init()
        familyEnvironment = environment
        requestAuthorization = authorize
        didSave = onSaved
        self.section = section
        if let configuration = environment.snapshot?.configuration { populate(configuration) }
        navigationItem.title = section == .watch ? "观看规则" : "答题与奖励"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !dirty, !saving { loadConfiguration() }
    }

    override func draftDidChange() { dirty = true }

    private func populate(_ configuration: FamilyConfiguration) {
        self.configuration = configuration
        originalConfiguration = configuration
        quizEnabled = configuration.quizRules != nil
        quiz = configuration.quizRules ?? Self.defaultQuiz
        weekdayEnabled = false
        weekdayStart = 480
        weekdayEnd = 1140
        weekendEnabled = false
        weekendStart = 480
        weekendEnd = 1200
        bedtimeEnabled = false
        bedtimeStart = 1320
        bedtimeEnd = 420
        if let window = configuration.schedule?.weekday {
            weekdayEnabled = true
            weekdayStart = window.startMinuteOfDay
            weekdayEnd = window.endMinuteOfDay
        }
        if let window = configuration.schedule?.weekend {
            weekendEnabled = true
            weekendStart = window.startMinuteOfDay
            weekendEnd = window.endMinuteOfDay
        }
        if let window = configuration.schedule?.bedtimeWindow {
            bedtimeEnabled = true
            bedtimeStart = window.start
            bedtimeEnd = window.end
        }
        dirty = false
        loaded = true
    }

    private func loadConfiguration() {
        guard !loading, !dirty, !saving else { return }
        loading = true
        loaded = false
        loadError = nil
        reloadSettings()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.familyEnvironment.refreshVerified()
                // A choice may have completed while the read was suspended.
                if !self.dirty { self.populate(snapshot.configuration) }
                else { self.loaded = true }
            } catch {
                self.loadError = "无法读取当前规则，请重试。"
            }
            self.loading = false
            self.reloadSettings()
        }
    }

    override func reloadSettings() {
        guard loaded else {
            var items = [information("家庭规则", loading ? "加载中" : "尚未加载", message: loadError ?? "正在读取现有规则。")]
            if !loading { items.append(row("重新加载规则") { [weak self] in self?.loadConfiguration() }) }
            render([group("信息", items), group("操作", [row("取消") { [weak self] in self?.leaveEditor() }])])
            return
        }
        var sections = errorSections()
        sections += (section == .watch ? watchSections() : quizSections())
        sections.append(doneSection())
        render(sections)
    }

    /// Each row applies immediately. Invalid combinations are rejected before
    /// the draft changes, so leaving the page can never silently drop an edit.
    private func watchSections() -> [SectionModel] {
        let limits = [
            durationRow("每天最多看多久", current: configuration.dailyLimitMilliseconds,
                        minutes: Array(stride(from: 15, through: 240, by: 15))) { [weak self] in
                guard let self else { return }
                self.configuration.dailyLimitMilliseconds = $0
                self.saveRules(leaving: false)
            },
            durationRow("连续看多久需要休息", current: configuration.continuousLimitMilliseconds,
                        minutes: Array(stride(from: 5, through: 90, by: 5))) { [weak self] in
                guard let self else { return }
                self.configuration.continuousLimitMilliseconds = $0
                self.saveRules(leaving: false)
            },
            durationRow("每次休息多长时间", current: configuration.restMilliseconds,
                        minutes: Array(stride(from: 5, through: 60, by: 5))) { [weak self] in
                guard let self else { return }
                self.configuration.restMilliseconds = $0
                self.saveRules(leaving: false)
            },
        ]
        var weekday = [scheduleToggleRow("限制工作日观看时段", weekdayEnabled) { [weak self] in
            guard let self else { return }
            self.weekdayEnabled = $0
            self.saveRules(leaving: false)
        }]
        if weekdayEnabled {
            weekday += [clockRow("工作日开始", weekdayStart) { [weak self] proposed in
                guard let self else { return false }
                guard proposed < self.weekdayEnd else {
                    self.showMessage(title: "没有生效", message: "工作日开始必须早于结束。")
                    return false
                }
                self.weekdayStart = proposed
                self.saveRules(leaving: false)
                return true
            },
                        clockRow("工作日结束", weekdayEnd) { [weak self] proposed in
                guard let self else { return false }
                guard proposed > self.weekdayStart else {
                    self.showMessage(title: "没有生效", message: "工作日结束必须晚于开始。")
                    return false
                }
                self.weekdayEnd = proposed
                self.saveRules(leaving: false)
                return true
            }]
        }
        var weekend = [scheduleToggleRow("限制周末观看时段", weekendEnabled) { [weak self] in
            guard let self else { return }
            self.weekendEnabled = $0
            self.saveRules(leaving: false)
        }]
        if weekendEnabled {
            weekend += [clockRow("周末开始", weekendStart) { [weak self] proposed in
                guard let self else { return false }
                guard proposed < self.weekendEnd else {
                    self.showMessage(title: "没有生效", message: "周末开始必须早于结束。")
                    return false
                }
                self.weekendStart = proposed
                self.saveRules(leaving: false)
                return true
            },
                        clockRow("周末结束", weekendEnd) { [weak self] proposed in
                guard let self else { return false }
                guard proposed > self.weekendStart else {
                    self.showMessage(title: "没有生效", message: "周末结束必须晚于开始。")
                    return false
                }
                self.weekendEnd = proposed
                self.saveRules(leaving: false)
                return true
            }]
        }
        var bedtime = [toggleRow("晚上禁止观看", bedtimeEnabled) { [weak self] in
            guard let self else { return }
            self.bedtimeEnabled = $0
            self.saveRules(leaving: false)
        }]
        if bedtimeEnabled {
            bedtime += [clockRow("开始禁止", bedtimeStart) { [weak self] proposed in
                guard let self else { return false }
                guard proposed != self.bedtimeEnd else {
                    self.showMessage(title: "没有生效", message: "睡前禁看的开始与结束不能相同。")
                    return false
                }
                self.bedtimeStart = proposed
                self.saveRules(leaving: false)
                return true
            },
                        clockRow("解除禁止", bedtimeEnd) { [weak self] proposed in
                guard let self else { return false }
                guard proposed != self.bedtimeStart else {
                    self.showMessage(title: "没有生效", message: "睡前禁看的开始与结束不能相同。")
                    return false
                }
                self.bedtimeEnd = proposed
                self.saveRules(leaving: false)
                return true
            }]
        }
        return [group("每天看多久、多久休息", limits), group("工作日时段 · 可选限制", weekday), group("周末时段 · 可选限制", weekend), group("睡前", bedtime),
                group("信息", [information("说明", message: "改哪一项就立即生效，不用保存。关闭时段限制只取消几点观看的限制，每天额度和连续休息仍然有效。")])]
    }

    private func scheduleToggleRow(_ title: String, _ enabled: Bool,
                                   onChange: @escaping (Bool) -> Void) -> CellModel {
        row(title, enabled ? "开 · 按下面时段" : "关 · 不限制时段") { [weak self] in
            guard let self else { return }
            onChange(!enabled)
            self.reloadSettings()
        }
    }

    /// Time is chosen in two steps (hour, then minute). A flat list of 97
    /// quarter-hour values forced the parent to walk down from 00:00 every time.
    private func clockRow(_ title: String, _ current: Int, onChange: @escaping (Int) -> Bool) -> CellModel {
        row(title, String(format: "%02d:%02d", current / 60, current % 60)) { [weak self] in
            guard let self else { return }
            let page = FamilyClockChoicePage(title: title, current: current) { [weak self] proposed in
                guard let self else { return false }
                guard onChange(proposed) else { return false }
                self.reloadSettings()
                return true
            }
            self.navigationController?.pushViewController(page, animated: true)
        }
    }

    private func quizSections() -> [SectionModel] {
        var sections = [group("答题开关", [toggleRow("开启答题奖励", quizEnabled) { [weak self] in
            guard let self else { return }
            self.quizEnabled = $0
            self.applyQuizChange()
        }])]
        if quizEnabled {
            sections.append(group("答题时机", [
                toggleRow("每天第一次看之前先答题", quiz.quizBeforeFirstWatch) { [weak self] in
                    guard let self else { return }
                    self.quiz.quizBeforeFirstWatch = $0
                    self.applyQuizChange()
                },
                toggleRow("每次休息结束后再答题", quiz.quizAfterRest) { [weak self] in
                    guard let self else { return }
                    self.quiz.quizAfterRest = $0
                    self.applyQuizChange()
                },
            ]))
            sections.append(group("题目要求", [
                choiceRow("每轮题数", current: quiz.questionsPerRound, values: Array(1...10), label: { "\($0) 题" }) { [weak self] in
                    guard let self else { return }
                    self.quiz.questionsPerRound = $0
                    self.applyQuizChange()
                },
                choiceRow("通过正确率", current: quiz.passRatio, values: [50, 60, 70, 80, 90, 100].map { Double($0) / 100 }, label: {
                    NSDecimalNumber(string: String($0)).multiplying(by: NSDecimalNumber(value: 100)).stringValue + "%"
                }) { [weak self] in
                    guard let self else { return }
                    self.quiz.passRatio = $0
                    self.applyQuizChange()
                },
            ]))
            sections.append(group("奖励上限", [
                choiceRow("每次奖励时长", current: quiz.rewardMinutes, values: [5, 10, 15, 20, 30], label: { "\($0) 分钟" }) { [weak self] in
                    guard let self else { return }
                    self.quiz.rewardMinutes = $0
                    self.applyQuizChange()
                },
                choiceRow("每个孩子每天最多奖励", current: quiz.personalDailyRewards, values: Array(0...10), label: { "\($0) 次" }) { [weak self] in
                    guard let self else { return }
                    self.quiz.personalDailyRewards = $0
                    self.applyQuizChange()
                },
                durationRow("全家每天最多奖励时长", current: quiz.maxFamilyDailyRewardMilliseconds, minutes: [0, 15, 30, 45, 60, 90, 120]) { [weak self] in
                    guard let self else { return }
                    self.quiz.maxFamilyDailyRewardMilliseconds = $0
                    self.applyQuizChange()
                },
                durationRow("全家含奖励的绝对上限", current: quiz.familyAbsoluteTotalMilliseconds, minutes: [60, 90, 120, 150, 180, 240, 300, 360]) { [weak self] in
                    guard let self else { return }
                    self.quiz.familyAbsoluteTotalMilliseconds = $0
                    self.applyQuizChange()
                },
            ]))
        }
        sections.append(group("信息", [information("说明", message: "改哪一项就立即生效。奖励不会跳过强制休息和禁看时段。")]))
        return sections
    }

    /// Reject an unusable required-quiz configuration before it is written.
    /// Reads the ledger rather than a possibly stale published snapshot so a
    /// child added moments ago is already included in the check.
    private func applyQuizChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let ledger = self.familyEnvironment.ledger else { throw LedgerError.closed }
                let state = try await ledger.snapshot()
                try Self.validateRequiredQuiz(self.quizEnabled ? self.quiz : nil, profiles: state.profiles)
            } catch {
                // Restore the switches to what is actually stored, not the rejected draft.
                if let config = try? await self.familyEnvironment.ledger?.snapshot().configuration {
                    self.quiz = config.quizRules ?? Self.defaultQuiz
                    self.quizEnabled = config.quizRules != nil
                }
                self.showInlineError("没有生效", "题库未就绪：请勾选答题科目，或关闭强制答题")
                return
            }
            // A valid change is written immediately; any write failure is shown
            // by the shared auto-save path with the stored value restored.
            self.saveRules(leaving: false)
        }
    }

    private static func merge<Value: Equatable, Model>(_ field: WritableKeyPath<Model, Value>,
                                                       edited: Model, original: Model, into latest: inout Model) {
        if edited[keyPath: field] != original[keyPath: field] {
            latest[keyPath: field] = edited[keyPath: field]
        }
    }

    private static func mergeWindow(_ edited: DailyScheduleWindow?, original: DailyScheduleWindow?,
                                    latest: DailyScheduleWindow?) throws -> DailyScheduleWindow? {
        guard edited != original else { return latest }
        guard let edited, let original else { return edited }
        guard var latest else {
            throw LedgerError.invalidInput("该时段已在其他入口关闭，请返回后重新编辑。")
        }
        merge(\.startMinuteOfDay, edited: edited, original: original, into: &latest)
        merge(\.endMinuteOfDay, edited: edited, original: original, into: &latest)
        return latest
    }

    override func flushPendingAutoSave() { saveRules(leaving: false) }

    private func saveRules(leaving: Bool = true) {
        guard loaded, !loading else { return }
        let edited = configuration
        let original = originalConfiguration
        let editedQuiz = quiz
        let enableQuiz = quizEnabled
        let editingSection = section
        let schedule = FamilySchedule(
            weekday: weekdayEnabled ? DailyScheduleWindow(startMinuteOfDay: weekdayStart, endMinuteOfDay: weekdayEnd) : nil,
            weekend: weekendEnabled ? DailyScheduleWindow(startMinuteOfDay: weekendStart, endMinuteOfDay: weekendEnd) : nil,
            bedtimeStartMinute: bedtimeEnabled ? bedtimeStart : nil,
            bedtimeEndMinute: bedtimeEnabled ? bedtimeEnd : nil)
        commit(.configureRules, leaving: leaving) { ledger, authorization in
            // Fetch AFTER PIN, then apply only fields changed in this section's draft.
            let snapshot = try await ledger.snapshot()
            var latest = snapshot.configuration
            switch editingSection {
            case .watch:
                Self.merge(\.dailyLimitMilliseconds, edited: edited, original: original, into: &latest)
                Self.merge(\.continuousLimitMilliseconds, edited: edited, original: original, into: &latest)
                Self.merge(\.restMilliseconds, edited: edited, original: original, into: &latest)
                // Timezone and hidden configuration fields are never edited here.
                let originalSchedule = original.schedule ?? FamilySchedule()
                var merged = latest.schedule ?? FamilySchedule()
                merged.weekday = try Self.mergeWindow(schedule.weekday, original: originalSchedule.weekday, latest: merged.weekday)
                merged.weekend = try Self.mergeWindow(schedule.weekend, original: originalSchedule.weekend, latest: merged.weekend)
                if (schedule.bedtimeWindow != nil) != (originalSchedule.bedtimeWindow != nil) {
                    merged.bedtimeStartMinute = schedule.bedtimeStartMinute
                    merged.bedtimeEndMinute = schedule.bedtimeEndMinute
                } else if schedule.bedtimeWindow != nil &&
                    (schedule.bedtimeStartMinute != originalSchedule.bedtimeStartMinute || schedule.bedtimeEndMinute != originalSchedule.bedtimeEndMinute) {
                    guard merged.bedtimeWindow != nil else {
                        throw LedgerError.invalidInput("睡前禁看已在其他入口关闭，请返回后重新编辑。")
                    }
                    Self.merge(\.bedtimeStartMinute, edited: schedule, original: originalSchedule, into: &merged)
                    Self.merge(\.bedtimeEndMinute, edited: schedule, original: originalSchedule, into: &merged)
                }
                if merged != (latest.schedule ?? FamilySchedule()) {
                    latest.schedule = merged == FamilySchedule() ? nil : merged
                }
                if [merged.weekday, merged.weekend].compactMap({ $0 }).contains(where: { $0.startMinuteOfDay >= $0.endMinuteOfDay }) {
                    throw LedgerError.invalidInput("允许时段的开始必须早于结束；请核对当前时段。")
                }
                if let bedtime = merged.bedtimeWindow, bedtime.start == bedtime.end {
                    throw LedgerError.invalidInput("睡前禁看的开始与结束不能相同。")
                }
            case .quiz:
                let originalQuiz = original.quizRules ?? Self.defaultQuiz
                if enableQuiz != (original.quizRules != nil) || (enableQuiz && editedQuiz != originalQuiz) {
                    if enableQuiz {
                        guard latest.quizRules != nil || original.quizRules == nil else {
                            throw LedgerError.invalidInput("答题奖励已在其他入口关闭，请返回后重新编辑。")
                        }
                        var rules = latest.quizRules ?? editedQuiz
                        Self.merge(\.questionsPerRound, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.passRatio, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.rewardMinutes, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.personalDailyRewards, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.quizBeforeFirstWatch, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.quizAfterRest, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.maxFamilyDailyRewardMilliseconds, edited: editedQuiz, original: originalQuiz, into: &rules)
                        Self.merge(\.familyAbsoluteTotalMilliseconds, edited: editedQuiz, original: originalQuiz, into: &rules)
                        latest.quizRules = rules
                    } else { latest.quizRules = nil }
                }
                try Self.validateRequiredQuiz(latest.quizRules, profiles: snapshot.profiles)
            }
            try await ledger.configureFamily(latest, credential: authorization.credential)
            let savedConfiguration = latest
            return { $0.configuration == savedConfiguration }
        }
        didCommit = { [weak self] snapshot in
            guard let self else { return }
            self.configuration = snapshot.configuration
            self.originalConfiguration = snapshot.configuration
            self.quiz = snapshot.configuration.quizRules ?? Self.defaultQuiz
            self.quizEnabled = snapshot.configuration.quizRules != nil
            // Auto-save has no draft left over once the ledger confirms the row.
            // Keeping dirty=true here would permanently block reloads on re-entry.
            self.dirty = false
            self.reloadSettings()
        }
        didFail = { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.populate(snapshot.configuration)
            self.reloadSettings()
        }
    }
}

final class FamilyNativeParticipantsEditor: FamilyNativeEditorPage {
    private var profiles = [ViewerProfile]()
    private var selection = Set<UUID>()
    private var actualViewerIDs = [UUID]()
    private var sessionLocked = false
    private var loaded = false
    private var loading = false
    private var loadError: String?

    convenience init(environment: FamilyEnvironment, authorize: @escaping FamilyAuthorize, onSaved: @escaping () -> Void) {
        self.init()
        familyEnvironment = environment
        requestAuthorization = authorize
        didSave = onSaved
        if let snapshot = environment.snapshot { populate(snapshot) }
        didFail = { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.populate(snapshot)
            self.reloadSettings()
        }
        navigationItem.title = "多人观看"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !loaded { loadParticipants() }
    }

    private func populate(_ snapshot: LedgerSnapshot) {
        profiles = snapshot.profiles.filter(\.isEnabled)
        selection = Set(snapshot.activeViewerIDs)
        actualViewerIDs = snapshot.activeViewerIDs
        sessionLocked = snapshot.activeLease != nil
        loaded = true
    }

    private func loadParticipants() {
        guard !loading, !loaded else { return }
        loading = true
        loadError = nil
        reloadSettings()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.familyEnvironment.refresh()
            if let snapshot = self.familyEnvironment.snapshot { self.populate(snapshot) }
            else { self.loadError = self.familyEnvironment.errorMessage ?? "家庭账本尚未就绪，请重试。" }
            self.loading = false
            self.reloadSettings()
        }
    }

    override func reloadSettings() {
        guard loaded else {
            var rows = [information("参与者列表", loading ? "加载中" : "尚未加载", message: loadError ?? "正在读取已保存的参与者。")]
            if !loading { rows.append(row("重新加载参与者") { [weak self] in self?.loadParticipants() }) }
            render([group("信息", rows), group("操作", [row("取消") { [weak self] in self?.leaveEditor() }])])
            return
        }
        // Index prefixes also disambiguate equal nicknames in the original title-keyed data source.
        let choices = profiles.enumerated().map { index, profile in
            row("\(index + 1). \(profile.displayName)", selection.contains(profile.id) ? "✓ · 已勾选" : "未勾选") { [weak self] in
                guard let self, !self.saving else { return }
                var proposed = self.selection
                if proposed.contains(profile.id) { proposed.remove(profile.id) }
                else { proposed.insert(profile.id) }
                guard !proposed.isEmpty else {
                    self.showMessage(title: "至少留一个孩子", message: "取消最后一位孩子会让播放没有观看者，所以这次没有生效。")
                    return
                }
                self.selection = proposed
                self.saveParticipants()
                self.reloadSettings()
            }
        }
        let actualNames = actualViewerIDs.map { id in profiles.first { $0.id == id }?.displayName ?? "不可用档案" }.joined(separator: "、")
        var sections = [group("选择本次一起观看的孩子", choices.isEmpty ? [information("暂无启用的孩子", message: "请返回添加或启用孩子档案后再选择参与者。") ] : choices),
                        group("信息", [
                            information("当前已保存参与者", "\(actualViewerIDs.count) 人", message: actualNames.isEmpty ? "尚未选择参与者。" : actualNames),
                            information("参与者锁定", sessionLocked ? "会话进行中" : "勾选即生效", message: "勾选会立即保存。会话进行中不能改，需先停止播放。家庭共享额度只扣一次；任一参与者额度不足将停止全场。"),
                        ])]
        sections = errorSections() + sections
        sections.append(doneSection())
        render(sections)
    }

    override func flushPendingAutoSave() { saveParticipants() }

    private func saveParticipants() {
        guard loaded else { return }
        guard !selection.isEmpty else {
            showMessage(title: "尚未保存", message: "请至少选择一位孩子。")
            return
        }
        let selected = selection.sorted { $0.uuidString < $1.uuidString }
        commit(.manageSession, leaving: false) { ledger, authorization in
            let latest = try await ledger.snapshot()
            let enabled = Set(latest.profiles.filter(\.isEnabled).map(\.id))
            guard Set(selected).isSubset(of: enabled) else {
                throw LedgerError.invalidInput("所选孩子已被停用或删除，请返回检查。")
            }
            try await ledger.selectViewers(selected, credential: authorization.credential)
            return { Set($0.activeViewerIDs) == Set(selected) }
        }
    }
}
