# NasCabOS 部署与 Android 构建手册

本文分别记录本机部署验证和远端发布流程。文中的实测记录注明执行日期、环境与验证边界；远端发布步骤不会因本机部署成功而自动执行。

## 1. 当前环境

| 项目 | 值 |
| --- | --- |
| 本地仓库 | `/Users/bytedance/P4Workspace/NasCabOS` |
| Flutter 项目 | `flutter_client` |
| 服务端项目 | `electron_server` |
| 远端 SSH | `ermao@ddns.ermao.fun:13122` |
| Docker 容器 | `nascabos` |
| Web 容器目录 | `/nascabos/web/main` |
| 服务端源码目录 | `/nascabos/src` |
| 公网地址 | `http://ddns.ermao.fun:18761/` |
| 镜像归档目录 | `~/appdata/myimage` |
| Android 包名 | `com.nascabos.mobile` |
| 测试设备 | `e6fc7cb7` |

不要把 SSH 密码、签名密码或私钥写入仓库。本文默认 SSH 已通过交互输入密码或密钥认证。

### 1.1 本机部署记录（2026-10-12）

本次使用当前工作区的未提交源码，在 macOS arm64 上以仓库配套的 Electron 启动服务端，并将 Electron 配置目录和应用数据库隔离到 `/tmp`：

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/electron_server
userDataFolder=/tmp/NasCabOS-local-deploy-20261012 \
    npm start -- --user-data-dir=/tmp/NasCabOS-local-electron-profile-20261012
```

验证结果：

- Electron 服务端启动成功；HTTP API 监听端口 `6789`，HTTPS 端口 `6799`。
- `curl -i http://127.0.0.1:6789/health` 返回 `HTTP/1.1 200 OK` 和 `{"success":true,"message":"OK"}`。
- 临时数据库和 Electron 配置位于上面的 `/tmp` 路径，不使用现有用户数据目录。停止服务在启动终端按 `Ctrl+C`。
- 系统 Node.js 直接启动不兼容当前 `better-sqlite3` 二进制（模块 ABI 136 与系统 Node ABI 137 不一致）；使用项目的 Electron 启动后正常。
- 本机 Docker Desktop daemon 可用（27.4.0），但没有现存容器、镜像或仓库 Docker Compose/Dockerfile 部署定义，因此本次未做本机容器部署。
- Flutter `3.47.6` 使用 `android-arm64`、版本 `1.2.7`、build number `2042` 构建成功。构建产物默认未签名；使用本机 debug keystore 签出的内部测试包为 `flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2042-signed.apk`，SHA-256：`4c633b9fd387b3a8720a65601c6963dc704e0fd68f53d5af29b17316c165138a`。此签名仅供内部测试，不可用于正式发布。
- 本次 `adb devices -l` 没有列出设备，因此 APK 尚未安装或做设备启动验证。
- 本次只在本机运行服务和生成 APK，没有向远端服务器上传或发布。

重建 APK 的命令：

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/flutter_client
flutter build apk \
    --release \
    --target-platform android-arm64 \
    --build-name=1.2.7 \
    --build-number=2042 \
    --android-skip-build-dependency-validation
```

构建输出 `build/app/outputs/flutter-apk/app-release.apk` 是未签名包。内部测试签名方法见第 10.2 节，安装前需确认已连接授权的 Android 设备，步骤见第 11 节。

## 2. 发布前检查

仓库可能包含多组未提交改动。发布前必须明确本次范围，禁止直接把整个工作区无差别覆盖到远端。

```bash
cd /Users/bytedance/P4Workspace/NasCabOS
git status --short
git diff --check
```

对涉及的 Node.js 文件执行语法检查：

```bash
node --check electron_server/src/path/to/file.js
```

对 Flutter 改动执行定向分析和测试：

```bash
cd flutter_client
flutter pub get
flutter analyze lib/path/to/changed_file.dart
flutter test test/relevant_test.dart
```

高风险操作必须手动确认，包括卸载 App、删除容器、覆盖数据卷和删除镜像归档。

## 3. 构建 Flutter Web

当前验证环境为 Flutter `3.47.6`、Dart `3.13.5`。

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/flutter_client
flutter clean
flutter pub get
flutter build web --release
```

产物位于：

```text
flutter_client/build/web
```

构建后至少检查以下文件：

```bash
test -f build/web/index.html
test -f build/web/main.dart.js
shasum -a 256 build/web/main.dart.js
```

## 4. 部署 Web 到远端 Docker

先在本机打包，避免传输大量零散文件：

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/flutter_client
STAMP=$(date +%Y%m%d-%H%M%S)
tar -C build/web -czf "/tmp/nascabos-web-${STAMP}.tar.gz" .
scp -P 13122 "/tmp/nascabos-web-${STAMP}.tar.gz" \
    ermao@ddns.ermao.fun:/tmp/
```

登录远端：

```bash
ssh -p 13122 ermao@ddns.ermao.fun
```

在远端宿主机执行：

```bash
set -eu

CONTAINER=nascabos
STAMP=替换为本次时间戳
ARCHIVE="/tmp/nascabos-web-${STAMP}.tar.gz"
STAGE="/tmp/nascabos-web-${STAMP}"

rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -xzf "$ARCHIVE" -C "$STAGE"

test -f "$STAGE/index.html"
test -f "$STAGE/main.dart.js"

sudo docker exec "$CONTAINER" \
    sh -lc "cp -a /nascabos/web/main /nascabos/web/main.backup-${STAMP}"
sudo docker cp "$STAGE/." "$CONTAINER:/tmp/web-main-${STAMP}/"
sudo docker exec "$CONTAINER" sh -lc "
    rm -rf /nascabos/web/main &&
    mv /tmp/web-main-${STAMP} /nascabos/web/main
"
sudo docker restart "$CONTAINER"
```

不要直接覆盖旧目录而不清理，否则分包后的旧 JavaScript 文件可能残留。

## 5. 同步服务端代码

只有服务端源码发生变化时才执行本节。推荐维护明确的发布文件清单，不要自动发布所有 dirty 文件。

在本地创建本次清单，例如：

```text
src/api/modules/book/list/bookListService.js
src/api/modules/book/list/bookSearchUtil.js
src/utils/naturalSortUtil.js
language/zh-CN.json
language/en-US.json
```

确认清单后，从 `electron_server` 根目录打包：

```bash
cd /Users/bytedance/P4Workspace/NasCabOS
STAMP=$(date +%Y%m%d-%H%M%S)

tar -C electron_server \
    -czf "/tmp/nascabos-server-${STAMP}.tar.gz" \
    -T /tmp/nascabos-server-files.txt

scp -P 13122 "/tmp/nascabos-server-${STAMP}.tar.gz" \
    ermao@ddns.ermao.fun:/tmp/
```

远端先备份，再解压到 `/nascabos`：

```bash
CONTAINER=nascabos
STAMP=替换为本次时间戳
ARCHIVE="/tmp/nascabos-server-${STAMP}.tar.gz"

sudo docker cp "$ARCHIVE" "$CONTAINER:/tmp/server-update.tar.gz"
sudo docker exec "$CONTAINER" sh -lc "
    cp -a /nascabos/src /nascabos/src.backup-${STAMP} &&
    tar -xzf /tmp/server-update.tar.gz -C /nascabos &&
    rm -f /tmp/server-update.tar.gz
"
sudo docker restart "$CONTAINER"
```

如果清单包含 `language/*`，归档会同步到 `/nascabos/language`。不要覆盖 `node_modules`、数据库、用户配置或挂载卷。

## 6. 部署验证

检查容器状态和最近日志：

```bash
sudo docker ps --filter name=nascabos
sudo docker logs --tail 200 nascabos
curl -I http://127.0.0.1:15006/
curl -I http://ddns.ermao.fun:18761/
```

核对 Web 主文件哈希：

```bash
# 本机
shasum -a 256 flutter_client/build/web/main.dart.js

# 远端
sudo docker exec nascabos sha256sum /nascabos/web/main/main.dart.js
```

两端哈希必须一致。浏览器验证时执行强制刷新；Flutter Web 的 Service Worker 或浏览器缓存可能继续使用旧资源。

接口或数据库逻辑变更还需要验证对应业务路径，不能只以 HTTP 200 作为成功标准。

## 7. 回滚

Web 回滚：

```bash
sudo docker exec nascabos sh -lc "
    rm -rf /nascabos/web/main &&
    mv /nascabos/web/main.backup-时间戳 /nascabos/web/main
"
sudo docker restart nascabos
```

服务端回滚：

```bash
sudo docker exec nascabos sh -lc "
    rm -rf /nascabos/src &&
    mv /nascabos/src.backup-时间戳 /nascabos/src
"
sudo docker restart nascabos
```

回滚前确认备份目录存在。验证完成前不要删除最后一个可用备份。

## 8. 制作和归档自定义镜像

直接修改容器可写层只能跨 `docker restart` 保留；执行容器重建、Compose `down` 后重建或上游镜像更新时会丢失。因此部署验证通过后需要提交自定义镜像。

在远端执行：

```bash
set -eu

STAMP=$(date +%Y%m%d-%H%M%S)
IMAGE="nascabos-custom:${STAMP}"
ARCHIVE="$HOME/appdata/myimage/nascabos-custom-${STAMP}.tar.gz"

mkdir -p "$HOME/appdata/myimage"
sudo docker commit --pause=true nascabos "$IMAGE"
sudo docker tag "$IMAGE" nascabos-custom:latest
sudo docker image inspect "$IMAGE" >/dev/null

sudo docker save "$IMAGE" | gzip -1 > "$ARCHIVE"
gzip -t "$ARCHIVE"
sha256sum "$ARCHIVE" | tee "${ARCHIVE}.sha256"
ls -lh "$ARCHIVE" "${ARCHIVE}.sha256"
```

验证归档无误后再清理 `/tmp` 中的发布包。不要删除 `~/appdata/myimage`。

恢复镜像：

```bash
gzip -dc ~/appdata/myimage/nascabos-custom-时间戳.tar.gz |
    sudo docker load
```

加载后必须把 Compose 或 Portainer 中的镜像名改为对应的 `nascabos-custom:时间戳` 或 `nascabos-custom:latest`，然后重建容器。仅执行 `docker load` 不会自动切换现有容器。

镜像归档不是业务数据备份。SQLite、媒体库和用户配置仍应通过挂载卷单独备份。

## 9. 构建 Android APK

### 9.1 版本策略

`pubspec.yaml` 当前基础版本为 `1.2.7+27`。测试构建通过命令行覆盖：

```bash
--build-name=1.2.7
--build-number=递增整数
```

每次安装新 Release 包都递增 `build-number`。Android 16 对 non-debuggable Release 包可能拒绝降级，即使使用 `adb install -d` 也不可靠。

### 9.2 arm64 Release 构建

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/flutter_client

BUILD_NUMBER=2041

flutter clean
flutter pub get
flutter test
flutter build apk \
    --release \
    --target-platform android-arm64 \
    --build-name=1.2.7 \
    --build-number="$BUILD_NUMBER" \
    --android-skip-build-dependency-validation
```

输出：

```text
build/app/outputs/flutter-apk/app-release.apk
```

`android-arm64` 适用于当前测试设备并减小包体。需要分发到未知 ABI 的设备时，不传 `--target-platform`，或按 ABI 分包并分别验证。

当前版本默认包含 sherpa-onnx 本地 TTS 原生库，因此 arm64 APK 约 212 MB。

## 10. APK 签名

### 10.1 正式发布签名

正式发布应在 `flutter_client/android/key.properties` 配置独立 release keystore。该文件和 keystore 不得提交 Git。

```properties
storeFile=/absolute/path/to/release.jks
storePassword=从安全存储读取
keyAlias=release
keyPassword=从安全存储读取
```

`android/app/build.gradle.kts` 检测到完整配置后会为 Release 构建使用该签名。

### 10.2 内部测试签名

未配置正式 keystore 时，可用本机 debug keystore 对 Release APK 手动签名。该包只用于测试，不得用于商店发布。

```bash
cd /Users/bytedance/P4Workspace/NasCabOS/flutter_client

BUILD_NUMBER=2041
BUILD_TOOLS="$HOME/Library/Android/sdk/build-tools/35.0.0"
OUT=build/app/outputs/flutter-apk

cp "$OUT/app-release.apk" \
    "$OUT/app-release-arm64-v${BUILD_NUMBER}-unsigned.apk"

"$BUILD_TOOLS/zipalign" -f -p 4 \
    "$OUT/app-release-arm64-v${BUILD_NUMBER}-unsigned.apk" \
    "$OUT/app-release-arm64-v${BUILD_NUMBER}-aligned.apk"

"$BUILD_TOOLS/apksigner" sign \
    --ks "$HOME/.android/debug.keystore" \
    --ks-key-alias androiddebugkey \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$OUT/app-release-arm64-v${BUILD_NUMBER}-signed.apk" \
    "$OUT/app-release-arm64-v${BUILD_NUMBER}-aligned.apk"

"$BUILD_TOOLS/apksigner" verify --verbose \
    "$OUT/app-release-arm64-v${BUILD_NUMBER}-signed.apk"

rm -f "$OUT/app-release-arm64-v${BUILD_NUMBER}-aligned.apk"
shasum -a 256 "$OUT/app-release-arm64-v${BUILD_NUMBER}-signed.apk"
```

## 11. ADB 安装和验证

确认设备：

```bash
adb devices -l
```

覆盖安装并保留数据：

```bash
adb -s e6fc7cb7 install --no-incremental -r \
    build/app/outputs/flutter-apk/app-release-arm64-v2041-signed.apk
```

验证版本：

```bash
adb -s e6fc7cb7 shell dumpsys package com.nascabos.mobile |
    rg -m2 'versionCode|versionName'
```

启动并检查崩溃：

```bash
adb -s e6fc7cb7 shell am start \
    -n com.nascabos.mobile/.MainActivity

adb -s e6fc7cb7 logcat -d |
    rg 'FATAL EXCEPTION|AndroidRuntime|com.nascabos.mobile'
```

常见失败：

- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`：已安装包签名不同。只有在用户明确接受应用数据被清除后，才能执行 `adb uninstall com.nascabos.mobile`。
- `INSTALL_FAILED_VERSION_DOWNGRADE`：提高 `--build-number` 后重新构建，不要依赖 `-d`。
- `device unauthorized`：解锁设备并确认 USB 调试授权。
- 安装后黑屏：先检查设备是否进入安全锁屏或 AOD，再判断是否为应用问题。

## 12. 发布完成清单

- [ ] 已确认本次发布文件范围。
- [ ] 定向测试、静态分析和语法检查通过。
- [ ] Web 或 APK 构建成功。
- [ ] 远端部署前已创建容器内备份。
- [ ] 容器重启后日志无启动错误。
- [ ] 公网访问和实际业务路径验证通过。
- [ ] 本地与远端 Web 主文件哈希一致。
- [ ] 自定义镜像已提交到带时间戳 tag。
- [ ] 镜像已归档到 `~/appdata/myimage`。
- [ ] gzip 完整性和 SHA-256 校验通过。
- [ ] Compose/Portainer 已记录应使用的自定义镜像。
- [ ] APK 签名、版本号、安装和启动验证通过。

本清单用于远端正式发布。若只完成本机部署验证，应只勾选已实际完成的本机步骤，并在上面的部署记录中说明设备安装、远端发布等未完成项。

## 13. 视频裁剪发布（2026-10-14）

本次已完成远端 Web/服务端部署、硬件裁剪及真实任务验证，并构建 APK `1.2.7 (2051)`。本次仅发布视频转换范围，未包含工作区其他未完成改动。

- 线上实际映射为 `6789/tcp -> 18761`，本机健康检查应使用 `http://127.0.0.1:18761/health`。
- Docker 为 Snap 安装，`docker cp` 不能读取宿主普通 `/tmp` 下的上传文件；应先将发布包放到 `/home/ermao/nascabos-video-release-v2051` 这样的用户目录。
- APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2051.apk`，约 212 MiB，沿用已有内部测试签名；已覆盖安装到 `e6fc7cb7` 并核对版本，启动后显示系统权限授权页。
- 新镜像标签、备份位置、归档校验及 APK 哈希见 [视频裁剪发布记录](VIDEO_CONVERSION_TRIM_RELEASE_20261014.md)。

## 14. 替换源文件保存热修复（2052）

2026-10-14 修复 Flutter 控制器的旧保存目录必填检查。4 项控制器回归测试通过，Web 已热切换，APK `1.2.7 (2052)` 已覆盖安装到 ADB 设备 `e6fc7cb7`。新镜像和归档已完成，详情见 [2052 热修复记录](VIDEO_CONVERSION_TRIM_HOTFIX_2052.md)。

## 15. 硬件转码链路优化（2026-10-14）

视频转换 Worker 已加入禁用隐式自动缩放、硬件分辨率滤镜和三级回退。22 项 Node 测试中 21 通过、1 项本机 WebP 编码器缺失跳过；远端全硬件、问题片段及人为失败后的混合编码验证通过。仅热更新服务端两个文件，不重启容器，新任务加载优化。APK 仍为 2052，无需重建。

镜像 `nascabos-custom:video-trim-hw-20261014` 已无暂停提交并归档校验，详见 [硬件优化记录](VIDEO_CONVERSION_HARDWARE_OPTIMIZATION_20261014.md)。

## 16. 可变分辨率保护（2026-10-14）

后续将无条件关闭硬件 autoscale 改为固定画布＋GPU 帧条件关闭。CPU 帧编码仍保留默认 autoscale；新增可变分辨率/宽高比和竖屏旋转测试。26 项本地测试中 25 通过、1 项 WebP 编码器缺失跳过。远端逐帧尺寸检查通过，已无重启热更新、无暂停提交并归档 `nascabos-custom:video-trim-fixed-20261014`，APK 仍为 2052。

详见 [固定画布修复记录](VIDEO_CONVERSION_FIXED_GEOMETRY_20261014.md)。

## 17. 保留软件帧后端的硬件解码（2026-10-14）

VideoToolbox / D3D11VA 新增硬件解码、软件缩放、硬件编码路径。用户授权后，远端 Worker/helper 已备份并热更新，10 项路径测试及真实 VAAPI 回归验证通过，内外健康检查正常。容器未重启，新 Worker 加载更新；APK 仍为 2052。

新镜像标签 `nascabos-custom:video-decode-20261014`，旧版本保留，详情见 [硬件解码保留记录](VIDEO_CONVERSION_SOFTWARE_FRAME_HW_DECODE_20261014.md)。

## 18. 视频转换校验方式发布（2026-10-15）

发布内容为视频转换任务的“校验方式”：默认快速校验，支持严格校验。Flutter Web、Android APK 和服务端均已部署；Harmony 源码虽同步实现，但本次未构建或发布 Harmony 客户端。

- 远端部署目录：`/home/ermao/nascabos-video-validation-20261015/`；容器 `nascabos` 保持运行，未重启。发布前确认没有视频转换 Worker 正在运行。服务端新文件供新启动的 Worker 加载。
- 服务端文件已分别备份为 `.backup-validation-20261015-v2053` 后缀：`/nascabos/src/api/modules/mediaTool/videoTransCore.js`、`/nascabos/src/workers/mediaTool/videoTrans/videoTransWorker.js`。Web 备份位于 `/nascabos/web/main.backup-validation-20261015-v2053`。
- Web `main.dart.js` 本地与远端 SHA-256 一致：`ab48123fe744f7a35f57dafd61395e11d629acde0a3bfb7c0923d3b9daf94cd9`。首页及 `/health` 均返回 HTTP 200；部署后的服务端文件语法检查通过，默认及严格模式配置归一化分别返回 `fast`、`strict`。
- 镜像标签：`nascabos-custom:video-validation-v2053-20261015`，同时更新了 `nascabos-custom:latest`。镜像 ID：`sha256:93940df5b789f071f41bafeb0923271ec40d14527ff9f751dfdbaed9b38f924a`。归档位于 `/home/ermao/appdata/myimage/nascabos-custom-video-validation-v2053-20261015.tar.gz`，约 2.8 GiB；SHA-256：`e8d46e3d4a52af562796ccc8f02a652a9a65ba914f76eed4d4db6b7fc99f0dcc`，归档生成期间 gzip 完整性检查通过。
- Android APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2054-signed.apk`，版本 `1.2.7 (2054)`，SHA-256：`0bd07eae1473bb848d7ca41f66e83e113ebc0a3e67ae1c2a23ed726e01e4f80c`。使用本机 debug keystore 内部测试签名，不可用于商店正式发布；签名和 APK 16 KiB 对齐检查通过。
- APK 已覆盖安装到 `e6fc7cb7`，设备原版本为 `1.2.7 (2053)`；安装后确认版本为 `1.2.7 (2054)`，Activity 启动返回 `Status: ok`。首次启动停留在系统权限授权页，尚未验证客户端业务交互。
- Flutter Web 与 APK 构建成功。Web 构建打印了现有依赖的 Wasm dry-run 兼容性提示，但标准 dart2js Release 构建通过。未运行视频转换端到端媒体任务验证。

## 19. MetaTube NFO 标签和电影角标（2026-10-15）

服务端文件名标签策略与电影列表/首页 `nfo_tags` 字段已部署，两个 API Worker 滚动更新，保留两项正在运行的视频转换任务。Android `1.2.7 (2055)` 已覆盖安装至 ADB 设备 `e6fc7cb7`，实测“中”“破”“中 / 破”三种角标组合。未发布 Web、Harmony 或 TV 客户端，未触发刮削。

发布清单、存量 NFO 刷新结果、备份及镜像信息见 [MetaTube 标签发布记录](METATUBE_NFO_TAGS_RELEASE_2055.md)。

## 20. 视频校验与 MetaTube 标签更新（2026-10-15，2058）

按当前工作区构建并部署视频校验方式、MetaTube 文件名标签和影视卡片角标更新。服务端与 Flutter Web 已部署，Android Release APK 已覆盖安装到 ADB 设备 `e6fc7cb7`。本次没有重建自定义 Docker 镜像，也没有发布 Harmony、Android TV 或 Apple TV 客户端。

- 服务端发布包：`/home/ermao/nascabos-server-video-validation-metatube-v2058-20261015.tar.gz`，SHA-256：`913af3fd024c62a5dff168ce4d57b95af2487b55495245550a9d4e8d75a2d8f4`。部署 6 个定向文件：视频转换配置与 Worker、首页和影视列表 API、NFO runner 及 MetaTube 文件名标签 helper。旧文件备份在容器 `/nascabos_data/backups/server-video-validation-metatube-v2058-20261015/`。
- 服务端文件在容器内逐个通过 `node --check`。两个 Express API Worker 依次优雅退出并自动补位；每次切换后的 `/health` 均返回 HTTP 200。Docker 容器没有重启，未执行 NFO 刮削或存量刷新。
- Flutter Web Release 构建成功。构建输出包含既有依赖的 Wasm dry-run 兼容性提示，标准 Web 构建通过。归档 SHA-256：`8f76325250ce32905250347bc3d605906fbe090f847546349e7253d9283dcf84`；本地和远端 `main.dart.js` SHA-256 均为 `735716c1b52b9b6c9d20a35f5e94cac79cf0a372706ddb754a3283aecd4f5a91`。首页返回 HTTP 200；旧 Web 目录备份在 `/nascabos/web/main.backup-v2058-20261015`。
- Android arm64 APK：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2058-signed.apk`，版本 `1.2.7 (2058)`，SHA-256：`b7a39395d31f1b38074ec4553448d6929e53d56183c706e2ecfe68e3e3cd3e30`。使用本机 debug keystore 签名，仅供内部测试，不可用于商店正式发布；签名验证和 16 KiB 对齐验证通过。
- ADB 设备原版本为 `1.2.7 (2057)`。APK 覆盖安装成功，设备确认 `versionCode=2058`、`versionName=1.2.7`，Activity 已启动；安装后检查的最近日志没有发现崩溃记录。
- 本次完成构建、语法及部署健康检查；未运行视频转换媒体端到端任务，也未做影视卡片 UI 的逐项实机验收。

## 20. 文件名标签合入现有类型筛选（2026-10-15）

“中文字幕”“破解版本”已同时写入 NFO 类型、`nfo_genres` 和类型检索表，保留原角标标签；226 份 NFO 更新，类型筛选分别命中 221、11 部，双条件命中 6 部，刮削状态未变。无需更新客户端，详情页标签及类型筛选直接复用现有能力。详见 [标签类型合并记录](METATUBE_GENRE_MERGE_20261015.md)。

## 手机详情类型标签点击修复（2026-10-15，2059）

APK 详情页的类型/地区链接此前调用桌面 `VideoMainController` 浮层，而手机端未注册该控制器，点击直接返回。改为手机独立筛选列表 `AppVideoMetadataVideosPage`，复用分页、筛选、搜索及返回能力，保留原详情页。地区链接一并修复，桌面浮层逻辑不变。

三项 Widget 回归测试通过：未注册桌面控制器时，点击“中文字幕”“破解版本”“日本”均进入筛选页，发出正确类型/地区参数，并能返回详情；相关源码及测试定向静态检查通过。

APK `1.2.7 (2059)` 已签名并通过 16 KiB 对齐检查，覆盖安装至 `e6fc7cb7`，版本核对正确。实机点击详情“中文字幕”打开“风格-中文字幕”列表，UI 树显示匹配电影，返回原详情正常。未触发刮削或修改服务端。

产物：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2059-signed.apk`，SHA-256：`1fe47c62ed67202e995a128e9ee0fb5ee7b66e0ffe3ec11d6135acd20994f7c0`，沿用已有内部测试签名。
