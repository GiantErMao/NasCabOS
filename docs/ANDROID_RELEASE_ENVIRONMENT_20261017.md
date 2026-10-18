# 当前 Mac 的 Android 构建环境

配置日期：2026-10-17。设备架构：Intel x86_64。

## 安装路径

| 工具 | 路径 |
| --- | --- |
| Flutter | `/Users/ermao/Env/flutter` |
| Temurin JDK 21 | `/Users/ermao/Env/jdk-21/Contents/Home` |
| Android SDK | `/Users/ermao/Env/android-sdk` |
| Android 命令行工具 | `/Users/ermao/Env/android-sdk/cmdline-tools/latest` |
| 下载缓存 | `/Users/ermao/Env/downloads` |

Android 组件：平台 API 32、33、34、35、36，Build Tools 35.0.0 和 36.0.0，Platform Tools、NDK 28.2.13676358、CMake 3.22.1。多个平台版本用于满足当前 Flutter 插件各自声明的编译 SDK。

JDK 与命令行工具下载自 Adoptium 和 Google，安装前核对 SHA-256。SDK 许可证通过官方工具配置。

## 环境变量

`~/.zprofile` 的 Android 配置区块设置 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`，并将 Java、ADB、命令行工具和 Build Tools 36.0.0 加入 PATH。

原配置备份：`/Users/ermao/.zprofile.backup-20261017-android`。

新终端自动加载；现有终端执行：

```sh
source ~/.zprofile
```

Flutter 已配置上述 JDK 和 SDK 路径。项目的 `android/local.properties` 使用本机 SDK 路径，该文件不纳入版本管理。

本机内存 16 GB；`~/.gradle/gradle.properties` 设置 Gradle 最大堆 3 GiB、最大 Metaspace 1 GiB，供新启动的构建进程使用。

本地 `flutter_client/android/gradle.properties` 启用 `android.useAndroidX=true`。该文件原先只有 Flutter 自动迁移配置，缺少 AndroidX 标志会阻止当前项目的 Release 构建。

## 构建

```sh
cd /Users/ermao/GPT/Dokcer/NasCabOS/flutter_client
flutter doctor -v
flutter build apk --release --no-pub \
  --target-platform android-arm64 --split-per-abi \
  --android-project-arg=force-version-code-ignoring-abi=true \
  --build-name=1.2.7 --build-number=2060 \
  --android-skip-build-dependency-validation
```

版本号在后续构建时继续递增。

## 签名与安装

用户选择先配置构建环境，签名稍后处理。本次不生成正式签名、不创建 `android/key.properties`，也不替换现有证书。

当前 Gradle 配置在缺少发布证书时生成未签名 Release APK，签名前不能安装。后续应沿用现有 App 的证书以支持覆盖升级。

设备检查：`adb devices -l`。本次配置开始时没有连接的 Android 设备。

## 环境验证

- `java -version`：Temurin 21.0.12.1，x86_64。
- 项目 `./gradlew --version`：Gradle 8.12，使用上述 JDK 21。
- `flutter doctor -v`：Android toolchain 检查通过，SDK 36.0.0，所有 Android 许可证已接受。
- 新登录终端中的 Java 和 Android 命令路径验证通过。
- `apksigner`、`aapt2`、CMake 和 NDK Clang 可运行；正式证书尚未配置。

## 修复包构建结果

Release 构建成功，最终 ARM64 包：`flutter_client/build/app/outputs/flutter-apk/app-release-arm64-v2060-unsigned.apk`。

- 包名 `com.nascabos.mobile`，版本 `1.2.7 (2060)`，仅包含 `arm64-v8a`。
- 文件大小 117457900 字节。
- SHA-256：`cbe2ff41098799b527c6410cd4c9885320e5caac46e770d411b5cc2ba2684514`。
- ZIP 完整性与 16 KiB 对齐检查通过；当前未签名。
- 连接设备 `e6fc7cb7` 后，读取到已安装版本 `1.2.7 (2059)`。原证书 SHA-256 为 `152a82f49872800be1c9c6e5554e662689469374b028517565662a8396418da7`，证书名称为 Android Debug。覆盖安装需要该证书对应私钥。
