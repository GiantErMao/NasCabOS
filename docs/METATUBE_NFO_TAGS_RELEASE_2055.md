# MetaTube NFO 标签策略发布（2026-10-15）

本次发布服务端 MetaTube 文件名标签规则、电影列表/首页标签字段，以及 Android 电影卡片“中 / 破”角标。没有发布 Web、Harmony 或 TV 客户端。

## 规则与存量刷新

视频文件去掉扩展名后匹配结尾，不区分大小写：`-C`、`ch` 添加“中文字幕”；`-U` 添加“破解版本”；`-UC` 同时添加两者。光盘目录直接使用目录名。保留原标签并去重。自动及手动 MetaTube 刮削共用 NFO 写入入口。

存量维护使用 `electron_server/scripts/refreshMovieNfoFilenameTags.js`，没有调用刮削服务：检查 942 部电影，补充 226 份 NFO，361 条索引标签同步或去重，24 部缺少 NFO 跳过。再次 dry-run 的 NFO 和索引变更均为 0，数据库 `nfo_get_state` 与备份对照无变化。备份位于容器 `/nascabos_data/backups/nfo-tags-refresh-20261015/`。

## 服务端部署

发布清单仅四个文件，与远端原版本逐一比对后部署：

- `src/api/modules/video/home/videoHomeService.js`
- `src/api/modules/video/list/videoListService.js`
- `src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- `src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags.js`

部署包：`/home/ermao/nascabos-metatube-server-2055.tar.gz`，SHA-256 `d15cd5741b3ae27f11dbf665225e4fd1348bc49b619c1cb6a10dabfda5f32805`。原有三个文件备份：容器 `/nascabos_data/backups/metatube-server-2055/original-server.tar`。新增 helper 在旧版中不存在。

未重启容器。两个 API Worker 逐一优雅退出，由主进程自动补齐，PID 从 `78/79` 更新为 `8810/8823`。转码 Worker `8027/8073` 在滚动更新后均保持运行。后续启动的 MetaTube 刮削进程读取新策略，本次未启动刮削。

验证：30 项 Node 回归测试通过；四个部署文件语法检查通过；包哈希两端一致。使用现有有效会话在容器内进行只读 HTTP 检查：电影列表 HTTP 200，30 条视频行均含 `nfo_tags`，11 条含角标标签；首页 HTTP 200，71 条视频行均含 `nfo_tags`，31 条含角标标签。`-UC` helper 返回“破解版本”“中文字幕”。

无暂停提交镜像 `nascabos-custom:metatube-tags-v2055-20261015`，同时更新 `nascabos-custom:latest`。镜像 ID `sha256:fac5a92b82178cddd2b966e84a55ed75e89abaf4d59194df0638cc3181ea7be1`。

## Android APK

版本 `1.2.7 (2055)`，APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2055-signed.apk`。SHA-256：`5795bd1d96476f379d29d7d897b466322d284f147bae619d0c60dc11cc4ce40f`。

沿用本机 debug keystore 内部测试签名。Release 构建、签名、16 KiB 对齐和五个 Flutter 改动文件静态检查均通过。Flutter 构建包含此前已发布的视频转换校验改动及本次视频标签/角标改动。

ADB 设备 `e6fc7cb7` 从 `1.2.7 (2054)` 覆盖安装至 `1.2.7 (2055)`，`adb install -r` 返回 `Success`，设备 `dumpsys package` 确认 `versionCode=2055`、`versionName=1.2.7`，启动 `Status: ok`。使用原保存服务器登录并进入影视库，可访问性树实测最近播放卡片显示“破”及“中 / 破”，最新电影卡片显示“中”；三种角标组合均已验证。本次验证未触发刮削。

镜像归档已完成：`/home/ermao/appdata/myimage/nascabos-custom-metatube-tags-v2055-20261015.tar.gz`，约 2.8 GiB，`gzip -t` 完整性校验通过。SHA-256：`1574c8a3047fbd5f263ad914f6471eb3c3c5eadc42797b42bab42854197cbfe4`，同目录已保存 `.sha256` 文件。宿主 `http://127.0.0.1:18761/health` 返回 HTTP 200。

## 角标外观更新（2056）

2026-10-15 将 Flutter 电影卡片的独立黑色标签合并为紧凑的深色圆角徽标组，“中”使用薄荷绿，“破”使用暖金色，双标签之间增加细分隔线；统一文字尺寸、描边和轻阴影。手机卡片角标移至右上角更多按钮左侧。添加完整标签的无障碍描述。

定向 Dart 静态检查、arm64 Release 构建、APK 签名和 16 KiB 对齐检查通过。`1.2.7 (2056)` 已覆盖安装到 `e6fc7cb7`，设备版本核对正确。登录已保存服务器进入影视库，实机检查单标签与双标签的位置及显示效果。仅更新 Flutter 客户端外观，未更改服务端或触发刮削。

APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2056-signed.apk`。

## 左上角锚点（2057）

2026-10-15 按用户要求将 Flutter 手机海报、桌面海报和推荐卡片的元数据角标统一锚定至左上角，顶部及左侧各留 8 logical pixels。手机收藏标记移至右侧更多按钮下方，桌面收藏按钮移至右上角，避免重叠。定向静态检查、Release 构建、签名及 16 KiB 对齐检查通过。APK `1.2.7 (2057)` 已覆盖安装至 `e6fc7cb7`，产物 `flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2057-signed.apk`。
