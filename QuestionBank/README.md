# 离线题库与审核声明

## 当前内容（2026-11-06）

App 内置 `BilibiliLive/QuestionBank/grade4-general.json`，**80 道通用知识单选题**，不是精确教材同步题库。数学 40 题，语文、英语、科学、道德与法治各 10 题。准确上下学期分布和使用契约见 `../docs/QUESTION_BANK.md`。

这些题已作 **AI核对+结构校验，非教师/出版社审定，未逐教材匹配**。家长委托 AI 决定内容，不等于家长逐题审核，也不等于教师、出版社或法务批准。`reviewStatus=approved` 在这里仅表示允许此版本进入明确选择的通用知识练习池。

`fixtures/synthetic.test-only.json` 仍是测试数据，禁止改标充当真实内容。测试中模拟的人工审核记录只存在于测试内存，不是实际审核证据。

## 审核与许可边界

- `reviewType=ai`、`humanReviewed=false`、`textbookAlignmentVerified=false`，审核者明确标记 AI。
- 通用 AI 评估采用 `licenseStatus=ai_assessed`、`licenseVerified=false`，不得声称已取得法律许可确认或版权零风险。`licenseBasis` 记录具体依据和局限。
- 苏轼《题西林壁》、朱用纯《朱子家训》的古代原文属于公共领域；现代注释、译文、编排可能另有权利。不能因引用古诗文就声称“所有文字均原创”或“从未引用”。题库注明引用作者，不复制现代教材正文或注释；仅提作品名/作者不表示获出版社授权。
- `answersVerified/provenanceVerified=true` 在 AI 记录中只表示已进行本轮 AI 答案核对和来源声明检查，**不是独立人工验证**。
- `reviewedQuestionIDs` 覆盖全部题号；`contentSHA256` 绑定 `curriculum/questions`，防止误改内容后继续使用旧审核记录。它不是数字签名，不能阻止恶意填写者重新计算，也不能证明审核人身份、答案正确或许可真实。
- 无教材来源映射时 `sourceBook/sourcePage` 均为 null，不伪造教材页码。

## 精确教材门禁

精确教材不接受仅 AI 审核：需要真实人工审核声明、许可依据、`licenseStatus=cleared`、`textbookAlignmentVerified=true`、固定来源书与正整数 PDF 物理页码。来源逐项匹配固定 `repo/commit/path/blobsha/book_id` 索引；App 从 `Documents/QuestionBank/book-index.json` 读取索引，Python 使用 `--index`。缺索引、缺页码、分片 PDF 或版本不符一律拒绝，不回退通用知识。

应由实际审核人员合法取得材料并核对版次、目录、页码、答案、干扰项和授权条款，保留外部可审计凭据。GitHub 公开可见、书名或路径都不能证明教材版权或官方审定。索引不能证明 PDF 页数、页面内容和题目映射；填写完整声明也不自动证明真实性。

## 工具

- `question.schema.json`：结构契约。
- `../tools/questionbank/bank.py`：Python 标准库离线校验、导入和选择。
- `../tools/questionbank/test_bank.py`：50 个结构、语义及实际内容回归测试。
- `../tools/questionbank/test_runtime.py`：7 组 macOS Swift 回归，编译实际 App loader 与实际 Core 公共模型；不用 UIKit、不运行模拟器、不修改 Core。
- App loader 位于 `BilibiliLive/FamilyControl/FamilyQuestionBank.swift`，仅依赖 FamilyCore、Foundation/CoreFoundation、CryptoKit。

不分发教材 PDF 或 OCR 全文。真实精确教材题当前为 **0**；已有 80 道通用练习不应被描述为“已核实教材题”。
