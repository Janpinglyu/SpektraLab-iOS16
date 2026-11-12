# iOS 移植的技术决策

这个文件记的是**为什么**,而不是**是什么**。代码里有是什么。

## 为什么走 Metal 而不是 Vulkan

安卓版走 Vulkan,是因为 Android 没有 Metal。iOS 原生就是 Metal,所以这一版直接复用上游
`engine/src/gpu/metal_gpu.cpp`。

这不是"抄近路",是"抄到了更近的路":

1. **可移植性**:`metal_gpu.cpp` 是纯 C++ + metal-cpp,没有任何 AppKit / UIKit / Cocoa 依赖。
   全引擎(不含 vendored 的 metal-cpp)搜不到 `NSImage`/`NSColor`/`NSView` 之类的引用。
2. **着色器合规**:引擎加载的是**预编译的 `.metallib`**(`device->newLibrary(path)`),
   不是运行时 `newLibraryWithSource`。后者在 iOS 上不允许(App Store 审核问题)。
3. **少一层转换**:Vulkan 在 iOS 上要靠 MoltenVK 转译,多一层损耗和一层不确定性。
4. **白捡一个能力**:`contrast_mask` 在 Vulkan 后端未移植,安卓版只能在
   `capabilities.backend.unsupported_features` 里显式拒绝。Metal 后端是完整的。

## 引擎的输入契约

**引擎期望调用方交给他线性 ProPhoto RGB 的浮点像素。**

这不是猜的,是读出来的:

- `engine/src/core/params.hpp:409` — `input_color_space = "ProPhoto RGB"`(默认)
- `engine/src/core/params.hpp:410` — `input_cctf_decoding = false`(默认)
- `engine/src/pipeline/pipeline.cpp:587` — `node_decode_input` 在
  `input_cctf_decoding == false` 时直接 `out = in`,**引擎不替调用方解码**
- `engine/src/pipeline/pipeline.cpp:576` — `node_input_cast` 只丢 alpha 通道,
  **不做任何色彩空间转换**

所以 iOS 端不能把 ImageIO 的 8-bit sRGB 结果直接交给引擎。普通 JPEG 由
`CIContext` 直接 render 到线性 ProPhoto；相机 RAW 由 Core Image 或 LibRaw 直接
产出线性 ProPhoto，不再经过 8-bit sRGB 中间层。

## 传递函数:ProPhoto 的不是 sRGB 的

这是最容易错、而且错得很安静的地方。

`engine/src/pipeline/pipeline.cpp:41` 的 `cctf_mode_for`:

```cpp
if (cs == "sRGB" || cs == "Display P3") return 0;
if (cs == "ProPhoto RGB") return 1;
```

`engine/src/shaders/nodes.metal:242` 的 `cctf_decode_mode`:

```
mode 0 (sRGB):     (0.040449936 >= v) ? v/12.92 : pow((v+0.055)/1.055, 2.4)
mode 1 (ProPhoto): (v < 16/512)      ? v/16    : pow(v, 1.8)
```

**ProPhoto 是 gamma 1.8 + 16 倍线性脚,不是 sRGB 的 gamma 2.4 + 12.92 斜率。**

后果:

- **输入端**:解码结果已经是线性 ProPhoto,所以 `input_cctf_decoding = false`,引擎不再解码。
- **输出端**:当前 iOS 配置与 macOS preview host 一致:
  `output_color_space = "sRGB"`、`output_cctf_encoding = true`。画布把
  `CAMetalLayer` 标记为 sRGB,不再做 shader 里的传递函数转换。
- **转换由谁做**:输入和输出的色彩空间转换都交给 Core Image
  (`CIContext` / `CIRAWFilter` / `CGColorSpace`)。App 不自建颜色矩阵,
  也不在 Swift 或 Metal 里手写 gamma 变换。

用错的后果分两种:

- 用 sRGB 曲线解 ProPhoto:画面**看起来差不多**,但中调偏移、阴影发灰。安静的错误。
- 少了解码这一步(直接当线性用):双重编码,画面**压到近乎全黑**。响亮的错误。

画布 shader(`ios/SpektraLab/Canvas/Canvas.metal`)只负责 aspect-fit、缩放和拖动。
色彩空间由 `CAMetalLayer.colorspace = sRGB` 标记;如果输出色域改了,这里和
`ParamDefaults` 必须一起改。

## 引擎的输出契约

- 纹理的格式是 `RGBA16Unorm`(`metal_gpu.cpp:680`)。
- `spk_result.row_stride_px` 的单位是**像素**,不是字节,而且每像素是 **4 个 uint16**(RGBA)。
  安卓版在这里翻过车:消费端写成 `rgba16 + y * stride` 会让每行只前进 1/4 行,导出成片横向错乱。
  正确写法是 `rgba16 + y * stride * 4`。
- iOS 导出不再从纹理 blit。`spk_result.rgba16` 已经是一块连续行,应用用
  `CGDataProvider` 把它直接交给 Core Graphics/ImageIO;provider 的释放回调调用
  `spk_result_free`,所有权只有一份。
- 引擎原本创建的纹理只有 `MTLTextureUsageShaderRead`,**没有 `CopySource`**。
  iOS 补丁仍会补上 `CopySource`,以保留从纹理读回的能力;当前导出路径不再依赖它。

## 界面与片边的边界

界面层只选择胶片、相纸和物理片幅，不绘制假的胶片边框。片基、齿孔、DX 码、
片边字、格号、日期和 120 拍摄数据都通过引擎的 `overscan_*` 与
`date_imprint_*` 参数参与显影，因此会继承颗粒、光晕和相纸响应。

片边开启后，引擎要求输入画面的宽高比与所选片幅相符。App 在解码阶段居中裁切。
“片边方向”为自动时保留照片自身方向：横图使用片幅的“长边 / 短边”，竖图使用
它的倒数；手动选横向或竖向时，改用精确的目标宽高比裁切，照片本身不旋转，但构图
会变成对应方向的片条。Core Image、LibRaw 回退、预览和全尺寸导出共用同一目标
比例，避免各部分产生不同构图。`ImageDecoder.centerCrop` 的长短边接口保留原图
方向兼容，新增的 `targetAspect` 接口用于明确覆盖横竖方向。

自动片幅不按“比例最近”硬匹配：3:2 和 4:3 同时也是 120 6×9、半格和 645 的比例，
单凭宽高比无法判断真实片基。自动模式因此对普通横竖照片使用 135，1:1 使用 6×6，
只有接近 XPan、6×12、6×17 的全景比例才自动切换；其余 120 片幅由用户明确选择。

## 为什么自己写 Xcode 工程

上游的 macOS 工程是 `Tools/gen-project.py` 生成的 pbxproj,不是 Xcode 手写后提交的。
这个仓库沿用同一套做法(`ios/Tools/gen-project.py`),理由一样:

- 工程文件从磁盘状态派生,**加一个源文件不可能被忘记**
- 它是一个可以 review 的 diff,而不是 Xcode 恰好写出来的东西
- 对象 id 由**相对路径**的 sha1 派生,所以两个 checkout 一致,worktree 重新生成不冲突
- **可以在没有 Mac 的机器上改工程**——这正是本项目需要的

`gen-project.py` 也因此是 CI 的一步:CI 重新生成工程,构建的是磁盘上的东西,不是提交上来的。

## 为什么引擎是源码而不是静态库

引擎的 C++ 直接进 app target 的 Compile Sources,和 macOS 版一样。
一个单独的静态库 target 在这里唯一多出来的东西,是**第二处 include 路径会漂移的地方**。

排除掉的三个目录和三个文件,原因各不相同:

| 排除 | 原因 |
|---|---|
| `src/io/` 中除 `raw_decoder.cpp` / `raw_headroom.cpp` 外的文件 | Windows 主机的原生 TIFF I/O 与辅助代码。iOS 只编译 RAW 兼容策略所需的两个文件 |
| `src/desktop/` | 桌面控制器 |
| `src/gpu/vulkan_gpu.cpp` | Vulkan 后端。iOS 是 Metal |
| `src/pipeline/windows_unported.cpp` | Windows 专用的桩 |
| `src/pipeline/imprint_raster.cpp` | 非 Apple 的印字光栅器。Apple 路径在 `overscan.cpp` 里用 CoreText |

## 引擎补丁的三处改动

`tools/apply-ios-patch.py`。每一处都先断言命中次数,全部命中才写盘,并且检查
`#if`/`#endif` 是否平衡——一个悄悄没打上的补丁会在很远的地方以"引擎 bug"的样子炸掉。

1. **内存压力监控**:`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 在 iOS SDK 里不存在。
   不改就是编译不过。共用同一个队列的 idle timer 是普通 timer,在 iOS 上照常工作,所以
   只有 pressure 那一半是条件编译的,队列本身保持无条件。
2. **结果纹理的 `CopySource`**:见上面"引擎的输出契约"。
3. **`GPUFamilyMac2`**:iOS 没有这个 family。`supportsFamily(Mac2)` 在 iOS 上返回 false,
   所以不改也不会错,只是问了个平台上不存在的问题。

## 打包的三个容易忘的点

1. **safe-math 不是可选的**。引擎在启动时探测 metallib,发现 fast-math 漂移就拒绝运行
   (RFC-014 §5.1 trap 1,`exp` 和 fma 收缩带来 1.1e-5 的偏差)。所以引擎的 kernel 由
   `ios/Tools/build-engine.sh` 用 `xcrun -sdk iphoneos metal` **单独编译**,带
   `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise`,不走 Xcode。
   Xcode 的 `MTL_FAST_MATH = YES` 只影响 app 自己的 canvas shader。

2. **`.metallib` 要编给 iOS,不是 macOS**。`xcrun -sdk iphoneos metal` 用的是 iOS SDK
   和 iOS GPU family 的能力集;用 macOS 的编出来虽然能加载,但缺了 iOS 编译器会丢掉的东西。

3. **资源是相对路径解析的**。引擎把 `resources_dir` 拼到每个资源上
   (`profiles/<stock>.json`、`spektrafilm_constants.bin`、`io/sRGB.icc`),所以
   `resources_dir` 必须是**包含**这些文件的目录,而不是文件本身。iOS 端是
   `Bundle.main.resourceURL/engine`。

## 已经验证的导出路径

`spk_result.rgba16` 是紧密排列的 16-bit RGBA 行,`row_stride_px` 以像素为单位,
每像素 8 字节。iOS 27.2 模拟器上用 6240×4168 的 Sony ARW 完成全尺寸
`decode → open → solve → full render → sRGB JPEG` 验证,未再出现导出时的
内存峰值或横向错行。

## RAW 解码的两种路径

1. **Core Image**:优先使用文件扩展名、PhotosPicker 类型或容器签名对应的 RAW UTI。
   iOS 27 会把 ARW/NEF 的 `CGImageSourceGetType` 报成 `public.tiff`;把该值当成
   RAW 提示会丢厂商配置。应用会先用 `CIRAWFilter.nativeSize` 和输出 extent 校验,拒绝内嵌缩略图
   (Nikon NEF 在 iOS 27 上会返回 120×160)。
2. **LibRaw 0.22.2**:Core Image 返回空图、缩略图、低分辨率结果，或拒绝 TIFF
   容器的 RAW 时启用。
   与桌面兼容策略相同:相机白平衡、AHD、无自动提亮、线性 ProPhoto。
   `ios/Tools/gen-project.py` 在生成工程前会检查 LibRaw 源码,避免链接期才失败。

已在 iOS 27.2 模拟器验证全尺寸 135 与 120/645 片边导出，输出分别为 `6446×5946`
和 `5658×4188`，JPEG 中片边、日期和拍摄数据完整。目标真机仍需复测相册写入、
长时间内存峰值和不同 RAW 型号；若真机出现斜条纹，再检查 `row_stride_px` 的行距约定。
