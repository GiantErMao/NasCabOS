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
