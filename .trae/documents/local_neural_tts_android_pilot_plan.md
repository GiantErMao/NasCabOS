# Android 本地神经 TTS 试验计划

## Summary

在现有 TXT 语音朗读功能上增加一个默认关闭的 Android 本地神经 TTS 试验：

- 推理运行时采用 Apache-2.0 的 `sherpa_onnx 1.13.8`。
- 首个模型采用 `matcha-icefall-zh-baker` 中文女声与 `vocos-22khz-univ` 声码器。
- 模型不进入 APK，用户首次启用时按需下载、校验并安装到应用私有目录。
- 该模型训练数据仅允许非商业使用，因此功能必须由
  `--dart-define=ENABLE_EXPERIMENTAL_LOCAL_TTS=true` 显式开启，并在下载前显示许可提示；
  默认构建继续只提供系统 TTS。
- 系统 TTS 始终保留。用户可以在系统 TTS 与本地神经 TTS 间切换，模型缺失、损坏、
  初始化失败或设备资源不足时可以立即切回系统 TTS。
- 首版按当前朗读 segment 合成完整 WAV 后播放，不实现句内 PCM 流式播放或预合成队列。
- 保持当前“阅读位置与播报位置彼此独立”的行为，只用当前播报句的强调色标识播放位置。

首轮只覆盖 Android。Web、iOS、HarmonyOS、桌面端、正式商用模型、多音色和情绪控制均不在本次范围。

## Current State Analysis

### 现有朗读架构

- `flutter_client/lib/modules/book/reader/service/txt_speech_engine.dart`
  已定义 `TxtSpeechEngine`，提供初始化、声音枚举、语速、播放、暂停、停止和释放接口。
- `flutter_client/lib/modules/book/reader/service/flutter_tts_speech_engine.dart`
  使用 `flutter_tts 4.2.5` 调用 Android 系统 TTS / Web Speech。
- `flutter_client/lib/modules/book/reader/controller/txt_speech_controller.dart`
  已负责稳定文本坐标、跨句/跨章队列、播放竞态 token、媒体会话、音频焦点及语速/声音持久化。
- `flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart`
  当前直接创建 `FlutterTtsSpeechEngine`，朗读位置变化只更新高亮，不强制翻页、滚动或覆盖阅读进度。
- `flutter_client/lib/modules/book/reader/view/txt_speech_control_sheet.dart`
  已提供播放控制、语速和系统声音选择。
- 音乐和朗读已通过 `AppMediaPlaybackCoordinator` 共用 Android MediaSession；本地引擎不得再创建第二套
  `AudioService`。

### 平台与依赖

- Android NDK 固定为 `28.2.13676358`，现有最低 Android 版本满足 sherpa-onnx 要求。
- 已有 `dio`、`crypto`、`path_provider`、`path` 和 `just_audio`，可复用下载、校验、目录和 WAV 播放能力。
- 需要新增：
  - `sherpa_onnx: 1.13.8`
  - `archive: 4.3.0`，用于安全解压 `.tar.bz2`
- 当前工作区已有未提交的 TXT 连续阅读、朗读与 MediaSession 修改；实施时必须保留，不做无关回退或格式化。

### 模型与许可结论

- `sherpa_onnx` 代码许可证为 Apache-2.0。
- `matcha-icefall-zh-baker`：
  - 单中文女声，22.05 kHz。
  - 声学模型解压后约 72 MB。
  - 还需要约 51 MB 的 `vocos-22khz-univ.onnx`。
  - 官方 Raspberry Pi 4 双线程 RTF 约 0.536，可作为移动 CPU 试验基线。
  - DataBaker 训练数据明确限定非商业用途，因此不可在默认或正式发行配置中启用。
- 下载清单固定为：
  - `matcha-icefall-zh-baker.tar.bz2`
    - URL: `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2`
    - size: `75463442`
    - SHA-256: `20de2ec034b55562609d6362771c934905dfe11d0f41ec103d593427ad9a7efb`
  - `vocos-22khz-univ.onnx`
    - URL: `https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx`
    - size: `53884024`
    - SHA-256: `0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081`
- 下载总量约 129 MB。安装前要求应用私有存储至少有 350 MB 可用空间，以覆盖压缩包、解压目录、
  声码器和原子替换的峰值占用。

参考：

- `https://pub.dev/packages/sherpa_onnx`
- `https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/matcha.html`
- `https://github.com/k2-fsa/sherpa-onnx/tree/master/flutter-examples/tts`

## Proposed Changes

### 1. 引入依赖并隔离实验入口

修改：

- `flutter_client/pubspec.yaml`
- `flutter_client/pubspec.lock`

新增固定版本依赖：

- `sherpa_onnx: 1.13.8`
- `archive: 4.3.0`

新增：

- `flutter_client/lib/modules/book/reader/service/local_tts_feature_flag.dart`

行为：

- 用 `bool.fromEnvironment('ENABLE_EXPERIMENTAL_LOCAL_TTS', defaultValue: false)` 控制本地神经 TTS。
- 仅 Android 且 flag 为 true 时暴露本地引擎；其他平台不导入 `dart:io` 或 sherpa 原生实现。
- 通过条件导入提供 Web/非 Android stub，保证现有 Web Release 构建和系统 TTS 不受影响。
- 不修改全局 ABI 支持；验收 APK 使用 `--target-platform android-arm64` 限制试验包体，正式通用构建仍需验证。

### 2. 建立固定模型清单与安全模型仓库

新增：

- `flutter_client/lib/modules/book/reader/model/local_tts_model_manifest.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store_stub.dart`

`LocalTtsModelManifest` 固定保存：

- model id/version/display name/locale
- 两个下载 URL、长度和 SHA-256
- 必需文件相对路径：
  - `matcha-icefall-zh-baker/model-steps-3.onnx`
  - `matcha-icefall-zh-baker/lexicon.txt`
  - `matcha-icefall-zh-baker/tokens.txt`
  - `matcha-icefall-zh-baker/phone.fst`
  - `matcha-icefall-zh-baker/date.fst`
  - `matcha-icefall-zh-baker/number.fst`
  - `vocos-22khz-univ.onnx`
- 非商业许可说明和来源链接。

模型目录：

- `<ApplicationSupport>/tts_models/matcha-icefall-zh-baker-v1/`
- 临时下载：同级 `.downloads/*.part`
- 解压暂存：同级 `.staging-<generation>/`
- 完成标记：目标目录内 `.ready.json`，包含 manifest version、文件长度、哈希和安装时间。

下载流程：

1. 检查 flag、Android 平台、可用存储空间。
2. 用 `Dio` 顺序下载两个 artifact，发布总进度、当前文件、已下载/总字节和状态。
3. 保留 `.part` 支持取消后断点续传；若服务器不接受 Range 并返回完整响应，则清空局部文件后重下。
4. 下载完成后流式计算 SHA-256；长度或哈希不符立即删除损坏文件。
5. 在后台 isolate 中用 `archive` 解压 bzip2 + tar：
   - 拒绝绝对路径、`..`、软链接和越过 staging 根目录的条目。
   - 不在主 isolate 中一次性持有全部解压内容。
6. 校验所有必需文件后写入 `.ready.json`，再原子重命名 staging 目录。
7. 删除已安装版本的压缩包和旧 staging；保留直接使用的 vocoder。

公开状态：

- `notInstalled`
- `downloading(progress)`
- `verifying`
- `extracting`
- `ready`
- `error(message)`

公开操作：

- `refresh()`
- `download()`
- `cancelDownload()`
- `deleteInstalledModel()`
- `resolvePaths()`

删除模型前必须先停止并释放本地引擎；正在朗读或加载时 UI 禁止删除。

### 3. 实现 isolate 化的 sherpa-onnx 合成 worker

新增：

- `flutter_client/lib/modules/book/reader/service/local_tts_worker.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_wav_writer.dart`

worker 生命周期：

- 每个 `SherpaOnnxSpeechEngine` 使用一个长生命周期 isolate。
- 主 isolate 和 worker 通过有类型的 request/response 消息通信。
- worker isolate 内单独调用 `sherpa_onnx.initBindings()`，创建一个 `OfflineTts` 并复用。
- 配置：
  - `OfflineTtsMatchaModelConfig`
  - acoustic model、vocoder、tokens、lexicon
  - `ruleFsts = phone.fst,date.fst,number.fst`
  - `numThreads = 2`
  - `debug = false`
  - `maxNumSenetences = 1`

合成请求包含：

- generation id
- text
- speed
- 临时 WAV 输出路径

worker 使用 `OfflineTtsGenerationConfig(speed: value, silenceScale: 0.2)` 合成 Float32 PCM，
转换为单声道 16-bit PCM WAV 并写到应用 cache 目录。返回：

- WAV path
- sample rate
- audio duration
- synthesis elapsed time
- RTF

停止/竞态：

- 每次请求有 generation id，旧结果不得触发播放。
- 使用 sherpa progress callback 响应取消；若原生调用未及时取消，结果返回后也必须因 generation 不匹配而删除，
  不能播放或推进队列。
- dispose 时发送释放请求并终止 isolate；所有临时 WAV 都需删除。
- worker 错误必须序列化为稳定错误码，不把 FFI 对象跨 isolate 传递。

### 4. 实现本地神经朗读引擎

新增：

- `flutter_client/lib/modules/book/reader/service/sherpa_onnx_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/service/sherpa_onnx_speech_engine_stub.dart`

`SherpaOnnxSpeechEngine` 实现现有 `TxtSpeechEngine`：

- `initialize`
  - 要求模型仓库处于 ready。
  - 启动 worker 并加载模型。
  - 初始化独立 `just_audio.AudioPlayer`，但不创建 AudioService/MediaSession。
- `getVoices`
  - 返回一个 `zh-CN · 本地神经女声（试验）`。
- `getMaxInputLength`
  - 返回 `180`，让现有 segment 拆分逻辑限制单次合成长文本延迟和内存峰值。
- `setRate`
  - 保持 UI 的 `0.5x-2.0x`，直接映射到 sherpa generation speed。
- `speak`
  - 请求 worker 生成 WAV。
  - generation 仍有效时交给 `just_audio` 播放。
  - 等待 `ProcessingState.completed` 后返回，使现有 `TxtSpeechController` 推进下一 segment。
- `pause`
  - 播放阶段调用 player pause。
  - 合成阶段取消当前请求；恢复时由 controller 从当前 segment 重新合成。
- `stop`
  - 立即停止 player、取消当前 generation 并删除临时 WAV。
- `dispose`
  - 释放 player、worker 和临时文件。

首版明确不做：

- 句内 PCM 流式播放
- 下一句预合成
- 音调/情绪参数
- 多音色
- WAV 持久缓存

### 5. 让朗读控制器支持系统/本地后端切换

修改：

- `flutter_client/lib/modules/book/reader/service/txt_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/controller/txt_speech_controller.dart`
- `flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart`

新增：

- `TxtSpeechBackend.system`
- `TxtSpeechBackend.localNeural`

控制器改动：

- 构造时接收系统引擎和可选本地引擎，不再只有一个固定 `engine`。
- 所有播放命令只路由到 active engine，现有队列、generation token、MediaSession 和音频焦点逻辑保持不变。
- `switchBackend` 必须：
  1. 停止当前朗读并增加 generation；
  2. 释放当前 active owner；
  3. 懒初始化目标引擎；
  4. 重新应用语速和该后端保存的声音；
  5. 保留当前文本坐标，但不自动开始播放。
- 持久化：
  - `txt_speech_backend`
  - `txt_speech_voice:system`
  - `txt_speech_voice:local_neural`
  - 共用现有 `txt_speech_rate`
- 若保存的是本地后端但 flag 关闭、模型不存在或初始化失败，启动时静默回退系统后端并清除无效选择。
- 本地合成/播放失败时进入现有 error 状态，不自动继续发声；UI提供“切换到系统语音”操作，避免意外双播。
- 本地播报位置只更新高亮和媒体通知，不改变阅读页位置或阅读进度，继续满足边阅读边播报。

页面创建：

- Android + 实验 flag 开启时注入两个 engine 和 `LocalTtsModelStore`。
- Web 与默认 Android 构建只注入 `FlutterTtsSpeechEngine`。

### 6. 增加模型管理和许可 UI

修改：

- `flutter_client/lib/modules/book/reader/view/txt_speech_control_sheet.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_mini_bar.dart`

控制 sheet：

- 实验开启时增加“语音引擎” segmented control：`系统` / `本地神经（试验）`。
- 未安装：
  - 显示预计下载 `约 129 MB`。
  - 点击下载先显示非商业许可确认；未同意不得下载。
  - 显示下载、校验、解压进度和取消按钮。
- 已安装：
  - 可切换本地引擎。
  - 显示占用空间、模型名称和“删除模型”命令。
  - 删除前二次确认。
- 初始化或播放失败时显示错误与“切回系统语音”。
- 模型管理区域采用普通列表/状态行，不嵌套卡片。

mini bar：

- 保持现有固定尺寸和播放控制。
- 可在“正在朗读”旁显示简短来源：`系统` 或 `本地`；状态切换不能改变布局尺寸。

### 7. 国际化

修改：

- `flutter_client/lib/core/languages/zh_cn.dart`
- `flutter_client/lib/core/languages/en_us.dart`
- 其余现有语言文件

新增 key：

- 语音引擎、系统、本地神经（试验）
- 模型未安装、下载模型、取消下载、校验、解压、下载失败、重试
- 模型大小/空间不足/校验失败/模型损坏
- 非商业许可标题、正文、来源链接、同意并下载
- 删除模型、删除确认、切回系统语音
- 本地引擎初始化/合成/播放失败

中英文提供准确翻译；其他语言先使用英文 fallback，避免显示原始 key。

### 8. 诊断与性能证据

只在 debug 日志记录，不上传遥测：

- 模型初始化耗时
- 每段字符数、合成耗时、音频时长、RTF
- worker 取消耗时
- 模型目录占用
- 错误码

日志不得记录完整书籍文本，只记录长度和最多 20 字的脱敏预览。

## Data Flow

1. 打开 TXT 阅读页，默认创建并使用系统 TTS。
2. 实验 flag 开启时，控制 sheet 查询 `LocalTtsModelStore`。
3. 用户确认非商业许可后下载两个 artifact，逐个校验 SHA-256，安全解压并原子安装。
4. 用户切换到本地后端；controller 停止旧引擎并初始化 sherpa worker。
5. 用户从当前位置或长按位置开始朗读；现有 controller 生成最多 180 字的 segment。
6. worker 在后台 isolate 合成 WAV，并返回 RTF 等元数据。
7. 本地 engine 通过 `just_audio` 播放 WAV；controller 与现有共享 MediaSession 发布播放状态。
8. 播放完成后 controller 推进下一 segment；页面只更新当前句强调色，不强制定位阅读视图。
9. 暂停、停止、切换后端或关闭页面时 generation 失效，旧 worker 结果被删除且不能继续推进。

## Failure Modes And Fallbacks

- 实验 flag 关闭：本地相关代码路径和 UI 不可见，系统 TTS 行为不变。
- 模型许可未确认：不发起下载。
- 空间不足：下载前阻止并显示所需空间。
- 网络中断：保留 `.part`，允许重试续传；系统 TTS仍可使用。
- Range 不支持：安全重启当前文件下载，避免拼接损坏文件。
- SHA-256/长度不匹配：删除 artifact，不解压。
- 路径穿越/软链接：拒绝整个 archive 并清理 staging。
- 应用在下载中退出：下次进入恢复 `.part`，staging 视为不完整并清理。
- 模型缺文件或 `.ready.json` 不匹配：标记损坏，禁止初始化，允许重新下载。
- FFI 初始化失败/ABI 不支持：释放 worker并切换按钮保持可用。
- 合成过慢：仍可停止；当前段不推进；不得卡住 Flutter UI isolate。
- 暂停发生在合成期：取消合成，继续时从当前 segment 重新合成。
- 音频焦点丢失/耳机拔出：沿用现有 controller 自动暂停。
- 来自旧 generation 的完成消息：删除 WAV，不播放、不推进。
- 模型删除：只删除应用私有 TTS 模型目录，不影响书籍、系统 TTS或其他缓存。

## Assumptions & Decisions

- 用户已确认首轮为 Android-only、轻量流畅优先、按需下载。
- 用户已确认首轮是内部试验，可以使用明确标注非商业用途的 Baker 模型。
- 实验默认关闭；任何可对外发布的构建都不得开启该 dart-define 或预装该模型。
- 第一版只验证单中文女声，不宣称“更多风格”或情绪化语音。
- 不自动下载模型，不使用后台静默下载。
- 不修改服务端 API、数据库或阅读进度协议。
- 不改变当前阅读/播报进度解耦和播报句强调色行为。
- 不修改第三方插件源码；只通过 pub 依赖使用 sherpa-onnx。
- ADB 设备当前未连接；实施后仅在设备可用时安装测试 APK，绝不为解决签名冲突自动卸载现有应用。

## Verification

### Unit tests

新增：

- `flutter_client/test/local_tts_model_store_test.dart`
  - manifest、长度和 SHA-256 校验
  - 下载进度聚合、取消与续传
  - Range 被忽略后的重下
  - 空间不足
  - archive 路径穿越/软链接拒绝
  - 原子安装、损坏恢复与删除
- `flutter_client/test/sherpa_onnx_speech_engine_test.dart`
  - 使用 fake worker/fake player 验证初始化、合成、播放完成
  - 合成期/播放期 pause、stop、dispose
  - 迟到 generation 结果不播放
  - 临时 WAV 清理
- 扩展 `flutter_client/test/txt_speech_controller_test.dart`
  - system -> local、local -> system
  - 切换停止当前播放并保留文本坐标
  - 本地模型不可用时回退系统
  - 本地错误后不自动双播
  - 后端和声音偏好分别持久化
- 扩展 control sheet widget tests：
  - flag 关闭不显示本地入口
  - 许可确认、下载/取消/错误/ready/删除状态

### Static/build verification

- `flutter pub get`
- 定向 `flutter analyze` 修改文件。
- 运行全部 TXT/TTS 测试和现有连续阅读测试。
- 默认构建：
  - `flutter build apk --debug`
  - `flutter build web --release`
  - 确认本地 UI 不可见，系统 TTS 不回归。
- 试验构建：
  - `flutter build apk --debug --target-platform android-arm64 --dart-define=ENABLE_EXPERIMENTAL_LOCAL_TTS=true`
- 对比引入 sherpa 前后的 APK 大小，并记录各 ABI native library 增量。

### Android device acceptance

设备连接后执行，优先使用现有目标设备；不自动卸载应用：

1. 首次进入显示系统 TTS，本地模型未静默下载。
2. 本地下载前出现非商业许可提示。
3. 下载进度、取消、重试和安装完成状态正确。
4. 切换本地后从当前页和长按字符位置分别起读。
5. 当前播报句使用强调色，用户仍可自由翻页/滚动，阅读位置不被播报位置拉回。
6. 暂停、继续、停止、上一段、下一段、语速均有效。
7. 熄屏、通知栏、锁屏和耳机媒体键仍通过共享 MediaSession 控制。
8. 系统 TTS 与本地 TTS 互切不会同时出声。
9. 删除模型后系统 TTS仍可正常使用。
10. 退出阅读页后无残留声音、worker 或临时 WAV。

性能验收使用固定 40、100、180 个中文字符样本，在冷/热启动各测 3 次：

- Flutter UI 无超过 100 ms 的合成长卡顿。
- 热模型、40 字样本首声目标不超过 3 秒。
- 合成 RTF 目标 `< 1.0`；若设备达不到，记录为试验失败并保持功能默认关闭，不用隐藏预合成掩盖结果。
- 连续朗读 30 分钟无崩溃、无持续增长的临时文件。
- 用 `adb shell dumpsys meminfo com.nascabos.mobile` 对比基线、加载模型、连续 30 分钟和释放后 PSS；
  区分模型常驻内存与释放后未回落的疑似泄漏。
