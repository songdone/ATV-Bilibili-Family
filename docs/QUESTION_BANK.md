# 离线题库契约与严格筛选

## 当前内容与局限

`BilibiliLive/QuestionBank/grade4-general.json` 含 **80 道五科通用知识单选题**。2026-11-06 逐题作 AI 核对并修订明显错误/歧义；不是教师/出版社审定，未逐教材匹配，不保证每校教学进度或教材单元一致。精确教材题仍为 **0**。

| 科目 | first（上） | second（下） | 总计 |
| --- | ---: | ---: | ---: |
| 数学 | 18 | 22 | 40 |
| 语文 | 10 | 0 | 10 |
| 英语 | 7 | 3 | 10 |
| 科学 | 5 | 5 | 10 |
| 道德与法治 | 6 | 4 | 10 |
| 合计 | 46 | 34 | 80 |

这些学期/章节标签仅为题库分类，未为凑数改成 20/20 或虚构语文下学期覆盖。显式选择通用版“全年”可联合上、下学期；选“下”时语文无池会报错，不偷偷借用上学期。

内容修订包括：废镉镍电池按有害垃圾、钮扣电池遵本地指引，并澄清常见无汞碱性干电池通常属其他垃圾；人体呼出混合气体而非纯二氧化碳；烙饼可行排程与忽略换饼时间；矩形分类、四舍五入、长方体可见面条件；常压下水结冰、太阳能可持续获得；火警/急救的中国大陆地域限定。古诗文标作者，来源不明拟人例句已更换。

正确选项 ID 为 **A/B/C/D 各 20**（数学每个 10，其余科目每个 2–3）。`balance_options` 使用固定种子 `ATV-G4-options-v1`，按科目/学期分组、SHA256 排序、全局最少使用标签优先分配；平局以题号+标签 hash 打破。重排幂等、可复现，保持原正确答案文字及含义；不能单靠全选 A 刷到几乎全对。每轮 UI 选项呈现顺序还会随机化。此措施不能阻止记忆答案或偶然猜中，不代替账本限额/防重放。

## 审核证据

bank 必填 `schemaVersion/bankId/curriculum/testOnly/licenseStatus/reviewEvidence/questions`。结构禁止未知字段。`reviewEvidence` 必须明确：

- `reviewType`（ai/human）、`reviewedBy`、带时区非未来 `reviewedAt`；
- `humanReviewed`、`textbookAlignmentVerified`；
- `answersVerified/provenanceVerified/licenseVerified`、`licenseBasis`、`notes`；
- 全题号 `reviewedQuestionIDs` 与 `contentSHA256`。

摘要采用 `curriculum/questions` 对象的 UTF-8 JSON，键排序、无多余空白、不转义中文或斜线，再取 SHA256。当前允许的 runtime 内容结构没有浮点数。摘要用于发现内容变化，**不是签名或审核真实性证明**。

AI 通用题发布条件：answers/provenance 声明为 true，human/textbookAlignment/licenseVerified 为 false，licenseStatus 为 `ai_assessed`，notes 明确包含“AI核对+结构校验，非教师/出版社审定，未逐教材匹配”。不能用 AI 身份冒充人工或以 `cleared` 冒称法律许可核实。`approved` 表示此内容版本被允许进入通用练习，不等同人审。

实际题库涉及苏轼《题西林壁》、朱用纯《朱子家训》古代公共领域原文及常用语，不能宣称全篇文字原创、完全未引用或版权零风险。现代注释/版本可能另有权利。详见 bank 的 `licenseBasis` 和 `QuestionBank/README.md`。校验器不能验证外部授权文件、审核人身份、PDF 内容或法律结论。

人工精确教材必须 `humanReviewed=true`、`licenseVerified=true`、许可 `cleared`、`textbookAlignmentVerified=true`；需受控真实审核流程和固定索引。JSON 声明自身不能自动防伪。

## 单题契约

每题必含以下 18 字段：

`question_id/stage/system/grade/semester/subject/textbookVersion/chapter/knowledgePoints/difficulty/prompt/type/options/answer/explanation/sourceBook/sourcePage/reviewStatus`

- K12 用绝对年级：六三小学 1–6、初中 7–9；五四小学 1–5、初中 6–9；高中 10–12。未知不默认为六三制。
- `curriculum.kind=general_knowledge` 配 `alignment=not_exact_textbook`、每题 `textbookVersion=general_knowledge`；精确教材为 exact_textbook，禁止混淆。
- 题号在所有加载 bank 中全局唯一，bankId 也全局唯一；同一规范化/解析符号链接后的文件路径重复发现只加载一次。不同路径同题号拒绝，而非静默去题。
- `single_choice` 至少两项，唯一 option ID 和不同非空文本，答案是存在的 ID。`true_false` 恰好 true/false 两项。
- Draft schema 可表达多选和简答，当前 **App/Python runtime 仅支持单选、判断**；App runtime 仅支持 K12。导入验证不等于 runtime 验证。
- `sourceBook/sourcePage` 必须同时存在字段且同时为 null 或对象；精确教材 approved 时必须为对象。book_id 为 repo@commit:path 的 SHA256，来源与固定索引一致；pdfPage 为正整数物理页，禁止 bool/小数。无法由索引核实页码上限。
- `testOnly`、含任一未审/拒绝题、格式错误、重复 JSON key、审核摘要不符均整库拒绝，不部分返回。

## App 配置与目录 API

`FamilyQuestionBank.load()`、`questions(for:)`、`makeRound(for:perRound:)` 都会 throws，可显示 `localizedDescription`。保留 app bundle `QuestionBank` 与同步组展开后的根目录查找；根目录仅明确排除已知无关 `SupportConfig.json`。`Documents/QuestionBank` 存在但读取失败、bank 格式不合法不再静默忽略。精确教材索引单独命名为 `Documents/QuestionBank/book-index.json`。

`bank.catalog: [CatalogItem]` 提供已校验的可用 `curriculum/stage/system/grade/semester/subject/textbookVersion/chapters`，供家长选择；它不是完整教学目录。

Profile 必须明确配置：

- `academicYear` 非空非“待设置”（题库无学年版次，学年只做配置完整性检查）；
- `schoolStage`：小学/初中/高中或 primary/junior_secondary/senior_secondary；
- `schoolSystem`：六三/五四、六三制/五四制或 6_3/5_4；
- `grade`、`semester`：上/下/全年，上学期/下学期/全学年或 first/second/full_year；
- `subjects` 非空且不重复，空列表**不是全部**；
- `subjectTextbookVersions[subject]` 每科明确选择，`general_knowledge`/通用知识版才表示通用；不读取“通用”伪科目去兜底；
- `learnedChapters[subject]` 非空。`["*"]` 表示家长显式选择全章节；`[]` 是未配置，拒绝；`*` 不能与具体章节混用。否则仅命中已学章节。

选择逐项匹配 curriculum、stage、system、grade、semester、subject、textbookVersion、chapter。通用版全年可联合 first/second/full_year；精确教材全年不合并上下册。每个选中科目无匹配题都会报 `MISSING_POOL`，不静默丢科目。整体不足规则要求题数报 `INSUFFICIENT_POOL`，**不缩短本轮**。每轮 1–10 题；抽样为总池无放回随机，不保证每轮五科各一题。

## 答题 UI

`FamilyQuizViewController(environment:viewerIDs:onFinished:)` 支持多人按传入顺序分别答题，重复 viewerID 只安排一次；保留 childID 初始化入口。每位通过后才能进入下一位；不通过可重试新一轮或返回。完成/返回真正 dismiss 后调用回调，回调不是绕过播放 gate 的授权。

提交使用账本 `submitQuizRound(id:childID:answers:)`；失败保留 round ID 和答案重试。只显示真实账本结果，奖励只在返回的毫秒数大于零时显示为已入账；失败、零奖励和次数上限不能冒充领奖成功。结果页可查看全部题目答案/解释，错题每题一行，不因通过就隐藏。

测试标识：`quiz-question-<id>`、`quiz-option-<id>`、`quiz-outcome`、`quiz-reward`；每题重建选项焦点作用域，优先首个显示选项。实际 tvOS 遥控器焦点、滚动和 dismiss 体验尚未由本次任务验证。

## CLI 与验证

只使用 Python 标准库、绝对路径及隔离模式，不联网下载 schema 或教材。

```sh
PROJECT="$(git rev-parse --show-toplevel)"
python3 -I "$PROJECT/tools/questionbank/bank.py" validate \
  "$PROJECT/BilibiliLive/QuestionBank/grade4-general.json" --runtime

python3 -I "$PROJECT/tools/questionbank/bank.py" select \
  "$PROJECT/BilibiliLive/QuestionBank/grade4-general.json" \
  --curriculum general_knowledge --stage primary --system 6_3 --grade 4 \
  --semester full_year --subject 数学 --textbookVersion general_knowledge

python3 -I "$PROJECT/tools/questionbank/test_bank.py" -v
python3 -I "$PROJECT/tools/questionbank/test_runtime.py" -v
```

CLI `select` 是单科六维低层选择；`select_profile` Python API 对齐 App profile 与题数/章节语义。`import` 校验后写新文件，不自动审批且不覆盖。失败不输出新池；成功退出 0，结构/声明错误退出 2，无池退出 3。

本次 **50 个 Python 测试 + 7 组实际 Swift loader macOS 编译回归通过**，80 题 runtime validate 通过；`FamilyQuizView.swift` 通过 Swift 语法解析。Swift 回归在临时目录编译真实 Core 公共模型与实际 loader，不建假 loader，不修改 Core、不运行模拟器。未验证：全 App tvOS 构建/运行、奖励持久化与 gate 的端到端 UI（由核心/集成测试负责）、真实教材索引与 PDF 对应、独立人工审核与法律许可审定。
