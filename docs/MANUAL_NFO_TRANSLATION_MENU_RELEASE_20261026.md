# 手动 NFO 翻译与更多菜单发布（2026-10-26）

## 范围

服务端以提交 `e99afc5d7102e8fdb15b334669a7e884267f4fa5` 为准，支持手动翻译电影 NFO 的标题、剧情及类型，并保留原始标题、同步元数据和检索索引。Flutter 手机端和桌面端的翻译入口由主操作区移至“…”更多菜单，仍仅对管理员及电影类条目展示，翻译处理逻辑不变。

本次只发布服务端和 Android APK，没有发布 Flutter Web、Harmony 或 TV 客户端，也没有启动真实翻译、刮削或存量 NFO 更新。

## 远端服务端

目标沿用已授权服务器 `ermao@ddns.ermao.fun:13122`，容器 `nascabos`。

发布核查时，下列八个文件远端已经与当前本地提交逐个 SHA-256 完全一致，因此没有重复覆盖或重启服务：

- `src/api/modules/video/detail/detailController.js`
- `src/api/modules/video/detail/movieNfoTranslation.js`
- `src/api/modules/video/detail/movieNfoTranslationService.js`
- `src/api/modules/video/videoRouter.js`
- `src/workers/videoIndex/nfoFetchWorker/metadataTranslateClient.js`
- `src/workers/videoIndex/nfoFetchWorker/metatubeFilenameTags.js`
- `src/workers/videoIndex/nfoFetchWorker/nfoFetchRunner.js`
- `src/workers/videoIndex/videoIndexIndexUtil.js`

以上源码备份到容器用户数据卷 `/nascabos_data/backups/manual-nfo-translation-20261026/server-source.tar`。前一笔提交中的两项 Python 图像维护脚本不属于运行时依赖，本次未执行。

服务端回归测试：`movieNfoTranslation.test.js`、`metatubeFilenameTags.test.js`、`nfoMetadataSource.test.js` 共 30 项通过，包含翻译跳过、失败处理和 HTTP 429 重试。

远端 `/health` 返回 HTTP 200；不携带凭据调用 `POST /api/video/detail/nfo/translate` 返回 HTTP 401，确认路由已加载且认证保护生效，没有触发翻译请求或 NFO 写入。没有读取会话凭据。

此前 `nascabos-custom:latest` 仍为 2026-10-15 快照，本次保存当前已生效代码为自定义镜像，避免后续容器重建丢失这些更新。

远端实际 Node `v22.22.2` 的 8 个语法检查通过。另在内存中执行已中文 NFO 的跳过测试，通过且外部翻译请求数、元数据写入数均为 0。

## 镜像备份

已无暂停保存镜像 `nascabos-custom:manual-nfo-translation-20261026`，并更新 `nascabos-custom:latest`。镜像 ID：`sha256:909d877342794153b26f92f5c28ae701448db41ea50ee7e07c7c833b0b3dbdb7`。

归档：`/home/ermao/appdata/myimage/nascabos-custom-manual-nfo-translation-20261026.tar.gz`，约 2.7 GiB；`gzip -t` 完整性检查通过。SHA-256：`71aa44eef8264980f27bc9c65376382d3e5ac27151d11a5831ae28ad0933d9c2`，同目录保存 `.sha256` 文件。公网 `http://ddns.ermao.fun:18761/health` 也返回 HTTP 200。

## Android APK

版本 `1.2.7 (2068)`，regular / android-arm64 Release。现有设备 `e6fc7cb7` 原版本为 `1.2.7 (2067)`，签名证书与本机内部测试 keystore 一致，本次保留数据覆盖安装。

初次构建在依赖仓库网络握手处等待，后使用缓存依赖离线构建成功。两个菜单修改文件定向 Flutter 静态检查通过。APK v2/v3 签名验证、16 KiB 对齐检查通过，ADB 安装成功，设备复核 `versionCode=2068`、`versionName=1.2.7`，Activity 启动 `Status: ok`。

产物：`flutter_client/build/app/outputs/flutter-apk/app-regular-release-arm64-v2068-signed.apk`。SHA-256：`923982cfc06b554d63158a076828a4df568d2b95857602a0a3b7d4b1572b7f91`。

实机电影操作二级菜单 UI 树已确认出现“下载 / 文件浏览 / 搜索影音信息 / 翻译 / 自动刮削 / 清理刮削信息 / 扫描变动”。没有点击翻译或刮削条目。主操作区移除翻译入口通过源码和静态检查确认；菜单关闭后设备被切至系统桌面，没有继续抢占用户操作。
