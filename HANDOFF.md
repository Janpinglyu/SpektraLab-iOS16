# 交接说明 — SpektraLab-iOS IPA 构建

> 给接手继续修的 agent。本文记录**当前精确状态**、**已踩过的坑**、**剩余问题**和**建议方案**。
> 最后更新：2026-11-06

## 一句话现状

> 2026-11-06 最新状态（v1.2.0，已发布）：
>
> - 开发目标仍是 iOS 27.0 / Xcode 27.2。
> - App 首页已重构为照片墙：多图导入、编辑返回后刷新缩略图，底部常驻
>   “胶片实验室”与拟物胶卷罐，可直接选胶片试色或进入完整编辑。
> - 已添加配方工作流：复制后来源照片降饱和锁定，全选和粘贴自动排除来源；
>   可多选其他照片，用真实引擎逐张粘贴胶片、相纸、片边、日期与调整参数。
> - 编辑器保留顶部实时片名、预览自适应、单指点按沉浸模式与单行片库；
>   长胶片名与长相纸名可显示两行。
> - 片边与日期后背已接入上游引擎的真实曝光模型：片基、齿孔、DX、片边字、格号、
>   日期和 120 拍摄数据都与画面一起显影，不是 SwiftUI 叠层。
> - 片边裁切已修正竖图方向：横图使用片幅长/短比，竖图使用其倒数；Core Image、
>   LibRaw 回退和全尺寸导出使用同一规则。
> - 片边方向可选手动“横向 / 竖向”：会按目标方向重新中心裁切，画面保持正向，
>   齿孔、片基、片边字、格号和日期随真实片条方向生成。自动片幅已修正竖图被误判
>   为 1:1（进而落到 6×6）的问题；普通 3:2 / 4:3 自动使用 135，不再误落到
>   6×9 或半格。
> - RAW 类型提示已修正：iOS 把 ARW/NEF 报成 `public.tiff`，现在会保留扩展名或
>   PhotosPicker 的 RAW UTI，并从 TIFF/ARW 容器签名补齐类型；相册导入 Sony ARW
>   不再被误当成普通 TIFF。Core Image 拒绝时会继续尝试 LibRaw。
> - Core Image 返回空图或内嵌缩略图（Nikon NEF 在 iOS 27 会返回 120×160）时，
>   自动回退到内置 LibRaw 0.22.2，色彩策略与桌面 1.3.5 一致。
> - 输出回到 macOS preview host 的 sRGB 约定；色彩空间转换全部交给 Core Image，
>   App 不自建转换矩阵。画布用同一 sRGB 标记，不做二次转换。
> - 导出改为直接编码 `spk_result.rgba16`，去掉 RGBA8 全图副本和纹理分块读回。
> - iOS 27.2 模拟器已验证：ARW / CR3 / NEF / JPEG 解码；NEF 竖图方向；2× 缩放；
>   曝光补偿 `+1.50` 可正常渲染且无报错；竖版 135 片边保持竖向。
> - 曝光补偿已接到产品默认值：iOS 在 `spk_open` 时传 `product_defaults: true`，
>   关闭印相机的中间调自动补偿，所以滑块会真实改变成片亮度（±3 EV 实测从
>   接近黑场到明显过曝），而不是只移动负片在特性曲线上的位置。
> - 全尺寸片边导出已验证：135 + 日期为 `6446×5946`，120/645 + 日期为 `5658×4188`。
>   输出 JPEG 中齿孔、片边字、格号、日期与拍摄数据均完整。
> - 仍未在目标真机上复测相册写入、长时间内存和胶片切换。
> - 真机无签名包由 CI 按 `repack-ipa.py` 生成，版本为 `1.2.0 (6)`，已发布到
>   [`latest` Release](https://github.com/Minerchu/SpektraLab-iOS/releases/tag/latest)；
>   对应提交 `e5cc4e7`、CI run `42062994969`。
>
> Xcode 27 的 simulator Metal 编译必须显式传
> `--target=air64-apple-ios27.0-simulator`，否则即使使用 `iphonesimulator` SDK
> 也会生成 device metallib。

### 本地复测 RAW / 导出

DEBUG 构建带一个启动探针。把样片放进模拟器沙盒后：

```bash
C=$(xcrun simctl get_app_container booted com.hanze.spektralab data)
mkdir -p "$C/Documents/rawtest"
cp /path/to/*.ARW "$C/Documents/rawtest/"

SIMCTL_CHILD_SPEKTRAFILM_DECODER_TEST_DIR="$C/Documents/rawtest"   xcrun simctl launch --terminate-running-process --console-pty   booted com.hanze.spektralab
```

结果写到 `$C/Documents/decoder-probe.txt`。要跑完整
`decode → engine → sRGB JPEG`：

```bash
SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_PATH="$C/Documents/rawtest/photo.ARW" SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_FULL=1   xcrun simctl launch --terminate-running-process --console-pty   booted com.hanze.spektralab
```

`SPEKTRAFILM_RENDER_TEST_SAVE=1` 会再写一次相册。
`SPEKTRAFILM_FORCE_LIBRAW=1` 可强制走 LibRaw，用来和 Core Image 对色。
这两个开关只在 DEBUG 构建生效。

片边与日期的全尺寸探针可再加：

```bash
SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_BORDER=1 \
SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_GATE=135 \
SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_ORIENTATION=vertical \
SIMCTL_CHILD_SPEKTRAFILM_RENDER_TEST_DATE=1
```

`SPEKTRAFILM_RENDER_TEST_ORIENTATION` 可选 `automatic`、`horizontal`、`vertical`。
UI 复测同名变量为 `SPEKTRAFILM_UI_TEST_ORIENTATION`。

输出写到 `$C/Documents/render-test.jpg`；失败时写 `render-probe-error.txt`。

打真机 IPA 之前必须先执行 `ios/Tools/build-engine.sh bundle device`，
否则会把模拟器 metallib 打进包；打包用
`python3 ios/Tools/repack-ipa.py <dir-with-Payload> <out.ipa>`，
不要用 `zip` 或 `ditto -c -k`。

**CI 已全绿：`Build` → `Package the IPA` → `Publish the IPA` 全部通过，
每轮 main 上的成功构建会把 IPA 发到一个滚动的 `latest` release，README 顶部有直链。**

已验证的产物（run `41619153990`，commit `1e48960873`）：

| 项 | 值 |
|---|---|
| release | <https://github.com/Minerchu/SpektraLab-iOS/releases/tag/latest> |
| 资产 | `SpektraLab-<提交号>.ipa`（**文件名带提交号，见下方「已解决」一节**） |
| 直链 | 打开 <https://github.com/Minerchu/SpektraLab-iOS/releases/tag/latest> 下载 |
| 匿名可下载 | 是（仓库 public，链接 302 到资产，zip 以 `Payload/` 开头） |

滚动替换在 run `41620080899`（commit `d4389cf94a`）上验证过：`latest` tag 跟着
移动、release 仍然只有一个、资产没有重复堆积。

**这个 IPA 仍然装不上真机**：没有证书与描述文件，bundle 里没有效签名
（`codesign` 的 ad-hoc 封装被 `Assets.car` / `default.metallib` 拒绝，见下面最后一个坑）。
用户侧要么用 AltStore / Sideloadly / Xcode 以自己的 Apple ID 重签，
要么配齐下面那 7 个 secret 走正规签名路径。

### archive 为什么不能用（已绕开，勿再排查）

根因（已确认并绕开）：archive 在写 `.xcarchive/Info.plist` 时是**从代码签名里**读取
bundle id / Team 的。CI runner 上没有证书与描述文件，归档出来的 .app
`code object is not signed at all`，这个读取为空，xcodebuild 就报出误导性的
`Archive Missing Bundle Identifier`。这解释了为什么改 Info.plist（值本来就对）、
改 `CODE_SIGN_STYLE`、去 `VALIDATE_PRODUCT`、加 `CODE_SIGNING_ALLOWED=NO` **全都无效**
—— 病根从来不在这些地方。

**现在的 CI 结构**（`.github/workflows/build-ios.yml`，共 16 步）：

- `Build`：签名 secret 齐全 → 走 `archive`；否则 → 直接
  `xcodebuild ... build CODE_SIGNING_ALLOWED=NO`，产出
  `Release-iphoneos/SpektraLab.app`，并把 `BUILD_MODE=archive|package` 写进
  `$GITHUB_ENV`。
- `Package the IPA`：archive 模式用 `plistlib` 生成 `ExportOptions.plist`
  后走 `-exportArchive`；package 模式把 .app 拷进 `Payload/`，先 ad-hoc 签名
  嵌套的 `*.metallib` 再签 bundle，最后用 `ditto -c -k --keepParent` 打包
  （用 `ditto` 不用 `zip`：iOS 需要它保留的 bundle 元数据与符号链接）。
  **两条路径都归一成 `build/ipa/SpektraLab.ipa`**，这样 release 资产名和
  README 直链不会随签名路径变化。
- `Publish the IPA`：`gh release` 维护一个打 `latest` tag 的滚动 release。
  先 `delete --cleanup-tag` 再 `create --target $GITHUB_SHA`，因为
  `gh release create` 搬不动已存在的 tag。只在 `main` 且全绿时执行。

### 最后一个坑（run `41614070312`，已修）

`Package the IPA` 第一次跑的时候死在 ad-hoc 签名：

```
build/Payload/SpektraLab.app: code object is not signed at all
In subcomponent: .../Payload/SpektraLab.app/default.metallib
```

`codesign` 在封装 bundle 前会先走一遍嵌套代码，而 `Canvas.metal` 编出来的
`default.metallib` 被它当成一个「未签名的代码对象」，于是整个 bundle 拒绝签名。
修法：**先给 bundle 里每个 `*.metallib` 单独 ad-hoc 签名，再签 bundle**；
并且这一次签名失败只 `::warning::` 不中断，因为无证书的 IPA 本来也装不上真机，
不该为了一个装饰性签名扔掉四十分钟的构建产物。


## 以下保留原始踩坑记录（仍是有效背景，勿重复尝试）


**编译已经 100% 通过**（Swift + 引擎 C++ + metallib 内核 + 资源烘焙 + App icon + 工程生成），
CI 目前卡在 `Build` 步骤的 **archive 收尾阶段**：

```
xcodebuild: error: Archive Missing Bundle Identifier
```

不是代码编译错误，是 **CI 无签名证书 + Xcode 16 archive 元数据组装** 的问题。

## 仓库与 CI

| 项 | 值 |
|---|---|
| 仓库 | `Minerchu/SpektraLab-iOS`，分支 `main` |
| Workflow | `.github/workflows/build-ios.yml` |
| 引擎来源 | 上游 `JamesQiu2005/SpektraLab`，固定 commit `02d82b56cf65f0f8e802a708612edc4e9a4790af` |
| 引擎拉取 | `tools/fetch-engine.py`（**必须用 `${{ github.token }}`**，匿名 API 只有 60 次/小时会 403） |
| 引擎 iOS 补丁 | `tools/apply-ios-patch.py`（拉取后由 CI 应用） |
| 工程生成 | `ios/Tools/gen-project.py`（CI 每次构建重新生成 pbxproj 与 xcscheme） |
| 最低系统 | `IOS_MIN = "27.0"`，界面使用系统原生 Liquid Glass |
| Swift | 6.0 + `SWIFT_STRICT_CONCURRENCY = complete` |

CI 步骤顺序：checkout → fetch engine → check profiles → patch engine → Metal toolchain
→ kernels & resources → App icon → generate project → install cert(跳过) → install
profile(跳过) → say what is missing → Build(通过) → Package the IPA → upload。

签名相关 secret 全部未配置，所以 `Install the signing certificate` / `Install the
provisioning profile` 两步被跳过，`ExportOptions.plist` 走 ad-hoc 分支。

## 已解决：SideStore 装不上，报 `Failed to get bundle ID`

**症状**：`IXErrorDomain Code=13 "Failed to get bundle ID from
.../Extracted/Payload/App.app"`。

**根因（两条叠加）**：

1. **release 资产的 CDN 缓存**。`releases/download/latest/<固定名>` 这个 URL 在资产
   **同名替换**之后，仍会继续返回旧文件一段时间。旧包的 `Payload/` 下是 `App.app`、
   Info.plist 也不对 → 安装器读不到 bundle id。用 API 取的却是新包，所以「CI 明明
   修好了、装上去还是旧包」。
2. **当时打包链路本身也是断的**：`fetch-engine.py` 在 141/239 个文件处 `HTTP 404`
   （raw.githubusercontent.com 限流时会伪装成 404），最新代码从来没跑到打包步骤。

**已修**：

- 资产名带提交号 `SpektraLab-<sha>.ipa`，URL 唯一，撞不上缓存；README 改指 release 页面。
- `fetch-engine.py`：改走 tree + **blob API**（`/git/blobs/{sha}`），不再用
  `download_url`；重试列表补上 **500**。本地实测 239/239 文件、17.2MB。
- 打包：`plutil -convert xml1`（Info.plist 用 XML，有些工具只认文本）；
  `ditto --norsrc --noextattr`（codesign 写的扩展属性会被 `ditto -c -k` 变成
  AppleDouble `._*`，在设备上和原文件并排存在，安装器会算进 bundle）；
  `codesign --force --deep --sign - --identifier <bundleid>`（metallib / `Assets.car`
  都被 codesign 当成 code，必须 `--deep` 一次封完；不给 `--identifier` 它会自己编一个
  `SpektraLab-<uuid>`，和 CFBundleIdentifier 不一致）；`codesign --verify` 失败不再致命。

**验收（`SpektraLab-b4081e6.ipa`，9.67MB）**：`Payload/SpektraLab.app`、Info.plist 为
XML、`CFBundleIdentifier=com.hanze.spektralab`、arm64、`MinimumOSVersion=16.0`、
`_CodeSignature/CodeResources` 存在、**零 AppleDouble**。

**IPA 装不上时的检查顺序**：

1. `unzip -l` 看 `Payload/` 下的 `.app` 目录名；
2. `.app/Info.plist` 是 XML 还是 binary、有没有 `CFBundleIdentifier`；
3. 有没有 `._*`；
4. 有没有 `_CodeSignature`；
5. 下载名是固定的 → 先怀疑 CDN 缓存。

## 当前卡点的精确诊断

最后一次 CI（run `41595779767`，commit `a62a30eeb2`）Build 步骤失败，日志尾部：

```
xcodebuild: error: Archive Missing Bundle Identifier
=== diagnostic: CFBundleIdentifier in the built app ===
build/SpektraLab.xcarchive/Products/Applications/SpektraLab.app/Info.plist
com.hanze.spektralab            <-- .app 里是对的
=== source Info.plist ===
com.hanze.spektralab            <-- 源码 plist 也是对的
=== .xcarchive/Info.plist ===
FileNotFoundError: .../build/SpektraLab.xcarchive/Info.plist   <-- 没生成
=== codesign state of the archived app ===
code object is not signed at all  <-- app 完全没签名
```

关键点：

- `.app/Info.plist` 的 `CFBundleIdentifier` **确实存在且正确**，所以**不要再往 plist 里找问题**。
- `Info.plist` 里的值已由 `gen-project.py` 写成字面量 `com.hanze.spektralab`
  （`write_infoplist_bundle_id()`），不再依赖 `$(PRODUCT_BUNDLE_IDENTIFIER)` 变量展开。
- `PRODUCT_BUNDLE_IDENTIFIER = com.hanze.spektralab` 在 build settings 里也已解析出来。
- 日志里**没有 CodeSign 步骤**，`.xcarchive/Info.plist` 没生成 —— Xcode 16 在组装
  archive 元数据时读不到「已签名产品」的 bundle id，于是报这个误导性错误。
- 最近一轮我在 archive 命令上加了 `CODE_SIGNING_ALLOWED=NO`，它让 app 变成
  「code object is not signed at all」，**很可能正是它导致/加剧了这个问题**，
  接手时优先考虑撤掉或改成 ad-hoc 签名。

## 已经修完的问题（按修复顺序，勿重复踩坑）

1. **引擎拉取**：匿名 GitHub API 限流 403 → 改用 `tools/fetch-engine.py` + `${{ github.token }}`
   （认证 5000 次/小时），用 Contents API 批量取文件而非 git clone。上游仓库无 Git LFS。
2. **App icon 步骤 PEP 668**（Homebrew Python 拒绝 pip install）→ 改用 venv。
3. **`-archivePath` / `-derivedDataPath` 必须配 `-scheme`** → 在 `gen-project.py` 里生成
   shared scheme（写入 `xcshareddata/xcschemes/SpektraLab.xcscheme`）。
4. **`HEADER_SEARCH_PATHS` 层级算错**：`$(SRCROOT)` 是 `ios/`，引擎在仓库根，
   所以是 `$(SRCROOT)/../engine/...`（一级），不是 `../../`（两级）。
5. **9 个 Swift 编译错误**，全部修完：
   - `makeDefaultLibrary(bundle: .main)` 返回值处理
   - `Stock.Type` → `Stock.FilmType`（`Type` 与 Swift 元类型冲突）
   - `ViewModel.State` → `AppState`（与 SwiftUI 的 `State` 冲突，曾导致 `.failed`
     被解析成手势 phase 的诡异报错）
   - `buffer.contents()!` 强解包 → 安全解包
   - `Transferable` 的 `DataRepresentation(importedAs:)` 标签
   - `MTLTexture` 不是 `Hashable`、没有 `hashValue` → 改用 `renderIdentity`（引擎 progressID）
   - `previous == .failed` → `if case .failed = previous`（带关联值的 case 不能用 `==`）
   - `Task` 初始化器歧义 → 统一写 `Task<Void, Never>(priority:)` / `Task<Void, Never>`
   - `toolbar(content:)` 歧义 → 整个移除 `.toolbar`，改成 body 里普通 `HStack` 顶栏
     （`ContentView.swift` 的 `topBar`）；`StockPicker` 里那个单个 `ToolbarItem` 的
     `.toolbar` 不冲突，保留。
6. **根因级大坑：`.onChange(of:initial:_:)` 是 iOS 17 API，而 target 是 16.0**。
   之前一连串「Task 歧义 / toolbar 歧义」全是它引发的连锁误报。最终解法：
   **完全不用 onChange**，把导入触发放进 `PhotosPicker` 的自定义
   `Binding<PhotosPickerItem?>` setter 里；两处 Task 都加 `@MainActor in`
   （ViewModel 是 `@MainActor`，Task 闭包是 `@Sendable`，Swift 6 严格并发要求）。
7. **ViewModel init**：`let renderer` 无默认值 + init 里有早退 → `return without
   initializing all stored properties`。改成 `private(set) var renderer: CanvasRenderer? = nil`。
8. **引擎补丁两处 C++ 错误**（`tools/apply-ios-patch.py`）：
   - `fire_test_pressure_if_asked()` 定义被 `#if TARGET_OS_OSX` 包了，但上游有 **2 处
     调用**（第 234、258 行）没包 → 给定义补 `#else` 空实现，调用点不用动。
   - `MTL::TextureUsageCopySource` **在 metal-cpp 里根本不存在**（blit 复制不需要
     usage 声明）→ 直接删掉那条 change，保持上游 `setUsage(MTL::TextureUsageShaderRead)`。
9. **签名风格判断写反**：`CODE_SIGN_STYLE` 改成始终 `Manual`
   （无证书时 `CODE_SIGN_IDENTITY = "-"` 即 ad-hoc；Automatic 需要 Team 和 Apple 账号，
   在无凭据 CI 上必失败）。
10. **`VALIDATE_PRODUCT = YES`** 从 Release 配置移除（它会触发
    `builtin-validationUtility` 校验无签名 app）。
11. **`codesign` 拒绝封装含未签名 `default.metallib` 的 bundle**（见上文
    「最后一个坑」）：先签每个 `*.metallib` 再签 bundle，且签名失败只告警。
12. **`ExportOptions.plist` 不要用 heredoc 写**：YAML 块标量的缩进会被带进文件，
    `<?xml` 前面多了空格就不是合法的 XML 声明了，`xcodebuild` 会拒收。
    改用 `plistlib.dump()` 生成（workflow 的 archive 分支已改）。

## 给接手 agent 的建议（按优先级）

### 方案 A（推荐，最省事）：绕过 archive，直接从 build 产物打 IPA

编译已经全过了，没必要跟 Xcode 的 archive 签名逻辑纠缠。把 Build 步骤的
`archive` 换成普通 `build`，然后从 `DerivedData` 里把 `.app` 打包：

```bash
xcodebuild -project ios/SpektraLab.xcodeproj \
  -scheme SpektraLab -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee build/xcodebuild.log

APP=$(find build/DerivedData/Build/Products -maxdepth 2 -type d -name 'SpektraLab.app' | head -1)
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry SpektraLab.ipa Payload)
```

这样 **无需任何签名证书**就能产出可下载的 IPA（未签名，装不了真机，但足以验证
整条编译链路并交付产物）。相应地，`Export the IPA` 步骤需要改成：若
`build/ipa/*.ipa` 已存在就跳过 `-exportArchive`。

### 方案 B：让 archive 成功

- 撤掉 `CODE_SIGNING_ALLOWED=NO`，改用显式 ad-hoc 签名：
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual`
- 或在 archive 前用 `codesign -s -` 给产物做 ad-hoc 签名。
- 若仍报 `Archive Missing Bundle Identifier`，可考虑 `-skipUnavailableDevices`、
  检查 scheme 的 `ArchiveAction`、或干脆保留方案 A 的兜底。

### 方案 C：配齐 7 个 secret，走正规签名

`tools/set-github-secrets.py` 可从本地文件一次性写入。所需 secret：

```
IOS_CERTIFICATE_P12            # 证书 p12 的 base64
IOS_CERTIFICATE_PASSWORD
IOS_CERTIFICATE_IDENTITY       # e.g. "Apple Development: NAME (TEAMID)"
IOS_PROVISIONING_PROFILE       # 描述文件 base64
IOS_PROVISIONING_PROFILE_NAME
IOS_TEAM_ID
IOS_BUNDLE_ID
```

有证书后 `Export the IPA` 会走 development 分支，产出可装真机的 IPA。

### 强烈建议：保留兜底

无论选 A/B/C，让 Build 步骤在 archive 失败时**自动回退到方案 A 直接打 IPA**，
这样 CI 永远有产物可下载，不会出现「编译全过但 artifact 为空」。

## 本地环境与工具（重要）

- 工作副本：`C:\Users\sodaer\WorkBuddy\2026-11-03-10-51-37\work\SpektraLab-iOS\`
- 本机是 Windows，**没有 Xcode**，只能在 GitHub Actions 的 macOS runner 上编译。
- 本机 PortableGit 缺 `git-remote-https`，`git clone/push` 走 HTTPS 会失败；
  用 GitHub **Contents API / Git Data API** 推送：
  - 全量单 commit：`tools/push-to-github.py`（脚本内 `files()` 决定推哪些文件，
    排除 `engine/`、`build/`、`.git/` 等）
  - 单文件快速推：`work/push_files.py <repo> <path...>`（从 `GITHUB_TOKEN` 读 token）
  - 带重试全量推：`work/push_retry.py`
- CI 结果监控：`work/watch_ci.py <run_id>`（等待完成并抽取编译错误）。
  ⚠️ 该脚本里**硬编码了 GitHub token**，**绝对不要提交进仓库**；如需复用请先改成读环境变量。
- `tools/push-to-github.py` 与 `tools/fetch-engine.py` 从环境变量读 token，是干净的。

## 验证当前 CI 状态的办法

```
GET /repos/Minerchu/SpektraLab-iOS/actions/runs?per_page=3
GET /repos/Minerchu/SpektraLab-iOS/actions/runs/{id}/jobs
GET /repos/Minerchu/SpektraLab-iOS/actions/runs/{id}/logs   # zip，解压看 ipa/NN_步骤名.txt
GET /repos/Minerchu/SpektraLab-iOS/releases/latest          # 发布后的资产与直链
```

`work/fetch_logs.py <run_id> [步骤名]` 已经把上面这套包好了：一次抓整个 logs.zip
并缓存成 `log<run_id>.zip`，然后按步骤名打印尾部日志（顺手剥掉每行的时间戳前缀）。
日志会在一段时间后被清理，失败后要尽快取。

取 artifact 或 release 的 zip 时有个坑：`archive_download_url` 会 302 到
`*.blob.core.windows.net`，如果继续带着 `Authorization: token ghp_...` 去跟这个
重定向，Azure 会以「Server failed to authenticate the request」回 403。要么禁掉
自动重定向、拿 `Location` 后裸取，要么直接走 release 的公开直链（仓库 public）。
本机代理还会掐大文件（约 500 KB 一次 `SSL record layer failure`），所以下载要带
`Range` 续传重试 —— `work/` 里的取法就是这样跑通的。

`Build` 步骤的失败诊断输出已写进 workflow，会打印 `.app` 与源码 plist 的
`CFBundleIdentifier`、`.xcarchive/Info.plist`、`codesign -dv` 结果、
以及解析出的 `PRODUCT_BUNDLE_IDENTIFIER`，排查时直接看日志尾部即可。
