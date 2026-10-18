# Pico 验证包报告（Flutter 版横屏）

日期：2026-10-18

> **状态：验证通过，已出正式 release 包。** 见文末「五、release 包」。
> 验证阶段的并存包 `com.nascabos.mobile.pico` 已完成使命，正式包回归官方包名 `com.nascabos.mobile`。

验证包（历史）：`com.nascabos.mobile.pico`（与正式版 `com.nascabos.mobile` **并存**，互不影响）
APK：`/Users/ermao/GPT/Dokcer/nascabos-mobile-pico-verify.apk`

---

## 一、结论：竖屏就是 Manifest 一行，放开后 Pico 直接给大屏

Pico 是按 **App 声明的屏幕方向** 来创建虚拟显示（`NS_APP[包名]`）的。实测三个包：

| 包名 | Manifest 方向 | Pico 虚拟显示 | 说明 |
|---|---|---|---|
| `com.nascabos.mobile` | `portrait` | **506 × 900** | 原版 → 竖屏小窗 |
| `com.nascabos.mobile.pico` | `landscape` | **1600 × 900** | **验证包 → 大屏** |
| `com.nascabos.tv` | 未锁（横屏布局） | **1600 × 900** | TV 版 → 大屏 |

密度均为 200dpi。**只改一行方向声明，面板从 506×900 变成 1600×900，与 TV 版一致。**

推论：`MediaQuery.of(context).size.width = 1600 ≥ desktopBreakpoint(600)`
→ `isDesktopLayout == true`；配合 `isPhone` 修正后 → `isPhone == false`。
**已有的桌面（大屏）排版会自动生效**。

---

## 二、验证包做了哪些改动（4 处）

| # | 文件 | 改动 | 性质 |
|---|---|---|---|
| 1 | `android/app/src/main/AndroidManifest.xml` | `android:screenOrientation="portrait"` → `"landscape"` | **核心**，Pico 据此分配大屏显示 |
| 2 | `lib/main.dart` | 方向锁增加 `&& !kPicoVerificationBuild` 条件 | 验证用开关 |
| 3 | `lib/utils/device_utils.dart` | 新增 `kPicoVerificationBuild` 常量；新增 `isLargeScreenAndroid`；`isPhone()` 改为**纯宽度判定** | 核心修复 |
| 4 | `android/app/build.gradle.kts` | 临时 `applicationIdSuffix = ".pico"` | **临时**，仅为了并存 |

### 为什么必须改 `isPhone()`

原实现：

```dart
static bool isPhone(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  return !isDesktopOrWeb && (width < phoneBreakpoint || isMobile);
}
```

`isMobile` 是**按平台**判定（Android‖iOS），在 Android 上恒为 true →
**1600dp 宽的 Pico 面板上 `isPhone` 仍为 true**，与按宽度判定的 `isDesktopLayout == true` 自相矛盾。
改为纯宽度判定后两者一致：

```dart
static bool isPhone(BuildContext context) {
  if (isDesktopOrWeb) return false;
  return MediaQuery.of(context).size.width < phoneBreakpoint;
}
```

受影响调用点：`isPhone` 42 处、`isDesktopLayout` 11 处。

---

## 三、已验证 / 未验证

### ✅ 已验证（客观数据）

- 安装成功，与正式版并存
- 虚拟显示 **1600 × 900 @ 200dpi**（原 506 × 900）
- 应用正常启动并 resume：`com.nascabos.mobile.pico/com.nascabos.mobile.MainActivity`
- 渲染正常：日志 `Using the Impeller rendering backend (Vulkan)`；
  SurfaceFlinger 中可见 `SurfaceView[com.nascabos.mobile.pico/...]` 图层
- **无崩溃、无 FATAL、无 Flutter 未捕获异常**

### ⚠️ 未能验证（需要你戴头显看）

虚拟显示带 `FLAG_SECURE | FLAG_PRIVATE`，`screencap` / `uiautomator dump` 都被拒绝；
Flutter 3.47 又不再注册 `ext.flutter.screenshot`（`flutter screenshot --type=skia` 会挂住）。
所以**画面只能由你在头显里确认**：

1. 首页/各模块列表是否按大屏铺开（列数、间距）
2. 详情页是否走两栏
3. **播放器横屏全屏是否正常**（这是本路线唯一未证实的高风险项）
4. 输入框能否唤起 Pico 输入法（大屏布局下）
5. 手柄射线点击小目标的命中率（可能需要放大点击区）

---

## 四、怎么跑

```sh
adb install -r /Users/ermao/GPT/Dokcer/nascabos-mobile-pico-verify.apk
# 在 Pico 的应用列表里找 "NasCabOS"（带 .pico 的那个）
```

重装后如需重建：

```sh
cd flutter_client
JAVA_HOME=/Users/ermao/Env/jdk-21/Contents/Home ANDROID_HOME=/Users/ermao/Env/android-sdk \
  flutter build apk --debug --target-platform android-arm64 \
  --android-skip-build-dependency-validation
```

> 注意：本机 Gradle 8.12 低于 Flutter 3.47 要求的最低 8.14，
> 所以必须带 `--android-skip-build-dependency-validation`（未改仓库里的 wrapper）。

---

## 五、验证通过后要做的收尾（现在先别做）

1. 去掉 `applicationIdSuffix = ".pico"`（改回单一包名）
2. 把 `kPicoVerificationBuild` 换成**运行时判定**（大屏 Android / VR 一体机），
   不能留编译期常量
3. Manifest 的方向锁应改为在 Dart 侧按设备形态决定，而不是写死 `landscape`
4. `isPhone` 改宽度判定后，需要回归**平板**（此前平板也误判为手机）
5. VR 观看距离适配：点击目标放大、字号再提一档（可接上目前 0 引用的 `DimensUtil`）

---

## 六、如果验证结果是"惨不忍睹"

回退到备选路线 B（改 TV 版），方案见 `PICO_ADAPTATION_PLAN_20261018.md`：
TextureView 改造 + 应用内自绘键盘 + Manifest + dimens。

---

## 七、第二轮（2026-10-18 晚）：方向回竖屏修复 + 播放器选择

### 7.1 用户实测反馈

- ✅ 桌面（大屏）排版在 1600×900 下生效
- ✅ 播放器横屏全屏正常
- ❌ **从播放器返回后，整个 App 变成竖屏**
- ➕ 新需求：希望能选择「App 内播放器」或「Pico 自带播放器」

### 7.2 返回后变竖屏的根因

`lib/modules/video_player/controllers/parts/window.dart`：

```dart
Future<void> restoreOrientation() async {
  ...
  if (DeviceUtils.isMobile) {              // ← 按「平台」判定，Android 恒为 true
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
}
```

该方法在 `lifecycle.dart:164`（播放器 dispose）被调用，于是**每次退出播放器都把整个 App 的方向改成竖屏**。
Pico 依据 Manifest 声明的方向分配虚拟显示，竖屏 → 面板从 1600×900 缩回 506×900。

这不是"退出全屏"，是改了 App 的基准方向。修复：

| 位置 | 改动 |
| --- | --- |
| `window.dart` | 新增 `_landscapeBaseline`（= `DeviceUtils.isLargeScreenAndroid`）与 `_restoreBaselineOrientation()`；`restoreOrientation()` 回到**基准方向**而非写死竖屏；大屏上 `toggleOrientation()` 只切播放器内 UI 态，不动系统方向 |
| `main.dart` | 大屏 Android 显式锁 `landscapeLeft/Right`（原为"不锁竖屏"，不够稳） |

验证：`adb shell dumpsys activity` → `requestedOrientation=SCREEN_ORIENTATION_USER_LANDSCAPE`。

### 7.3 播放器选择（新功能）

实测 Pico 上 `video/mp4` 的默认处理器是 **`com.picovr.wing.videoplayer/.UnityActivity`**（Pico 自带播放器，`isDefault=true`）：

```
$ adb shell cmd package resolve-activity --brief -a android.intent.action.VIEW \
    -d https://example.com/a.mp4 -t video/mp4
com.picovr.wing.videoplayer/.UnityActivity
```

新增三选一（设置 → 播放方式）：

| 选项 | 行为 |
| --- | --- |
| 应用内置播放器 | 原逻辑，FVP / Media3，保留字幕、转码、连播、进度记忆 |
| **Pico 自带播放器** | 直接 `setPackage(com.picovr.wing.videoplayer)` 启动 —— VR 下系统选择器可能不可交互，能定位包名时优先直启 |
| 系统播放器 | `ACTION_VIEW` + 选择器，可自行设为默认 |

改动文件：

| 文件 | 说明 |
| --- | --- |
| `lib/modules/video_player/playback/external_player.dart`（新增） | `VideoPlayerMode` 枚举（inApp / vrPlayer / systemChooser）、原画直链构建、MethodChannel 调用、进程内缓存 |
| `android/.../ExternalPlayerMethodHandler.kt`（新增） | ACTION_VIEW + mime + title + 断点位置 extras；`vr` 目标自动探测已知 VR 播放器包名；失败回退选择器 |
| `MainActivity.kt` | 注册 `com.nascabos/external_player` channel |
| `app_routes.dart` | `toVideoPlayer()` 统一分流（所有播放入口都走这里） |
| `settings_view.dart` | 「播放方式」设置项 + 三选对话框（未装 VR 播放器时不显示该选项） |
| 13 个语言文件 | 新增 `settings_player_mode*` 5 个 key（非中英语言暂用英文占位，符合现有惯例） |

限制：外部播放器走**原画直链**，不经过应用内转码 / 字幕渲染，播放进度也不会回写 NasCab。

---

## 八、第三轮：详情页「类型 / 地区」标签点了没反应

### 根因

桌面详情页 `video_detail_top_section.dart` 的 `_MetaLine`：

```dart
if (!Get.isRegistered<VideoMainController>()) return;   // ← 静默失效，没有任何反馈
Get.find<VideoMainController>().openFilterOverlay(...);
```

筛选列表在桌面布局下是挂在 `VideoMainView` 里的**浮层**（`_VideoFilterListOverlay`），
而 `VideoMainController` 只在 `VideoMainView` 里 `init` —— 从**文件模块 / 收藏**等入口
直接打开详情时根本没有这个宿主，于是点击什么都不会发生。

手机布局（`app_video_detail_top_section.dart`）走的是 `Get.to(AppVideoMetadataVideosPage)`
独立页面，不依赖 controller，所以**这个 bug 只在走桌面布局时才暴露**——
Pico 之前是手机布局，改成大屏后第一次踩到。

### 修复

| 文件 | 改动 |
| --- | --- |
| `base/video_utils/video_metadata_filter_opener.dart`（新增） | 统一入口：有 `VideoMainController` 走浮层；没有则退化为独立筛选页（genre/region/actor/director 各有对应页面） |
| `video_detail_top_section.dart` | 改用统一入口；类型/地区从「小号下划线文本」改为**胶囊 chip**（把点击热区做大，VR 射线更易命中） |
| `video_detail_people_section.dart` | 演员/导演同样改用统一入口；判定从 `isMobile`（按平台，Android 恒 true）改为 `isPhone(context)`（按宽度），与详情页其余部分一致 |

数据链路本来就是通的（`VideoListController.initialGenres` → `video_list_api_service` 的 `genres` 参数），
所以只需要修触发环节。

### 如何确认根因（若仍不生效）

debug 包里加了诊断日志，点标签后抓：

```sh
adb logcat -d | grep MetaFilter
# [MetaFilter] kind=genre value="动作" mediaType="movie" overlayHost=false
```

`overlayHost=false` 说明走了独立页回退分支（从文件模块等入口进详情时的正常情况）。

---

## 五、release 包（2026-10-18 出包）

验证通过后确认：**Pico 需要独立构建**。原因是 Pico 按 App 声明的方向分配虚拟显示尺寸，
一个包没法同时满足「Pico 横屏 1600×900」和「手机竖屏」，所以本 release 定位为 **Pico 专用横屏版**。

### 产物

| 项 | 值 |
| --- | --- |
| 包名 | `com.nascabos.mobile`（官方包名，已移除验证期的 `.pico` 后缀） |
| 版本 | versionName `1.2.7` / versionCode `2061`（原正式包为 2060） |
| 签名 | `nascabos-release.jks`，CN=NasCabOS，SHA-256 `6ef8c845…be2d`（v1/v2/v3） |
| APK | `/Users/ermao/GPT/Dokcer/nascabos-mobile-pico-release-v2061.apk` |
| 构建源 | `flutter_client/build/app/outputs/flutter-apk/app-release-v2061-signed.apk` |

设备上已实测：安装成功、`NS_APP[com.nascabos.mobile]` → **1600 × 900**、正常 resume、无崩溃。

### 构建命令

```sh
cd flutter_client
JAVA_HOME=/Users/ermao/Env/jdk-21/Contents/Home ANDROID_HOME=/Users/ermao/Env/android-sdk \
  /Users/ermao/Env/flutter/bin/flutter build apk --release \
  --target-platform android-arm64 --build-number=2061 \
  --android-skip-build-dependency-validation
```

两个环境坑（每次都会遇到）：

- 本机 Gradle 8.12 < Flutter 3.47 要求的 8.14，**必须**带 `--android-skip-build-dependency-validation`
  （不要去改仓库里的 wrapper）。
- 工程**没有** `android/key.properties`，且它不在 `.gitignore` 里。为免密钥/密码进版本库，
  沿用「先出 unsigned 再手动签」的老办法：

```sh
BT=/Users/ermao/Env/android-sdk/build-tools/36.0.0
WORK=$(mktemp -d)
chmod 700 "$WORK"
PW=$(tr -d '\n\r' < /Users/ermao/Env/android-signing/nascabos-20261017/keystore-password.txt)
printf '%s\n%s\n' "$PW" "$PW" > "$WORK/password.txt"
unset PW
chmod 600 "$WORK/password.txt"
cd flutter_client/build/app/outputs/flutter-apk
$BT/zipalign -p -f 4 app-release.apk app-release-v2061-aligned.apk
$BT/apksigner sign --ks /Users/ermao/Env/android-signing/nascabos-20261017/nascabos-release.jks \
  --ks-key-alias nascabos-release --ks-pass file:"$WORK/password.txt" --key-pass file:"$WORK/password.txt" \
  --min-sdk-version 24 --out app-release-v2061-signed.apk app-release-v2061-aligned.apk
rm -rf "$WORK"
```

### 本轮相对验证包的三处收尾改动

1. 删除 `kPicoVerificationBuild` 编译期开关，改为纯运行时判定 `DeviceUtils.isLargeScreenAndroid`。
   注意其健壮性处理：视图尚未就绪时 `_webLogicalWidth()` 返回 0，此时**不能**判为小屏，
   否则会把 Pico 误锁竖屏（面板缩回 506×900）。
2. `build.gradle.kts` 移除 `applicationIdSuffix = ".pico"`，回到官方包名。
3. Manifest 保持 `android:screenOrientation="landscape"` —— 这是 Pico 拿到 1600×900 面板的必要条件，不要改。

### TV 版改动已全部回退

`tv_android/` 下 29 个文件的改动（`+484/−25`）与 4 个新增文件（`TvImeHelper.kt`、
`VideoTitleUtils.kt`、两个 drawable）已全部撤销，`git status tv_android` 为空；
`docs/ANDROID_TV_SYNC_*` 三份文档一并删除。

如需找回，补丁与文件备份在 `/tmp/nascabos_tv_revert_backup/`（临时目录，重启会丢，需要请先转存）。
