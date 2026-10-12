# NasCabOS 当前仓库修改总结

更新时间：2026-10-12

用途：作为新对话的上下文输入，说明当前本地仓库相对 Git 基线的主要修改。本文只记录工程状态和行为变化，不保存密码、Token、私钥等敏感信息。

## 0. 总览

当前工作区包含较大范围的未提交改动：

- 已修改跟踪文件：69 个
- 新增未跟踪源码/测试/文档目录若干
- 本地存在 Flutter/Android/Dart/Gradle 临时 SDK 或缓存目录：`.tmp_*`
- 本地存在两个疑似误生成的 `ssh-copy-id ...` 文件，应在提交前确认并删除或忽略

主要功能方向：

1. 视频刮削扩展：TMDB 之外新增 MetaTube，支持番号类影片刮削。
2. NFO 翻译：支持将 `plot/summary`、`genres` 翻译为中文，标题翻译独立开关。
3. 视频转码：增强 Linux/Intel VAAPI 硬解 + GPU 缩放 + 硬编链路，并新增转码诊断接口/UI。
4. 视频展示：番号类影片标题展示时保留/补充番号，减少只显示中文标题后无法识别的问题。
5. 书籍/音乐/加密空间/回收站：增加自然排序和更好的搜索/首字母过滤。
6. TXT 阅读器：新增连续阅读模式和朗读/TTS 能力，包括本地 Sherpa-ONNX TTS 框架。
7. API 连接容灾：增强失败后通道切换与服务器连接选择逻辑。
8. Android 构建：支持缺少正式签名配置时仍可构建，增加 TTS service 查询声明。

## 1. 视频刮削与 MetaTube

### 后端能力

新增 `MetaTubeClient`：

- 文件：`electron_server/src/workers/videoIndex/nfoFetchWorker/metatubeClient.js`
- 初始实现曾包含默认地址；当前版本已移除，需用户自行配置服务地址。
- 支持：
  - provider 列表
  - 影片搜索
  - 影片详情
  - 图片下载
  - `metatube://provider/id` 风格 scrape id 解析/构建

`nfoFetchRunner.js` 新增 MetaTube 刮削路径：

- 文件：`electron_server/src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- 支持根据文件名/目录名抽取番号。
- 自动刮削时可用 MetaTube 替代 TMDB。
- 可将 MetaTube 返回数据映射为 Jellyfin/Kodi NFO：
  - `title`
  - `originalTitle`
  - `sortTitle`
  - `plot`
  - `genres`
  - `tags`
  - `actors`
  - `directors`
  - `unique id`
- 支持下载 MetaTube poster/fanart。
- 针对 MetaTube detail 接口失败，支持用搜索结果合并详情的降级策略。

### 远端同步回本地的两处修复

这两处修改已经从远端 `nascabos` 容器同步回本地仓库：

1. `nfoFetchRunner.js`
   - 自动 MetaTube 刮削会把请求番号传入候选选择函数。
   - `_pickMetaTubeMovieWithDetails(results, expectedNumber)` 会按归一化番号精确筛选候选。
   - 如果请求里有番号但结果中没有精确匹配，则返回 `null`，不再选择无关影片。
   - 同步时也带回了“番号末尾 1900-2099 不再直接排除”的逻辑，用于兼容真实番号。

2. `videoScrapeWorker.js`
   - 文件：`electron_server/src/workers/videoIndex/videoScrapeWorker/videoScrapeWorker.js`
   - 手动 MetaTube 刮削前不清理旧 NFO/图片。
   - 目标：避免手动 MetaTube 刮削失败时先删掉原有资料。

当前已知边界：

- 如果 MetaTube 搜索结果本身缺少 `number` 字段，但详情里有正确番号，当前精确筛选会提前拒绝。更稳的后续优化是：当候选都没有 `number` 时，先拉详情再按详情里的 `number` 精确匹配。
- 手动 MetaTube 成功刮削后不会主动清理旧图片残留。后续可改为“成功后定向清理旧资料，失败时保留旧资料”。

### 前后端配置与手动搜索

后端配置接口：

- 文件：`electron_server/src/api/modules/video/config/videoConfigController.js`
- 新增配置项：
  - `videoScrapeSource`
  - `metatubeBaseUrl`
  - `metatubeToken`
  - `metatubeProvider`
  - `metatubeFallback`
- 保存 MetaTube 配置时会测试连接。

手动搜索接口：

- 文件：`electron_server/src/api/modules/video/tmdb/videoTmdbController.js`
- 当 `videoScrapeSource=metatube` 且媒体类型为 movie 时，搜索接口切到 MetaTube。
- MetaTube 搜索结果映射为前端已有 TMDB 搜索结果结构，便于复用手动刮削 UI。
- 支持按 scrape id 取详情。

手动刮削链路：

- 文件：
  - `electron_server/src/api/modules/video/scrape/videoScrapeController.js`
  - `electron_server/src/msgHandler/videoScrape.js`
  - `electron_server/src/workers/videoIndex/videoScrapeWorker/videoScrapeWorker.js`
- 手动刮削请求现在可携带 `scrapeId`，不再只支持数字 `tmdbId`。

Flutter 设置页：

- 文件：
  - `flutter_client/lib/modules/video/other_setting/controller/video_other_settings_controller.dart`
  - `flutter_client/lib/modules/video/other_setting/service/video_tmdb_settings_api_service.dart`
  - `flutter_client/lib/modules/video/other_setting/view/video_other_settings_view.dart`
- 新增 TMDB/MetaTube 刮削源选择、MetaTube 地址/Token/provider/fallback 配置。

## 2. NFO 元数据翻译

新增翻译客户端：

- 文件：`electron_server/src/workers/videoIndex/nfoFetchWorker/metadataTranslateClient.js`
- 支持 LibreTranslate-compatible `/translate` API。
- 支持配置：
  - `nfoTranslateApiUrl`
  - `nfoTranslateApiKey`
  - `nfoTranslateTargetLanguage`
- 公共 Google/MyMemory 端点曾遇到 429，不适合作为稳定默认服务。

后端刮削流程：

- 文件：`electron_server/src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- NFO 写入前可翻译：
  - `plot`
  - `genres`
  - `title`，由独立开关控制
- 翻译失败保留原文。
- 日志会记录实际发生变化的字段，例如：
  - `[nfoTranslate] translated fields: plot,genres,title`

配置接口：

- 文件：`electron_server/src/api/modules/video/config/videoConfigController.js`
- 新增返回/保存：
  - `nfoTranslateEnable`
  - `nfoTranslateTitleEnable`
  - `nfoTranslateTargetLanguage`
  - `nfoTranslateApiUrl`
  - `nfoTranslateApiKey`

Flutter 设置页：

- 文件：
  - `flutter_client/lib/modules/video/other_setting/controller/video_other_settings_controller.dart`
  - `flutter_client/lib/modules/video/other_setting/service/video_tmdb_settings_api_service.dart`
  - `flutter_client/lib/modules/video/other_setting/view/video_other_settings_view.dart`
- 新增：
  - 元数据翻译开关
  - 标题翻译独立开关
  - 翻译服务地址
  - 翻译 API Key

语言文件：

- 后端：`electron_server/language/zh-CN.json`, `electron_server/language/en-US.json`
- Flutter：`flutter_client/lib/core/languages/*.dart`
- 新增 MetaTube、NFO 翻译、转码信息、TXT 朗读等文案。

## 3. 视频转码与硬件加速

### VAAPI 硬件转码

文件：

- `electron_server/src/workers/ffmpegHwTestWorker.js`
- `electron_server/src/workers/transcodeWorker.js`

主要变化：

- Linux VAAPI 探测结果现在包含 decode args：
  - `-hwaccel vaapi`
  - `-hwaccel_device /dev/dri/renderD128`
  - `-hwaccel_output_format vaapi`
- `transcodeWorker.js` 支持 VAAPI `hw_full` 路径：
  - 硬解
  - `scale_vaapi` GPU 缩放
  - `h264_vaapi` / `hevc_vaapi` 硬编
- `canTryFull` 不再只允许 CUDA/NVENC，也允许 VAAPI full path。
- 如果 VAAPI full path 失败，会回退到硬编路径，再失败才回退 CPU。
- 字幕烧录、HDR tone mapping 等需要 CPU filter 的场景仍会避开 full hardware path。

播放转码稳定性：

- 新增输出 FPS 限制，超过 60fps 的转码输出限制到 60fps。
- 针对高帧率 4K VAAPI 场景限制实时输出宽度，降低硬件压力。
- 修正竖屏源的目标宽度计算。
- VAAPI 码率控制使用 CBR 相关参数。

远端验证状态：

- 远端 Docker 已重建并映射 `/dev/dri:/dev/dri`。
- 物理机 Intel UHD Graphics 730 / i915 / `/dev/dri/renderD128` 可用。
- 已验证实际 FFmpeg 命令进入 VAAPI full path：
  - `-hwaccel vaapi`
  - `-hwaccel_device /dev/dri/renderD128`
  - `-hwaccel_output_format vaapi`
  - `scale_vaapi`
  - `h264_vaapi`

### 转码信息接口和 UI

后端：

- 文件：
  - `electron_server/src/api/modules/videoPlayer/videoPlayerController.js`
  - `electron_server/src/api/modules/videoPlayer/videoPlayerRouter.js`
- 新增接口：
  - `GET /api/videoPlayer/transcode-info?playId=...`
- 返回：
  - 转码 session 状态
  - 请求参数
  - HLS segment 数量
  - 最新 segment 信息
  - ffprobe 探测到的输出 codec、分辨率、pix_fmt、bitrate 等

Flutter：

- 文件：
  - `flutter_client/lib/modules/video_player/controllers/parts/transcode_info.dart`
  - `flutter_client/lib/modules/video_player/views/components/transcode_info_dialog.dart`
  - `flutter_client/lib/modules/video_player/controllers/video_player_controller.dart`
  - `flutter_client/lib/modules/video_player/views/app_components/app_video_player_top_bar.dart`
  - `flutter_client/lib/modules/video_player/views/pc_components/pc_video_player_top_bar.dart`
- 播放器顶部新增“转码信息”入口。

## 4. 视频展示和番号标题

文件：

- `flutter_client/lib/modules/video/base/video_utils/video_item_utils.dart`
- `flutter_client/lib/modules/video/base/views/app_video_item_poster.dart`
- `flutter_client/lib/modules/video/base/views/video_item_poster.dart`
- `flutter_client/lib/modules/video/base/views/video_item_recommend.dart`
- `flutter_client/lib/modules/video/detail/view/video_detail_page.dart`
- `flutter_client/lib/modules/video/detail/view/parts/video_detail_top_section.dart`
- `flutter_client/lib/modules/video/detail/view/parts/app_video_detail_top_section.dart`
- `flutter_client/lib/modules/video/detail/view/parts/video_detail_storyline_section.dart`
- `flutter_client/lib/modules/video/home/view/app_video_home_page.dart`

主要变化：

- 新增前端番号识别工具：
  - FC2
  - 1Pondo
  - 常见 `ABC-123` 风格
- 视频标题显示时，如果 NFO 标题不包含番号，会自动以 `番号 + 标题` 形式展示。
- 多个首页、海报、详情页组件改用统一标题解析函数。

注意：

- 前端 `_isLikelyVideoCode` 目前仍排除末尾 1900-2099；后端远端同步已取消这个排除。后续可评估是否需要前后端统一。

## 5. 书籍、音乐、加密空间和回收站排序/搜索

新增自然排序工具：

- 文件：`electron_server/src/utils/naturalSortUtil.js`
- 相关测试：
  - `electron_server/tests/bookNaturalSortUtil.test.js`

书籍列表：

- 文件：
  - `electron_server/src/api/modules/book/list/bookListService.js`
  - `electron_server/src/api/modules/book/list/bookSearchUtil.js`
  - `electron_server/tests/bookSearchUtil.test.js`
  - `flutter_client/lib/modules/book/list/controller/book_list_controller.dart`
  - `flutter_client/lib/modules/book/list/service/book_list_api_service.dart`
  - `flutter_client/lib/modules/book/list/view/book_list_page.dart`
- 变化：
  - 书名/文件名排序使用自然排序，避免 `第10章` 排在 `第2章` 前。
  - 搜索抽为 `bookSearchUtil`。
  - 支持首字母/`#` 过滤。
  - series 列表搜索可匹配子书。

音乐列表：

- 文件：`electron_server/src/api/modules/music/list/musicListService.js`
- 变化：
  - 文件名、标题、艺人、专辑、年份支持自然排序。
  - 分组列表按自然排序处理。

加密空间：

- 文件：`electron_server/src/api/modules/encryptedSpace/encryptedSpaceController.js`
- 变化：
  - `show_name` 排序改为自然排序分页。

照片回收站：

- 文件：`electron_server/src/api/modules/photo/timeline/photoTimeLineTrashOps.js`
- 变化：
  - 回收站支持按文件名自然排序。

## 6. TXT 阅读器和 TTS

依赖和平台配置：

- `flutter_client/pubspec.yaml`
  - 新增 `flutter_tts`
  - 新增 `sherpa_onnx`
  - 新增 `archive`
  - 新增 `scrollable_positioned_list`
- `flutter_client/android/app/src/main/AndroidManifest.xml`
  - 新增 `android.intent.action.TTS_SERVICE` 查询。

新增音频协调：

- `flutter_client/lib/core/audio/app_media_playback_coordinator.dart`
- `flutter_client/lib/core/audio/app_media_playback_delegate.dart`

新增朗读控制和模型服务：

- `flutter_client/lib/modules/book/reader/controller/txt_speech_controller.dart`
- `flutter_client/lib/modules/book/reader/model/local_tts_model_manifest.dart`
- `flutter_client/lib/modules/book/reader/model/txt_speech_segment.dart`
- `flutter_client/lib/modules/book/reader/service/flutter_tts_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_feature_flag.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store_io.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store_shared.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_model_store_stub.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_wav_writer.dart`
- `flutter_client/lib/modules/book/reader/service/local_tts_worker.dart`
- `flutter_client/lib/modules/book/reader/service/sherpa_onnx_speech_engine.dart`
- `flutter_client/lib/modules/book/reader/service/sherpa_onnx_speech_engine_io.dart`
- `flutter_client/lib/modules/book/reader/service/sherpa_onnx_speech_engine_stub.dart`
- `flutter_client/lib/modules/book/reader/service/txt_speech_engine.dart`

TXT 阅读器 UI：

- `flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart`
- `flutter_client/lib/modules/book/reader/view/txt_continuous_reader_view.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_control_sheet.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_mini_bar.dart`
- `flutter_client/packages/flutter_read/lib/src/read_controller.dart`
- `flutter_client/packages/flutter_read/lib/src/read_controller_impl.dart`
- `flutter_client/packages/flutter_read/lib/src/read_painter.dart`
- `flutter_client/packages/flutter_read/lib/src/read_view.dart`

主要变化：

- TXT 阅读器支持分页/连续阅读模式。
- 连续阅读模式记录当前位置并可回切分页。
- 支持从当前位置朗读。
- 支持点击位置发起朗读。
- 支持 Web/P2P 场景下通过 P2P channel 读取 TXT 内容。
- `flutter_read` 包增强位置定位、绘制和控制能力。
- 阅读器增加朗读 mini bar 和控制面板。

相关测试：

- `flutter_client/test/local_tts_availability_test.dart`
- `flutter_client/test/local_tts_model_manifest_test.dart`
- `flutter_client/test/local_tts_wav_writer_test.dart`
- `flutter_client/test/txt_continuous_reader_view_test.dart`
- `flutter_client/test/txt_speech_controller_test.dart`
- `flutter_client/test/txt_speech_location_test.dart`
- `flutter_client/test/txt_speech_mini_bar_test.dart`

## 7. 音乐播放协调

文件：

- `flutter_client/lib/modules/music/play_service/controller/music_play_service_controller.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/audio_handler.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/lifecycle.dart`
- `flutter_client/lib/modules/music/play_service/controller/parts/playback.dart`

主要变化：

- 配合新增的 `AppMediaPlaybackCoordinator`，让音乐播放与 TXT 朗读/其他媒体播放之间可以做暂停、恢复或互斥协调。
- 调整 audio handler、生命周期和播放逻辑以适配协调器。

## 8. API 连接容灾和服务器选择

文件：

- `flutter_client/lib/core/api/api_parts/api_controller_failover.dart`
- `flutter_client/lib/core/api/base_api_service.dart`
- `flutter_client/lib/modules/auth/views/server_list/server_list_controller.dart`
- 测试：`flutter_client/test/base_api_service_failover_test.dart`

主要变化：

- 新增 `connectToServerUsingBestChannel`，可基于 server id 尝试更合适的直连/P2P 通道。
- failover 探测支持：
  - 跳过内网直连地址
  - 不包含当前 base URL
  - 请求失败后尝试恢复连接
- `BaseApiService` 增加可覆写的错误恢复入口。

## 9. Android 构建和分析配置

文件：

- `flutter_client/android/app/build.gradle.kts`
- `flutter_client/android/app/src/main/AndroidManifest.xml`
- `flutter_client/android/app/src/main/kotlin/com/nascabos/mobile/MainActivity.kt`
- `flutter_client/analysis_options.yaml`

主要变化：

- Release signing 改为仅在 keystore 配置完整时启用，方便测试环境构建。
- Android manifest 增加 TTS service 查询。
- Kotlin `MainActivity` 有本地 TTS/平台能力相关修改。
- Flutter analyzer 排除 build、android、ios、web、windows、macos、linux 等平台目录，降低本地分析噪声。

## 10. 其他后端视频列表/详情变化

文件：

- `electron_server/src/api/modules/video/detail/detailService.js`
- `electron_server/src/api/modules/video/list/videoListService.js`

主要变化：

- 有少量视频详情/列表字段或排序相关调整，配合 MetaTube/NFO 展示、标题处理和列表行为。

## 11. 已生成或应保留的文档

新增或更新文档：

- `docs/DEPLOYMENT_AND_ANDROID_BUILD.md`
  - 统一远端 Docker、Web、服务端、APK 构建发布流程。
- `docs/CURRENT_DEVELOPMENT_PROGRESS.md`
  - 当前开发/部署进度总结。
- `docs/REPO_CHANGES_SUMMARY_20261012.md`
  - 本文。

## 12. 未跟踪文件和目录

需要提交或确认的新增源码/测试：

- `electron_server/src/api/modules/book/list/bookSearchUtil.js`
- `electron_server/src/utils/naturalSortUtil.js`
- `electron_server/src/workers/videoIndex/nfoFetchWorker/metadataTranslateClient.js`
- `electron_server/src/workers/videoIndex/nfoFetchWorker/metatubeClient.js`
- `electron_server/tests/`
- `flutter_client/lib/core/audio/`
- `flutter_client/lib/modules/book/reader/controller/`
- `flutter_client/lib/modules/book/reader/model/`
- `flutter_client/lib/modules/book/reader/service/`
- `flutter_client/lib/modules/book/reader/view/txt_continuous_reader_view.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_control_sheet.dart`
- `flutter_client/lib/modules/book/reader/view/txt_speech_mini_bar.dart`
- `flutter_client/lib/modules/video_player/controllers/parts/transcode_info.dart`
- `flutter_client/lib/modules/video_player/views/components/transcode_info_dialog.dart`
- `flutter_client/test/`

需要谨慎处理的本地环境/临时文件：

- `.tmp_android_home/`
- `.tmp_android_sdk/`
- `.tmp_dart_home/`
- `.tmp_flutter_home/`
- `.tmp_flutter_sdk/`
- `.tmp_gradle_home/`
- `.tmp_gradle_project_cache/`
- `debug-matcha-install-failure.md`
- `ssh-copy-id -p 13122 ermao@ddns.ermao.fun`
- `ssh-copy-id -p 13122 ermao@ddns.ermao.fun.pub`

建议：

- `.tmp_*` 目录通常不应提交。
- `ssh-copy-id ...` 两个文件看起来像误生成的密钥/命令残留，提交前应确认内容并删除或加入忽略。
- `debug-matcha-install-failure.md` 如果只是临时调试记录，可不提交；如果需要保留，应检查是否包含设备路径、账号或其他敏感信息。

## 13. 本地验证记录

已明确做过的验证：

- `electron_server/src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
  - `node --check` 通过。
- `electron_server/src/workers/videoIndex/videoScrapeWorker/videoScrapeWorker.js`
  - `node --check` 通过。
- 远端同步回本地后，这两个文件与远端容器版本 diff 为空。
- 后端多个视频刮削/翻译/转码文件此前执行过 `node --check`。
- Flutter `analyze` 曾输出 `No issues found`，但本地 sandbox 对 `~/.dartServer/.analysis-driver` 的写入会产生环境权限噪声。
- APK 曾构建并签名：
  - `flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2042-signed.apk`
  - 版本：`1.2.7 (2042)`
  - 已安装到设备：`e6fc7cb7`

## 14. 远端部署状态

远端信息：

- SSH：`ermao@ddns.ermao.fun:13122`
- SSH alias：`nascabos`
- 容器：`nascabos`
- 公网：`http://ddns.ermao.fun:18761/`
- 容器服务端：`/nascabos/src`
- 容器 Web：`/nascabos/web/main`

已完成：

- MetaTube 和 NFO 翻译服务端逻辑已发布过。
- Docker 已重建以支持 Intel VAAPI：
  - `/dev/dri:/dev/dri`
  - `video` / `render` 组权限
  - 容器内安装 Intel VAAPI 驱动
- VAAPI `hw_full` 入口修复已发布并验证。

近期镜像：

- `nascabos-custom:20261009-210114`
- `nascabos-custom-hwdecode-20261009-213314`
- `nascabos-custom:vaapi-full-entry-20261009-214202`

注意：

- 远端曾经在对话中暴露 sudo/WebDAV 相关敏感信息，应提醒用户轮换。
- 不要把密码、refresh token、WebDAV 密码或私钥写入仓库。

## 15. 后续建议

1. 提交前先整理工作区：
   - 确认 `.tmp_*` 目录是否加入 `.gitignore`。
   - 删除误生成的 `ssh-copy-id ...` 文件。
   - 决定 `debug-matcha-install-failure.md` 是否保留。

2. 补齐测试：
   - MetaTube 番号精确匹配：
     - 精确命中
     - 搜索结果无关时拒绝
     - 搜索结果缺 `number` 但详情有 `number` 的情况
   - 手动 MetaTube 失败时旧 NFO/图片保留。
   - VAAPI full path 和 fallback path。

3. 前后端番号识别规则统一：
   - 后端已允许 1900-2099 作为番号尾号。
   - 前端目前仍排除该区间，需要评估是否同步。

4. 下一次发布前按 `docs/DEPLOYMENT_AND_ANDROID_BUILD.md`：
   - 明确发布文件清单。
   - 不要无差别同步整个 dirty 工作区。
   - 远端替换前创建备份。
   - 发布后验证日志、接口、Web hash 和业务路径。

## 16. 主要修改文件清单

已修改跟踪文件：

```text
electron_server/language/en-US.json
electron_server/language/zh-CN.json
electron_server/src/api/modules/book/list/bookListService.js
electron_server/src/api/modules/encryptedSpace/encryptedSpaceController.js
electron_server/src/api/modules/music/list/musicListService.js
electron_server/src/api/modules/photo/timeline/photoTimeLineTrashOps.js
electron_server/src/api/modules/video/config/videoConfigController.js
electron_server/src/api/modules/video/detail/detailService.js
electron_server/src/api/modules/video/list/videoListService.js
electron_server/src/api/modules/video/scrape/videoScrapeController.js
electron_server/src/api/modules/video/tmdb/videoTmdbController.js
electron_server/src/api/modules/videoPlayer/videoPlayerController.js
electron_server/src/api/modules/videoPlayer/videoPlayerRouter.js
electron_server/src/msgHandler/videoScrape.js
electron_server/src/workers/ffmpegHwTestWorker.js
electron_server/src/workers/transcodeWorker.js
electron_server/src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js
electron_server/src/workers/videoIndex/videoScrapeWorker/videoScrapeWorker.js
flutter_client/analysis_options.yaml
flutter_client/android/app/build.gradle.kts
flutter_client/android/app/src/main/AndroidManifest.xml
flutter_client/android/app/src/main/kotlin/com/nascabos/mobile/MainActivity.kt
flutter_client/lib/core/api/api_parts/api_controller_failover.dart
flutter_client/lib/core/api/base_api_service.dart
flutter_client/lib/core/languages/*.dart
flutter_client/lib/modules/auth/views/server_list/server_list_controller.dart
flutter_client/lib/modules/book/list/controller/book_list_controller.dart
flutter_client/lib/modules/book/list/service/book_list_api_service.dart
flutter_client/lib/modules/book/list/view/book_list_page.dart
flutter_client/lib/modules/book/reader/view/book_txt_reader_page.dart
flutter_client/lib/modules/music/play_service/controller/music_play_service_controller.dart
flutter_client/lib/modules/music/play_service/controller/parts/audio_handler.dart
flutter_client/lib/modules/music/play_service/controller/parts/lifecycle.dart
flutter_client/lib/modules/music/play_service/controller/parts/playback.dart
flutter_client/lib/modules/video/base/video_utils/video_item_utils.dart
flutter_client/lib/modules/video/base/views/app_video_item_poster.dart
flutter_client/lib/modules/video/base/views/video_item_poster.dart
flutter_client/lib/modules/video/base/views/video_item_recommend.dart
flutter_client/lib/modules/video/detail/view/parts/app_video_detail_top_section.dart
flutter_client/lib/modules/video/detail/view/parts/video_detail_storyline_section.dart
flutter_client/lib/modules/video/detail/view/parts/video_detail_top_section.dart
flutter_client/lib/modules/video/detail/view/video_detail_page.dart
flutter_client/lib/modules/video/home/view/app_video_home_page.dart
flutter_client/lib/modules/video/other_setting/controller/video_other_settings_controller.dart
flutter_client/lib/modules/video/other_setting/service/video_tmdb_settings_api_service.dart
flutter_client/lib/modules/video/other_setting/view/video_other_settings_view.dart
flutter_client/lib/modules/video/scrape/service/video_scrape_api_service.dart
flutter_client/lib/modules/video/tmdb/service/video_tmdb_api_service.dart
flutter_client/lib/modules/video/tmdb/view/video_search_media_dialog.dart
flutter_client/lib/modules/video_player/controllers/video_player_controller.dart
flutter_client/lib/modules/video_player/views/app_components/app_video_player_top_bar.dart
flutter_client/lib/modules/video_player/views/pc_components/pc_video_player_top_bar.dart
flutter_client/packages/flutter_read/lib/src/read_controller.dart
flutter_client/packages/flutter_read/lib/src/read_controller_impl.dart
flutter_client/packages/flutter_read/lib/src/read_painter.dart
flutter_client/packages/flutter_read/lib/src/read_view.dart
flutter_client/pubspec.yaml
```
