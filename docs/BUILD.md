# 构建 ATV-Bilibili Family

> 0.1.1 为通用未签名自签包。同功能版本已有 Apple TV 4K 真机验证；不同证书重签后的安装、Keychain 行为和全部播放路线仍需接收方在自己的设备上核对。

## 环境

工程最低目标为 tvOS 16.0，使用 Xcode 的 tvOS SDK。本地开发验证环境为 Xcode 27.1 / Swift 6.4。工程使用文件系统同步组，请使用支持该格式的新版本 Xcode。

## 不签名模拟器构建

从源码根目录运行，DerivedData应指向项目外的独立目录：

```sh
xcodebuild -project BilibiliLive.xcodeproj -scheme BilibiliLive \
  -configuration Debug -sdk appletvsimulator \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath /tmp/ATVFamily-DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO SKIP_SWIFTFORMAT=YES build
```

`SKIP_SWIFTFORMAT`默认YES，构建不会自动格式化整个源树。仅在明确需要格式化时设置NO，并审查diff。不要把构建命令和上游fastlane产物清理/发布流程混用。

首次构建需要从GitHub下载锁定的SPM依赖。下载失败应保留错误记录并排查网络，不应静默更新依赖版本或将缓存下载成功当作构建成功。

## 未签名真机构建

从此公开源码根目录执行，使用新的工作目录；不会读取个人证书或启用私人资源：

```sh
RUN=$(mktemp -d "${TMPDIR:-/tmp}/ATVFamily-public-build.XXXXXX")
xcodebuild -project BilibiliLive.xcodeproj -scheme BilibiliLive \
  -configuration Release -sdk appletvos \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath "$RUN/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  FAMILY_APP_BUNDLE_IDENTIFIER=com.songdone.ATVBilibiliFamily \
  FAMILY_SUPPORT_ENABLED=NO SKIP_SWIFTFORMAT=YES build
```

产物位于 `$RUN/DerivedData/Build/Products/Release-appletvos/BilibiliLive.app`。打包 IPA 时在独立临时目录创建 `Payload` 并复制该 `.app`，再 ZIP 压缩 `Payload`。最终应确认包内所有 Mach-O 均无签名，且没有 `embedded.mobileprovision` 或 `_CodeSignature`；未签名产物必须由接收方重签才可装到 Apple TV。不同签名或工具链会使最终二进制/文件哈希不同，不承诺逐字节复现。

为了避免缓存越积越多，构建结束后只清理本次 `$RUN` 的中间文件、索引和依赖缓存；保留需要交付的产物与测试证据，不使用会删除源码根目录文件的清理命令。

## 核心自动化

```sh
swift test --package-path FamilyCore
```

核心测试在临时目录和内存安全存储上运行，不需要真实家庭信息、Apple ID或签名凭据。核心通过不能替代AVPlayer动态计时、tvOS Keychain/存储、遥控器、设备重启和真机微信扫码测试。

## 签名和真机

仓库不配置个人Development Team。用Xcode本地签名设置或不入库的配置提供自己的团队及Bundle ID。命令行自定义主应用标识使用 `FAMILY_APP_BUNDLE_IDENTIFIER=<自己的Bundle ID>`，**不要直接覆盖 `PRODUCT_BUNDLE_IDENTIFIER`**：后者会传播到SPM嵌入框架/资源包，造成重复标识，真机拒绝安装。测试账号密码、Token、P12、私钥、Provisioning Profile、设备UDID不得提交。

模拟器.app不是可安装到Apple TV的IPA。真机产物必须面向appletvos构建并使用合适的签名、Bundle ID及entitlements。Release 提供未签名 IPA；使用明确支持 tvOS 的重签工具和接收方自己的证书及描述文件安装。工具须签内嵌框架和主应用，并正确配置 Keychain 访问组。详见 Release 附件中的自签安装说明。

保持同一家庭安装的Bundle ID及签名身份，才能验证更新迁移保留。卸载或设备擦除不承诺自动恢复历史，不能先删App再以重新安装验证“升级无损”。

## 可选赞赏资源

公开构建默认不含个人微信赞赏码，`FAMILY_SUPPORT_ENABLED` 默认NO。

私人构建时使用独立DerivedData目录，并在上述构建命令追加：

```sh
FAMILY_SUPPORT_ENABLED=YES \
FAMILY_SUPPORT_RESOURCE_DIR=/absolute/path/to/local-support
```

该本地目录需包含 `SupportConfig.json`（`{"imageName":"wechat-6uos.jpg"}`）和原始 `wechat-6uos.jpg`。文件名是通用资源约定，图片内容由使用者自行配置。未开启此设置不要求任何私人文件，图片加载失败安全降级。复制不经过资产重编码，保留原始字节。

禁止在同一个DerivedData目录交替打私人和公共包；检测到残留图片时公共构建会直接失败，要求使用新的构建目录，不偷偷删除或误打包私人图片。公共导出树不得包含这些个人图片或启用后的本地配置。真实电视显示及微信扫码仍待验收。

## 发布

参见 `RELEASE.md`。手动构建验证工作流不发布IPA或创建Release，任何正式公开发布仍需隐私/许可审核与真实设备证据。

## 模拟器真实 Keychain / PIN 测试签名

`CODE_SIGNING_ALLOWED=NO` 适合编译检查，但不代表真实 Keychain 可用。本地 Xcode 27.1 / tvOS 26.5 模拟器验证中，此产物可以启动，却因缺少 `application-identifier` / `keychain-access-groups` 返回 Security `-34018`。PIN 页面按失败关闭处理，不能以此认定 PIN 业务有误，也不能换成内存存储掩盖问题。

不要对这个未签名构建产物直接执行 `codesign --sign - --entitlements Tests/FamilyTVUITests/Simulator.entitlements` 作为修复。在上述环境，安装虽成功，主机 AMFI 却拒绝启动：`AppleMobileFileIntegrityError -424: The file is adhoc signed but contains restricted entitlements`，外层表现为 `PBProcessManager ServiceUnavailable` / launchd spawn error 163。把 debug dylib、preview dylib 和 PocketSVG framework 全部重签后仍复现；`codesign --verify --deep` 通过也不代表可以启动。

应使用 **Xcode 标准模拟器 ad-hoc 构建链路**，让 Xcode 区分模拟器权限与宿主代码签名权限。先在本地创建 `Tests/FamilyTVUITests/Simulator.entitlements`（此本地签名配置不随公共源码导出）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>SIMULATOR.com.etan.tv.BilibiliLive</string>
<key>keychain-access-groups</key><array><string>SIMULATOR.com.etan.tv.BilibiliLive</string></array>
</dict></plist>
```

上述 `SIMULATOR.com.etan.tv.BilibiliLive` 是本地模拟器测试标识，不是真实团队 ID，不适用于真机或发布。无需 Apple 账号、证书或 provisioning profile；不要设置 `-allowProvisioningUpdates`，不要读取个人签名凭据或修改系统安全设置。

以下命令从源码根目录执行。`RUN` 必须是新的项目外 artifact 目录；`PACKAGES` 指向已有、与 `Package.resolved` 一致的依赖缓存，不更新依赖。不要复用公共导出或私人资源构建的 DerivedData，也不要手动重签原始产物。

```sh
PROJECT="$PWD"
ARTIFACTS="$(dirname "$PROJECT")/artifacts"
RUN="$ARTIFACTS/SimulatorKeychain-$(date +%Y%m%d-%H%M%S)"
PACKAGES="$ARTIFACTS/BaselineDerivedData/SourcePackages"
SIM="<从 xcrun simctl list devices available 选择本地 Apple TV 模拟器 ID>"
mkdir "$RUN"

xcodebuild -project "$PROJECT/BilibiliLive.xcodeproj" -scheme BilibiliLive \
  -configuration Debug -sdk appletvsimulator \
  -destination "platform=tvOS Simulator,id=$SIM" \
  -derivedDataPath "$RUN/AppDerivedData" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS="$PROJECT/Tests/FamilyTVUITests/Simulator.entitlements" \
  SKIP_SWIFTFORMAT=YES build > "$RUN/app-build.log" 2>&1

# 仅在构建成功后继续；安装更新此 app，不卸载 app 或擦除设备。
APP="$RUN/AppDerivedData/Build/Products/Debug-appletvsimulator/BilibiliLive.app"
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.etan.tv.BilibiliLive --family-preview

# 先阅读 Tests/FamilyTVUITests/FamilyTVUITests.swift。
# 独立 UI 测试工程只构建 runner，使用上一步已安装的 app。
xcodebuild -project "$PROJECT/Tests/FamilyTVUITests/FamilyTVUITests.xcodeproj" \
  -scheme FamilyTVUITests -destination "platform=tvOS Simulator,id=$SIM" \
  -derivedDataPath "$RUN/TestDerivedData" \
  -resultBundlePath "$RUN/pin-ui.xcresult" \
  -only-testing:FamilyTVUITests/FamilyTVUITests/testSetupPINAndVerifyAgainWithRemote \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test \
  > "$RUN/pin-ui-tests.log" 2>&1
```

这里测试 runner 的 `CODE_SIGNING_ALLOWED=NO` 不会改变已安装 app 的签名。测试使用 `--family-test-store <UUID>` 隔离测试数据命名空间，仍调用 `KeychainSecureStore` 的真实 `SecItem` API，并未替换成内存实现。

验证签名时应同时检查生成的 `BilibiliLive.app-Simulated.xcent` 和 `BilibiliLive.app.xcent`：本次前者包含两项权限，后者为空字典。Xcode linker 将模拟器权限嵌入主可执行文件的 `__TEXT,__entitlements` / `__TEXT,__ents_der`；只运行 `codesign -d --entitlements - "$APP"` 看到空字典是正常现象，不要再把两键手动签入宿主签名槽。Xcode 同时处理 nested framework 和 debug/preview dylib 的 ad-hoc 签名。

2026-11-05 本地验收：标准构建成功，`simctl launch` 成功返回 PID；指定 PIN 单测 **1 test / 0 failures**（18.918 秒），实际完成创建六位 PIN、二次确认、进入家庭管理、终止并重新启动 app、再次输入 PIN 解锁。证据保存在项目外 `artifacts/SimulatorSigningDiagnosis/` 的 `native-build.log`、`native-launch.log`、`native-signature.log`、`pin-native-tests.log` 和独立 `pin-native.xcresult`。这验证的是上述模拟器的真实 Keychain 路径，不替代实体 Apple TV、设备重启或真机分发签名验收。
