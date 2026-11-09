# 公共源码导出与发布门禁

本工具只做本地源码快照和安全审查，不发布、不上传、不创建 Git 仓库/提交/标签/release，不继承源仓库历史，也不运行应用或 Xcode。`check` 成功仅表示当前静态门禁通过，**不是构建、真机或发布批准**。Actions 不应由本工具开启。

## 运行

Python 3.9+，仅标准库。必须用隔离模式，脚本来自经过审核的工具目录；不要在下载/解压的待审目录内启动解释器或运行其脚本。以下命令从工作树根目录使用。

```sh
python3 -I tools/release/test_public_source.py -v
python3 -I tools/release/public_source.py check --source "$PWD" --version 0.1.0-review
python3 -I tools/release/public_source.py dry-run --source "$PWD" --version 0.1.0-review
```

`check` 与 `dry-run` 执行相同审查并输出 JSON，不落盘。退出码：`0` 静态检查通过，`1` 有阻断项，`2` 参数、路径或 I/O/provenance 错误。报告包含逐文件 SHA256、排除路径、带行号的敏感命中及已批准窄例外，不回显秘密值。报告本身也含本地路径清单，应留在受控私有位置。

导出须人工指定**不存在的新目录**，连预先创建的空目录也拒绝；父目录必须已存在，必须在源工作树之外。以下是模板，运行前将变量指向实际的独立受控位置：

```sh
python3 -I tools/release/public_source.py export \
  --source "$PWD" --version 0.1.0-review \
  --output "$PUBLIC_STAGE/new-source" \
  --manifest "$PRIVATE_AUDIT/new-manifest.json"
```

`PUBLIC_STAGE` 与 `PRIVATE_AUDIT` 为人工设置的现有绝对目录。manifest 必须是新文件，且位于导出树与源工作树之外。工具不覆盖任何已有目录/文件。预检失败不产生导出物；若磁盘写入失败，可能残留不完整目录，必须隔离、人工检查后丢弃，不能发布。工作时应暂停其他写入者；扫描后的文件以内存中同一字节快照写出，不重新读取变化的内容，不复制 xattr、所有权、签名或可执行权限。

## 正向允许清单

唯一规则文件为 `tools/release/allowlist.json`，不是“复制整个仓库再删除少数文件”。新增公开范围必须先审核此清单，不能用临时参数跳过扫描。

- 精确顶层文件：`LICENSE.md`、`README.md`、`Gemfile`、`Gemfile.lock`。
- 精确 Xcode 文件：项目、共享 workspace、共享 scheme、SPM 锁文件；不包含个人 workspace 数据。
- 精确构建工具：`BuildTools/Package.swift`、`Package.resolved`、`Empty.swift`，现有 fastlane 文件；不包含任何 CI workflow。
- `BilibiliLive/` 的明确源码/资源后缀，以及必要依赖许可；现有 `Module/Personal/` 是公开功能模块，不是私人数据目录。
- `FamilyCore/` 的 Swift、C/头文件、modulemap 和必要文本资源；允许 CSQLite 桥接源文件，不允许 SQLite 数据库。
- `QuestionBank/`、`tools/questionbank/`、`tools/textbook-index/` 的明确代码/文本类型；原始教材 PDF、私人题目、学生记录不得混入。样例内容即使是 JSON 也必须由人审定可公开。
- `imgs/` 仅现有三个精确图片；公开 `docs/` 仅清单逐一列出的文档；`tools/release/` 仅本工具、测试和清单。不会泛化为整个 `docs/` 或 `tools/`。

`private`、`PrivateResources`、`internal`、AGENTS/其他代理指令、个人/隐藏配置、凭据、UDID、数据库、PDF、签名材料和构建/压缩产物被拒绝进入导出。未知路径默认排除，并在报告列出；无需遍历非允许子树，因此工具不是整个私人仓库的泄漏审计器。可见的符号链接（包括断链）直接阻断、不解引用；不会进入已整体排除的子树。硬链接、特殊文件、路径穿越、大小超限及嵌套 `.git` 阻断。源根 `.git` 只记录为排除，不读取其文件内容进入快照。

## 敏感扫描与误报

扫描候选公开字节，不仅看扩展名。包含常见 GitHub/AWS/Slack/API token、JWT、字面量密码/会话/API 密钥、URL 凭据、认证头、个人绝对路径、Team/配置描述文件设置、设备标识；签名材料路径直接禁止。PDF/SQLite/压缩文件魔数可发现改名文件。

已知私人原图 SHA256 为 `33c845f8464cba9ab14cc923046865de45ddbdc81a6e0f088aaa90bc6719fc94`；即使改名也阻断，不能例外。重编码、裁剪、截图和其他未知私人图片**无法用此 SHA256 自动识别**，必须人工逐张审阅。工具不自动模糊、替换或擦除敏感数据。

只有 `literal-credential` 检测可配置窄例外，每项必须指定精确路径、规则、整行（去首尾空白）SHA256 和理由。既有上游 `ApiRequest.swift` 的协议 appkey/appsec 与 `ssoCookie` 公开端点 URL 使用此机制，不改变协议；例外命中会以 `accepted-exception` 明示，过期例外产生警告。没有“测试目录全部忽略”或“看起来是测试 token 就放行”。测试夹具如发生误报，必须逐行审核后记录窄例外，否则保持阻断。Team、私人图哈希和其他扫描器不可豁免。

## 公共可构建静态前置检查

在**实际将导出的文件集合**上验证必需入口/Info.plist/故事板/资产目录、项目/workspace/scheme、SPM 与 BuildTools 锁文件、资产 `Contents.json` 的 filename 引用、配置文件/本地包路径、同步根、命名 app icon/accent 及部分字面量 Bundle 资源引用。资源在私有目录中存在但不导出，也视作缺失。

新增传统 PBXFileReference 暂保守阻断，需扩充解析器审核，不假装支持全部 Xcode 语法。动态路径、自定义脚本生成物、SPM 目标资源和网络依赖可用性无法完整静态推断。静态通过后仍必须在独立、仅含公开文件的环境执行真实构建和运行验证，不可用开发树私有文件补齐而宣称公共构建成功。

公共项目不允许固定个人 `DEVELOPMENT_TEAM` 或配置描述文件 ID。用户签名只能来自**未提交的本地配置/模板填写**或人工构建参数，不允许导出真实签名配置。工具不生成或收集证书、Apple ID、密钥和设备 UDID。

## Manifest、GPL 与人工批准

manifest 为**私有 provenance sidecar**：含版本、工具/政策版本及政策 SHA256、本地 Git HEAD 源 commit、工作树 dirty 状态、每文件 SHA256/字节数和安全报告。它不在公开树内，也不能作为公开 release 附件。commit 指向 HEAD 仅是来源线索；有未提交改动时实际源码以 manifest 的字节哈希为准。工具不验证完整历史真实性、来源权属或上游可达性；不能根据一条 commit 声称已审核完整历史。若当前内部源 commit 字符串出现在候选内容，export 额外阻断。其他历史 commit 映射仍需人工审阅。

`LICENSE.md` 以当前上游原文件 SHA256 固定，必须逐字节原样保留；修改/缺失会阻断，不替换、不删节 GPL。发布二进制时由维护者确认对应源码与 GPL 义务，并保留上游署名、依赖许可和必要说明。

每次对外发布必须由人签署私有证据记录，至少包括：

1. 候选版本、公开源码内容哈希和对应私有 manifest；每个排除、警告、例外已人工复核。
2. 独立公共快照的实际构建命令、Xcode/SDK/依赖版本、退出码、日志摘要与哈希。不得写“计划构建”当“通过”。
3. Apple TV 真机型号与 tvOS 版本（对外记录不含 UDID）、实际执行功能和结果；未执行明确记 `NOT RUN`。模拟器不等于真机。
4. 公开截图/图像、题库样例、隐私边界、签名材料及许可证人工检查结果。
5. 审核人、时间、实际证据引用/哈希、明确同意的操作范围：仅源码 PR，还是另经批准的 tag/release/附件上传。未签署则不得发布。

本工具任何字段都不构成人工签署。`device_verified`、`build_verified`、`publication_authorized` 始终为 false。维护者在人工批准后自行处理公共 PR；本工具不做 Git 同步或网络发布。
