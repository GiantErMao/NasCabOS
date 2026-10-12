# TXT 语音阅读实施计划

## Summary

为 Flutter TXT 阅读器增加语音朗读，首期覆盖 Android 与 Web：

- 使用 MIT 许可的 `flutter_tts 4.2.5`，调用 Android 系统 TTS 与浏览器 Web Speech。
- 点击工具栏朗读按钮时从当前稳定文本位置开始；长按正文后通过“从这里朗读”从指定字符位置开始。
- 支持播放、暂停/继续、停止、上一段、下一段、语速和系统声音选择。
- 当前朗读段高亮，分页模式自动翻页，连续模式自动滚动跟随。
- Android 支持后台、通知栏/锁屏和耳机媒体键；Web 仅保证前台朗读，后台持续性按浏览器能力尽力而为。
- 阅读位置继续使用现有 `chapterIndex/sentenceIndex/wordIndex`，不新增服务端数据库字段或迁移。

## Current State Analysis

### TXT 数据与位置模型

- `flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart`
  - 统一加载 TXT 字节并交给 `flutter_read`。
  - 分页和连续模式已共享 `ChapterData(chapterIndex, sentenceIndex, wordIndex)`。
  - 本地阅读位置和服务端页进度已有节流持久化。
- `flutter_client/packages/flutter_read/lib/src/read_data.dart`
  - `BookSentence` 保存文本、句索引和原始索引。
  - `BookLine` 保存句内 `startIndex/endIndex`，可用于分页模式命中具体字符位置。
- `flutter_client/lib/modules/book/reader/view/txt_continuous_reader_view.dart`
  - 已按句构造懒加载 block，并能根据 `ChapterData` 定位和滚动。
- `flutter_client/packages/flutter_read/lib/src/read_view.dart`
  - 分页正文由 `CustomPaint` 绘制，目前只有点击翻页/菜单手势，没有长按命中与朗读高亮。

### 音频架构

- 项目已有 `audio_service`、`audio_session`、`just_audio`。
- `MusicPlayServiceController` 在首次音乐播放时调用一次 `AudioService.init`，由 `_MusicAudioHandler` 独占 Android MediaSession。
- TTS 不能再初始化第二个 `AudioService`；必须将现有 handler 提升为共享媒体控制入口，在音乐与 TTS 之间切换 active delegate。
- Android Manifest 已有媒体前台服务权限和 AudioService 声明，但缺少 Android 11+ 查询 TTS 服务的 `<queries>` intent。

### 方案选择

- 采用 `flutter_tts`，不引入神经 TTS 模型下载。
- 原因：安装包增量小、支持 Android/Web、具备语音/语言/语速及完成回调，且仓库内 `audio_service` 示例已有相同组合的参考实现。
- Android 24-25 没有可靠原生暂停/范围回调：降级为停止当前 utterance，继续时从当前朗读片段开头重播；Android 26+ 使用插件暂停能力。
- Web Speech 受浏览器标签冻结、用户手势与系统声音可用性限制，不承诺锁屏后继续。

## Proposed Changes

### 1. 引入 TTS 依赖与平台声明

文件：

- `flutter_client/pubspec.yaml`
- `flutter_client/pubspec.lock`
- `flutter_client/android/app/src/main/AndroidManifest.xml`

改动：

- 添加 `flutter_tts: 4.2.5`，锁定已评估版本。
- 在 Android `<queries>` 中声明 `android.intent.action.TTS_SERVICE`。
- 不申请录音权限；TTS 只输出音频。

### 2. 将 Android MediaSession 改为音乐/TTS 共用

新增：

- `flutter_client/lib/core/audio/app_media_playback_delegate.dart`
- `flutter_client/lib/core/audio/app_media_playback_coordinator.dart`

修改：

- `flutter_client/lib/main.dart`
- `flutter_client/lib/modules/music/play_service/controller/music_play_service_controller.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/lifecycle.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/audio_handler.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/playback.dart`

设计：

- `AppMediaPlaybackDelegate` 定义 `play/pause/stop/skipNext/skipPrevious`，并暴露当前 `MediaItem` 与 `PlaybackState`。
- `AppMediaPlaybackCoordinator` 是永久单例，Android 上唯一负责 `AudioService.init`，保留现有通知 channel id，避免重置用户通知设置。
- handler 只转发系统媒体操作给当前 active delegate，不直接依赖图书或音乐业务。
- 音乐控制器注册 music delegate；TXT TTS 开始时注册并激活 speech delegate。
- owner 切换规则：
  - TTS 开始前暂停音乐并记住音乐状态，但 TTS 结束后不自动恢复音乐，避免意外出声。
  - 用户主动播放音乐时停止 TTS，并切回 music delegate。
  - 同一时间只允许一个 active owner。
- Web 不初始化 AudioService，仅保留前台 TTS 控制。
- 现有音乐播放、通知栏、耳机键和锁屏行为保持不变。

### 3. 建立可测试的 TXT 朗读队列与控制器

新增：

- `flutter_client/lib/modules/book/reader/model/txt_speech_segment.dart`
- `flutter_client/lib/modules/book/reader/service/txt_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/service/flutter_tts_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/controller/txt_speech_controller.dart`

职责：

- `TxtSpeechSegment` 保存：
  - `chapterIndex`
  - `sentenceIndex`
  - `startWordIndex/endWordIndex`
  - 待朗读文本
- `TxtSpeechEngine` 抽象插件调用，便于单测使用 fake engine，不直接 mock MethodChannel。
- `FlutterTtsSpeechEngine`：
  - 初始化完成、错误、取消、进度回调。
  - 启用 `awaitSpeakCompletion(true)`。
  - 查询系统语言/声音和 Android 最大输入长度。
  - 按 `getSpeechRateValidRange()` 将 UI 的 `0.5x-2.0x` 映射到插件有效范围；无范围信息时映射到 `0.25-1.0`。
- `TxtSpeechController`：
  - 从 `ReadController.getSentenceFromIndex()` 按稳定坐标构造惰性队列。
  - 第一段从指定 `wordIndex` 开始，后续顺序跨句、跨章。
  - 空白段跳过；超长文本优先按中文/英文标点切分，再按引擎最大长度硬切，保留每个 chunk 的文本坐标。
  - 使用 generation token 防止 stop/seek/切书后旧 completion 回调继续推进。
  - 状态为 `idle/loading/playing/paused/error/completed`。
  - 提供 `startAt`、`play`、`pause`、`stop`、`previousSegment`、`nextSegment`、`setRate`、`setVoice`。
  - 当前 segment 开始时立即发布位置，驱动高亮、自动跟随和阅读进度持久化。
  - 声音、语速通过 `CacheManager` 持久化；声音不存在时回退同语言默认声音，再回退系统默认。
  - 页面销毁时停止并释放 delegate；应用仅进入后台时不停止。

### 4. 支持正文长按命中指定字符

修改：

- `flutter_client/packages/flutter_read/lib/src/read_controller.dart`
- `flutter_client/packages/flutter_read/lib/src/read_controller_impl.dart`
- `flutter_client/packages/flutter_read/lib/src/read_view.dart`
- `flutter_client/packages/flutter_read/lib/src/read_painter.dart`
- `flutter_client/lib/modules/book/reader/view/txt_continuous_reader_view.dart`

分页模式：

- 为 `ReadView` 增加可选的 `onLocationLongPress(ChapterData, Offset globalPosition)` 和 `highlightedLocation`。
- 根据当前页 `BookPage.lines`、阅读 padding、行高、字宽和对齐方式，将长按坐标映射到 `BookLine` 与句内字符索引。
- 命中正文外区域时不弹菜单；命中标题或正文时返回规范化 `ChapterData`。
- 在已有 picture 上方增加轻量 highlight painter，仅绘制当前朗读 segment 对应行的半透明背景，不重新生成整页 picture。

连续模式：

- 为每个 block 增加 `onLongPressStart`，用 `TextPainter.getPositionForOffset` 计算 block 内字符索引。
- 接收 `highlightedLocation`；当前 segment 使用主题强调色的低透明背景。
- `didUpdateWidget` 检测朗读位置变化并调用现有 offset 表自动滚动，使当前段保持可见。

共同约束：

- 长按只产生位置，不直接播放；在触点显示包含“从这里朗读”的小型菜单，避免误触。
- 高亮颜色从当前主题 `colorScheme.primary` 派生，确保亮/暗背景可辨认。

### 5. 阅读页集成控制、位置同步与持久化

新增：

- `flutter_client/lib/modules/book/reader/view/txt_speech_control_sheet.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_mini_bar.dart`

修改：

- `flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart`

交互：

- AppBar 增加 `record_voice_over` 图标，tooltip 为“语音朗读”。
- 未播放时打开控制 sheet，主操作“从当前位置朗读”。
- 长按正文菜单选择“从这里朗读”后，从命中坐标启动。
- 播放期间底部显示固定高度 mini bar：上一段、播放/暂停、下一段、停止；布局不随状态变化。
- 控制 sheet 提供：
  - 语速选择 `0.5x/0.75x/1.0x/1.25x/1.5x/2.0x`
  - 系统声音下拉菜单，按 locale 分组
  - 当前平台不支持或无声音时的明确错误
- TTS 位置变化时：
  - 更新 `_lastLocation` 与 `_uiProgress`
  - 分页调用 `jumpToLocation`
  - 连续模式交给 view 自动滚动
  - 继续复用 `_schedulePersist`，使朗读进度可恢复
- 切换分页/连续模式、重新选择编码或重新排版时保留 TTS 坐标；数据重载期间暂停，成功后从同一稳定坐标恢复，失败则停止。
- 返回/关闭阅读页时停止 TTS；锁屏或应用后台不触发页面 dispose，因此 Android 可继续播放。

### 6. 国际化

修改：

- `flutter_client/lib/core/languages/zh_cn.dart`
- `flutter_client/lib/core/languages/en_us.dart`
- 其余现有语言文件 `ar_ar.dart`、`de_de.dart`、`es_es.dart`、`fr_fr.dart`、`id_id.dart`、`ja_jp.dart`、`ko_kr.dart`、`pt_br.dart`、`ru_ru.dart`、`th_th.dart`、`vi_vn.dart`

新增 key 覆盖语音朗读、从当前位置/这里朗读、播放控制、语速、声音、无可用声音、浏览器限制、初始化/播放失败。非中英文先提供准确英文 fallback，避免界面直接显示 key。

## Data Flow

1. TXT 加载完成后，页面创建 `TxtSpeechController` 并注入现有 `ReadController`。
2. 用户点击工具栏时读取 `_currentLocation()`；长按时由对应阅读 view 返回精确 `ChapterData`。
3. controller 从章节句子数据生成首个 segment，激活 TTS audio owner，并调用 `flutter_tts.speak`。
4. segment 开始时发布稳定文本坐标：
   - 页面更新进度并持久化；
   - 分页/连续 view 跳转；
   - view 高亮当前 segment；
   - Android handler 更新通知栏 `MediaItem` 和播放状态。
5. completion 推进下一个 segment；pause/stop/skip 增加 generation，旧回调失效。
6. 到达末尾后发布 completed，清除高亮、释放 audio owner，保留最终阅读位置。

## Failure Modes And Fallbacks

- 没有系统 TTS/目标语言：显示可操作错误，保留阅读功能，不崩溃。
- Web 首次播放被浏览器用户手势策略拒绝：保持 paused/error，要求用户再次点击播放，不自动重试循环。
- Web 标签后台被冻结：回到前台后保持当前位置，用户可继续。
- Android 24-25 暂停：从当前 segment 开头恢复；UI 不承诺词级恢复。
- 来电、其他应用抢占音频焦点、耳机拔出：自动暂停，不自动跨状态继续。
- 音乐与 TTS 竞争：后发起者停止/暂停前一个 owner，避免同时出声。
- TTS 插件 completion/error 重复或迟到：generation token 与幂等 Completer 防止重复推进。
- 空章节、全空白文本、越界位置：规范化到下一个可读 segment；全书无内容则进入 completed。
- 页面销毁、切书、编码重载失败：停止引擎并清理 handler/delegate，不能留下后台孤立任务。

## Verification

### Unit tests

新增：

- `flutter_client/test/txt_speech_controller_test.dart`
  - 从 `chapter/sentence/word` 指定位置开始。
  - 跨句、跨章推进。
  - 空白段和超长段切分。
  - pause/resume/stop/skip 与迟到回调竞态。
  - 声音/语速回退及持久化。
- `flutter_client/test/txt_speech_location_test.dart`
  - 分页模式长按坐标命中正确 sentence/word。
  - 连续模式长按偏移映射正确。
- 扩展 `flutter_client/test/txt_continuous_reader_view_test.dart`
  - 高亮变化和自动跟随。
- 音频 coordinator 测试：
  - music -> TTS、TTS -> music owner 切换。
  - 系统 play/pause/next/previous 转发给 active delegate。
  - owner 释放后状态清理。

### Static/build verification

- `flutter analyze` 针对修改文件。
- 运行所有新增 TXT/TTS 测试及现有 `txt_continuous_reader_view_test.dart`。
- `flutter build apk --debug` 验证插件注册、Manifest 与最低 SDK。
- `flutter build web --release` 验证 Web plugin 与 tree shaking。

### Android device acceptance

- 从当前页开始朗读。
- 分页和连续模式分别长按某字符后“从这里朗读”。
- 当前段高亮且自动翻页/滚动。
- 暂停、继续、停止、上一段、下一段。
- 语速和系统声音切换，重进阅读页后保留设置。
- 熄屏后继续朗读；锁屏/通知栏/耳机键可控制。
- 播放音乐后启动 TTS，以及 TTS 中启动音乐，确认不会同时出声。
- 来电/音频焦点中断和拔耳机时暂停。
- 退出阅读页后通知消失且无残留语音。

### Web acceptance

- Chrome/Android Chrome 中从当前/长按位置朗读。
- 高亮、自动跟随、播放控制和偏好持久化。
- 刷新后无 Service Worker 旧资源问题。
- 浏览器无可用声音或拒绝播放时显示错误。
- 切后台后不对持续朗读作保证；回前台可从记录位置继续。

## Assumptions & Decisions

- 首期不覆盖 HarmonyOS 原生客户端、iOS、macOS、Windows；接口保持可扩展。
- 不做服务端音频合成、音频文件缓存、云端语音或神经模型下载。
- 不做单词级卡拉 OK 高亮；高亮粒度为当前朗读 segment，位置精度仍保留到 word index。
- 不增加定时关闭、睡眠计时、音调/音量调节；首期仅语速和声音选择。
- 不修改第三方插件源码；`flutter_read` 是仓库内 path package，可按项目需求扩展。
- 保持现有未提交修改，不做无关重构或格式化。
- 实现完成后先本地验证，不自动部署 Docker 或安装 APK，除非用户另行要求。

## References

- `flutter_tts 4.2.5`: https://pub.dev/packages/flutter_tts
- MIT license: https://pub.dev/packages/flutter_tts/license
- API/rate range: https://pub.dev/documentation/flutter_tts/latest/flutter_tts/FlutterTts-class.html
