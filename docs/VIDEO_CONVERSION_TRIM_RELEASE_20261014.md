# 视频转换裁剪发布记录

日期：2026-10-14（北京时间）。版本：1.2.7，Android versionCode 2051。

## 发布范围

本次使用隔离的 Flutter 源码构建 Web 与 APK，只加入视频转换改动；工作区已有的文件菜单“复制路径”和相关翻译不纳入本次发布，原工作区文件保持原样。

服务端发布清单：

- `src/api/modules/mediaTool/videoTransCore.js`
- `src/api/modules/mediaTool/videoTransService.js`
- `src/api/modules/mediaTool/videoTransValidation.js`
- `src/msgHandler/videoTrans.js`
- `src/workers/mediaTool/videoTrans/videoTransWorker.js`

## 远端部署

- 主机：`ermao@ddns.ermao.fun:13122`。
- 容器：`nascabos`。
- Web：`/nascabos/web/main`。
- 公网：[NasCabOS](http://ddns.ermao.fun:18761/)。
- 本次发布目录：`/home/ermao/nascabos-video-release-v2051`。
- 服务端备份：`/nascabos/src.backup-video-trim-v2051-20261014`。
- Web 备份：`/nascabos/web/main.backup-video-trim-v2051-20261014`。
- 数据库、配置和用户媒体挂载没有被发布包覆盖。

Web `main.dart.js` 本地与远端 SHA-256 一致：

```text
15d73cb3420e7f4f2da665fad732ad24f4fe509bb99a788102b745ad561f5d1c
```

部署后容器正常运行，公网主页 HTTP 200，`/health` 返回 `success: true`。部署前视频转换运行任务数为 0。

## 业务验证

1. 在隔离源码上生成临时视频，分别测试 H.264/H.265、原分辨率/240p：四种组合均使用远端 VAAPI 硬件编码，裁剪时长、音轨和分辨率正确。
2. 在正式部署源码上创建临时数据库任务，验证空保存目录的替换配置持久化、Worker 准备、硬件裁剪、完整产出校验、源路径提交、处理计数。
3. GIF 与 WebP 真实产出均通过，补足本机缺少 WebP 编码器的验证。
4. 临时任务、视频及该临时源路径的替换恢复记录已清理；本次测试残留任务数为 0。

## APK

- 文件：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2051.apk`。
- 版本：`1.2.7 (2051)`，包名 `com.nascabos.mobile`。
- Flutter 构建目标：`android-arm64`；约 212 MiB。
- 内部测试签名；签名证书与已有 v2050 APK 一致，v2/v3 校验通过，16 KiB 原生库对齐完成。已通过 ADB `install --no-incremental -r` 安装到设备 `e6fc7cb7`，保留原应用数据；设备核对版本为 `1.2.7 (2051)`，`am start -W` 返回 `Status: ok`，当前显示系统权限授权页面，业务界面尚未验证。
- APK SHA-256：

```text
0b61f9214b96d63efc9cdde7aeb2212544702268cafc3b105412685ca38ce1bf
```

构建命令（在隔离源码目录执行）：

```bash
flutter pub get --offline
flutter build web --release --no-pub
flutter build apk --release --no-pub --target-platform android-arm64 \
  --build-name=1.2.7 --build-number=2051 \
  --android-skip-build-dependency-validation
```

## 镜像持久化

镜像：`nascabos-custom:video-trim-v2051-20261014`，同时更新 `nascabos-custom:latest`。

镜像归档：`/home/ermao/appdata/myimage/nascabos-custom-video-trim-v2051-20261014.tar.gz`。归档已通过 `gzip -t` 完整性检查，并生成同名 `.sha256` 校验文件；压缩归档约 2.6 GiB。

归档 SHA-256：

```text
9065ac9c25f84b8823d05512cd353678a0fb63cf7b9eefa90a3ec7f5585279a0
```

镜像 ID：

```text
sha256:a80fce860f2be043063f77317d455fd08e33f4a8427bfbe71ebc4734fbc5cccb
```

当前容器未带 Compose 管理标签。容器由原镜像创建，现有容器重启保留本次代码。以后重建时应使用上述新版本镜像；镜像归档不代替业务数据备份。
