# 固定提交教材书目索引

## 已取得的真实证据

2026-11-05 使用 `gh api`，共 **2 次**网络请求：

1. `repos/TapXWorld/ChinaTextbook/commits/HEAD`：提取 commit 与对应 root tree SHA；不保存完整 commit 响应。
2. `repos/TapXWorld/ChinaTextbook/git/trees/f8fdce04791c5c9a399d02bf78072c0f42c6710e?recursive=1`：仅保存递归 Git tree JSON。

固定 commit：`e2b3f62213c77bb8c33c5be355f97625ea1b8b61`。

tree SHA：`f8fdce04791c5c9a399d02bf78072c0f42c6710e`。

tree 原始 JSON SHA256：`e21ffc8fbce8b074717dcaed601109ec22e0680a10d3a9977b5237e400e2d83b`。

返回 `truncated=false`，因此该提交的**递归路径树**完整；这不是教材内容审核完整、不是官方教材全集，也不是题库完成。没有 clone，没有下载 PDF/DJVU/分片，没有读取上游脚本或执行任何下载物。

项目外 artifact 根目录由本地环境变量 `TEXTBOOK_ARTIFACT_DIR` 指定；公开文档不记录个人目录。以下均为该根目录内的相对路径：

- `downloads/tree.json`：唯一原始下载树，下载目录与工具脚本分离。
- `derived/book-index.json`：约 3.3 MB 的完整派生书目索引。
- `derived/statistics.json`：统计输出。
- `logs/questionbank-tests.log`、`logs/textbook-index-tests.log`：最终测试日志。

公开目录只保留 `tools/textbook-index/sources.json`（约 11 KB 的来源清单和统计）、schema、生成器及测试，不带完整大索引或 PDF。公开 manifest 的 artifact 定位字段均为 null，固定提交、SHA256 和覆盖统计仍保留；本地绝对定位仅存于项目外 `sources.local.json`。移交 artifact 时保留 SHA256，并设置 `TEXTBOOK_ARTIFACT_DIR` 进行真实树测试；未设置时显式 skip，设置后路径无效则测试失败，绝不联网补齐。生成器会更新传入的 manifest，因此离线复现只传项目外副本，不把本机路径写回公开清单。

## 覆盖统计

统计按实际路径发现；“书”是候选文档，不排除教师用书、练习、重复版本或非教材。

| 指标 | 数量 |
|---|---:|
| Git tree 全部条目 | 3,112 |
| 全部 blob | 2,375 |
| 索引文档 blob | 2,372 |
| 完整 `.pdf` 路径 | 1,905 |
| `.pdf.N` 分片 blob | 466 |
| `.djvu` 路径 | 1 |
| 逻辑文档路径分组 | 2,062 |
| 非书文件排除 | 3 |
| 已发现非空科目标签 | 26 |
| 已发现非空版本标签 | 157 |
| 四年级明确路径命中 blob | 123 |
| 四年级逻辑文档分组 | 116 |
| 待人工审核 blob | 2,372 |
| 内容已核实 / runtime 题目 | 0 / 0 |

分片以去掉数字尾缀后的文档路径分组；`.pdf_merge_folder` 包装目录被归一化到原文档位置，**不**将同目录下不同书合并。逻辑分组可能同时包含完整 PDF 和分片，计数不是内容去重，也不证明分片齐全。每个 blob 始终保留独立原始 path、blobsha 和 part。

| path-derived 学段 | blob 数 |
|---|---:|
| primary | 1,119 |
| junior_secondary | 618 |
| senior_secondary | 597 |
| higher_education | 19 |
| null（待分类） | 19 |

未知字段数量（可重叠）：stage **19**、system **2,236**、grade **981**、semester **650**、subject **19**、textbookVersion **29**、volume **114**。五四制有明确标识的 blob 为 136；普通小学/初中目录没有显式学制，不能因此自动填写六三制。高中必修/选修和第几册不推算成具体年级或学期。大学版次写在文件名但缺少明确版本目录时不猜版次。

## schema 与生成规则

`book-index.schema.json` 使用离线本地引用。book 必含 repo/commit/path/blobsha、基于 pinned provenance 的稳定 book_id、大小、格式/分片信息、原始路径段、`metadataBasis=path-derived` 及审核标记。

metadata 字段固定为 stage/system/grade/semester/subject/textbookVersion/volume，支持全学段数据结构；当前规则认识小学、初中、高中、大学、学前、中职、特殊教育。未知新顶层目录保留原样并标 null，不丢记录。科目与版本来自当前树的实际目录（版本目录需出现“版”），不是四年级、单学科或单版本白名单。年级/学制/上下册只读明确路径文本，冲突、年级范围和无标记保持 null 并加入 reviewFlags。

全部 `reviewStatus=needs_review`、`licenseStatus=needs_review`、`officialApproval=null`。即使路径有“统编版”“义务教育”，也不推断官方审定。固定 SHA 证明本次索引引用哪个 Git blob，不证明该内容合法或教学正确。

`status`：完整树且非空为 `tree_complete_content_unverified`；截断为 `partial_tree`；零候选为 `empty_inventory`。下载受阻为 `blocked` 并保留错误类型、请求次数，statistics 为空；不会宣称空索引完整。

## 命令与复现

```sh
PROJECT="$(git rev-parse --show-toplevel)"
# 在本机设置并 export TEXTBOOK_ARTIFACT_DIR 为项目外 artifact 根目录
ARTIFACT="${TEXTBOOK_ARTIFACT_DIR:?请先设置项目外 artifact 根目录}"

# 复制到项目外，避免生成器把本地绝对路径写回公开 manifest
cp "$PROJECT/tools/textbook-index/sources.json" "$ARTIFACT/sources.local.json"
# 已有原始树时只做离线生成；校验 tree SHA256 和 pinned tree SHA
python3 -I "$PROJECT/tools/textbook-index/build_index.py" \
  --tree "$ARTIFACT/downloads/tree.json" \
  --manifest "$ARTIFACT/sources.local.json" \
  --output "$ARTIFACT/derived/book-index.json"

TEXTBOOK_ARTIFACT_DIR="$ARTIFACT" python3 -I "$PROJECT/tools/textbook-index/test_index.py" -v
```

如**未来明确要刷新**，`fetch_tree.py --artifact-parent /ABS/OUTSIDE_PROJECT --manifest /ABS/NEW_MANIFEST.json` 会创建新的空下载目录并最多请求两次，不重试；先固定当时 HEAD，再读其 tree SHA。不要为了复现当前提交而刷新 HEAD。本次两次预算已用完，无需再运行下载命令。

原始下载与派生数据不作为 Python 模块；使用 `python3 -I` 从可信工具脚本运行并以参数传路径，不在下载目录执行解释器/构建工具。工具不下载或分发 PDF，后续合法材料提取、OCR、逐题答案复核与许可发布门禁见 `QuestionBank/README.md`。

## 四年级内容结论

有真实四年级**书目路径线索**，没有已核验四年级题目。上述 123 个 blob / 116 个逻辑分组不可当题目数，也不可据此声称版本、答案或教学适配通过。真实题库仍须人工逐书、逐题、逐页、逐答案与许可审核。
