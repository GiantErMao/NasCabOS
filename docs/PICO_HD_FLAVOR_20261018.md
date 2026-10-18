# HD / regular 双变体构建（Pico 大屏版 + 手机版）

日期：2026-10-18

## 背景与目标

需求：**不单独维护一个「Pico 版」，而是维护一个「HD 版」**——同一套 Dart 代码，
构建出两种产物：

| 变体 | 目标设备 | Manifest `screenOrientation` | Pico 虚拟显示 |
|------|----------|------------------------------|---------------|
| `hd` | Pico VR 一体机 / Pad 等高分设备 | `landscape` | 1600×900 大屏 |
| `regular` | 普通手机 | `portrait` | — |

关键约束：**Pico 在 App 启动时按 Manifest 声明的 `android:screenOrientation`
分配虚拟显示尺寸**（landscape → 1600×900 大屏；portrait → 506×900 小窗），
这个值必须在 Manifest 里定死，运行时 `SystemChrome.setPreferredOrientations` 改不了。

## 实现方式（标准 AGP，不动源码）

1. `android/app/build.gradle.kts`：`flavorDimensions += "mode"` +
   `productFlavors { regular / hd }`。
2. `android/app/src/main/AndroidManifest.xml`：**不声明** `screenOrientation`。
3. `android/app/src/hd/AndroidManifest.xml`：`MainActivity` → `landscape`。
4. `android/app/src/regular/AndroidManifest.xml`：`MainActivity` → `portrait`。

即 flavor 专属源集 Manifest 覆盖（AGP manifest merger 的标准能力）。

运行时排版仍由 `DeviceUtils.isLargeScreenAndroid`（可视宽度 ≥ 600，
视图未就绪 width=0 时也判为大屏）决定，`main.dart` 据此锁横/竖屏。

## 构建与签名

```sh
cd NasCabOS/flutter_client

# 覆盖安装时新包 versionCode 必须大于已装包（Pico 上已装 2061）
BUILD_NUMBER=2062 ./build_flavor.sh hd
BUILD_NUMBER=2062 ./build_flavor.sh regular

./sign_flavor.sh hd        # -> ../../nascabos-mobile-hd-release-v2062.apk
./sign_flavor.sh regular   # -> ../../nascabos-mobile-regular-release-v2062.apk
```

- 工程**没有** `android/key.properties`，也不在 `.gitignore` 里 → 不把密钥写进仓库，
  走「先出 unsigned，再手动 zipalign + apksigner」。
- 钥匙必须是 `/Users/ermao/Env/android-signing/nascabos-20261017`（SHA-256
  `6EF8:C845:...:BE2D`），否则无法覆盖升级已安装的正式包。
- 本机 Gradle 8.12 < Flutter 要求的 8.14，构建必须带
  `--android-skip-build-dependency-validation`。

## 验证方式（务必用正确的枚举表）

```sh
BT=/Users/ermao/Env/android-sdk/build-tools/36.0.0
"$BT/aapt" dump xmltree build/app/outputs/flutter-apk/app-hd-release.apk AndroidManifest.xml \
  | awk '/com.nascabos.mobile.MainActivity/{f=1} f&&/screenOrientation/{print;exit}'
```

`android:screenOrientation` 的枚举**从 -1 开始**：

| 值 | 含义 |
|----|------|
| -1 (0xffffffff) | unspecified |
| **0** | **landscape** |
| **1** | **portrait** |
| 4 | sensor |
| 5 | nosensor |
| 6 | sensorLandscape |

所以 hd 期望 `=0`、regular 期望 `=1`。
（本次曾因记错成「0=unspecified,1=landscape」而误判两个变体都失败，
进而白折腾了 manifestPlaceholders / buildSrc / artifact transform 三条路。）

## 踩坑记录

- Gradle 产物目录是 **`flutter_client/build/app/`**（Flutter 重定向了 buildDir），
  不是 `android/app/build/`。
- `flutter build apk` 会把 `build/app/outputs/apk/<flavor>/release/*.apk`
  拷到 `build/app/outputs/flutter-apk/`，**拷贝会刷新 mtime**，
  所以「APK 时间戳新」不代表重新构建过——要用 sha1 或 manifest 内容判断。
- Kotlin DSL：`applicationVariants.all { manifestPlaceholders[...] }` 不可用
  （新版 AGP 的 `ApplicationVariant` 没有该属性）；脚本内定义的任务类 Gradle 会以
  "non-static inner class" 报错（需放 `buildSrc`）。本方案已不需要这些。
