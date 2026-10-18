# NasCabOS TV 版 → Pico（VR）改造方案

日期：2026-10-18
> ⚠️ **本文档已降级为「备选路线 B」。**
> 经进一步取证，推荐走**路线 A：改造非 TV 版（Flutter）为横屏/大屏布局**，
> 决策依据见 [`PICO_ROUTE_DECISION_20261018.md`](./PICO_ROUTE_DECISION_20261018.md)。
> 仅在路线 A 验证失败时才回来执行本文档。

结论：**走「2D 面板版」路线** —— 保留现有 Kotlin / Leanback 代码，让它在 Pico 的 VR 大屏里作为 2D 应用可用。
不建议整体重写为原生 VR 应用（成本 ≈ 重写整个 NasCab 客户端）。播放器可单独升级为「巨幕影院」。

---

## 一、为什么是这个结论

### 1. Pico 上 2D App 的运行机制（实测）

| 项 | 实测值 |
|---|---|
| 设备 | `sparrow` / A9210，Android 14，物理屏 4320×2160 |
| 应用窗口 | 由 `com.pvr.vrshell` 放进 `NS_APP[com.nascabos.tv]` 虚拟显示，**1600×900 横屏** |
| 窗口标志 | `FLAG_SECURE` + `FLAG_PRIVATE` → **无法截图、无法 `uiautomator dump`**，只能靠 logcat / `dumpsys` 取证 |
| 输入法 | 独立虚拟显示 `NS_INPUT_METHOD`（display 2，1020×540），PicoIME 自绘键盘渲染在那里 |
| 焦点管理 | 由 `com.pvr.vrshell` 掌管，2D App 窗口的 window focus 时有时无 |
| 控制器 | `Classes: KEYBOARD \| TOUCH \| CURSOR \| DPAD \| GAMEPAD \| JOYSTICK`，KeyLayout = `Generic.kl` |
| 按键映射 | `Generic.kl`：`103→DPAD_UP`、`105/106→DPAD_LEFT/RIGHT`、`108→DPAD_DOWN`、`353→DPAD_CENTER`、`28→ENTER`、`158→BACK` |

**关键推论：手柄天然发出 DPAD / ENTER / BACK，Leanback 的「D-pad 焦点导航」模型正好匹配，不需要推倒重来。**

### 2. 现有代码的 Leanback 依赖面

```
35 个文件、136 处 androidx.leanback import
VerticalGridView            67 处
GuidedStepSupportFragment   32 处
BrowseSupportFragment        4 处
```

结论：**短期不要去 Leanback**（代价过大，且它本身适合手柄）；长期若要做指针/触摸滚动，再按模块逐步替换。

---

## 二、阻塞点清单（按优先级）

### P0-1 视频会黑屏（最致命）

`res/layout/activity_tv_video_player.xml`：

- `androidx.media3.ui.PlayerView` 未指定 `app:surface_type` → **默认 SurfaceView**
- `org.videolan.libvlc.util.VLCVideoLayout` → **内部也是 SurfaceView**

SurfaceView 走独立 SurfaceFlinger 图层，在 VR 虚拟显示的合成路径上通常**不出画面**（表现为有声音、无图像）。
必须改成 `TextureView`（走 View 层级绘制，能被虚拟显示正常合成）。

### P0-2 无法输入文字（已定位根因）

搜索关键词、服务器地址、2FA、密码等全部依赖 Leanback `GuidedStepSupportFragment` 的编辑态 + 系统 IME。
反编译 `androidx.leanback:leanback:1.0.0` 后确认三个叠加问题：

1. `GuidedActionAdapterGroup.openIme()` **只调一次** `requestFocus()` + `showSoftInput()`，且不等布局。
   GuidedStep 入场过渡期间编辑 view 还是 `0,0-0,0`，焦点根本没落地：
   ```
   W/InputMethodManager: Ignoring showSoftInput() as view=GuidedActionEditText{... 0,0-0,0} is not served.
   ```
2. `GuidedActionsStylist.onBindViewHolder()` 结尾**无条件调用** `setEditingMode(vh, false, false)`，
   并把 title/description 重新 `setFocusable(false)` —— 过渡结束时的那次 rebind 会把 openIme 的成果全部抹掉。
3. 同一方法里，若 action 可聚焦，itemView 被设为 `FOCUS_BEFORE_DESCENDANTS`（`131072`），
   **容器优先于子 view 抢焦点**，IMM 的 served view 永远是 `GuidedActionItemContainer`。

在普通 TV 上这三条都被「窗口有真实 focus + 无 rebind」掩盖了；在 VR 虚拟显示上全部暴露。
→ **不要在 VR 上依赖系统 IME，做应用内自绘键盘。**

### P0-3 Manifest 的 TV 专属声明

`app/src/main/AndroidManifest.xml`：

```xml
<uses-feature android:name="android.software.leanback" android:required="true" />  <!-- 会挡住非 TV 分发 -->
<activity android:name=".MainActivity" android:banner="@drawable/tv_banner" ... >  <!-- banner 只有 TV 用 -->
<!-- 5 个 Activity 全部没有 android:configChanges / android:screenOrientation -->
```

### P1-4 UI 尺寸

虚拟显示 1600×900（约 200dpi）。当前字号（`14sp`/`18sp`）和 Leanback 的 `ImageCardView` 尺寸
是按 1080p TV、10% 观看距离设计的，在 VR 里会**明显偏小**。

### P1-5 生命周期

5 个 Activity 都没声明 `configChanges`。VR 里虚拟显示重建 / 手柄连接变化 / 密度变化都会
触发 Activity 重建，播放中会丢进度。

### P2-6 息屏

只有播放器布局有 `android:keepScreenOn="true"`，其余页面在 VR 里会按系统策略息屏。

---

## 三、分阶段落地方案

### 阶段 0：最小可验证包（先确认「能装能起、能点、能出画面」）

| # | 改动 | 文件 |
|---|---|---|
| 0.1 | `leanback` 改 `required="false"`；去掉 `android:banner`；`MainActivity` 补 `android:screenOrientation="landscape"` | `AndroidManifest.xml` |
| 0.2 | 所有 Activity 补 `android:configChanges="orientation\|screenSize\|screenLayout\|smallestScreenSize\|density\|keyboardHidden\|uiMode"` | `AndroidManifest.xml` |
| 0.3 | `PlayerView` 加 `app:surface_type="texture_view"` | `res/layout/activity_tv_video_player.xml` |
| 0.4 | 写一个 `res/xml/backup_rules` 之外不需要；重点是打**对照包**：`texture_view` 版 vs 原版 | — |
| 0.5 | 加一个调试探针页，日志打出：当前 display id、window focus、`PlayerView` 的 surface 类型、收到的按键序列 | 临时代码 |

**验收**：戴头显打开视频 → 有画面；手柄摇杆/扳机 → 焦点能动、能选中。

### 阶段 1：输入（决定「能不能用」）

放弃系统 IME，做**应用内自绘键盘**：

- 新建 `core/ui/keyboard/`：
  - `TvKeyboardView.kt` —— 自绘九宫格 / QWERTY 面板（**必须支持 D-pad 移动焦点 + ENTER 确认**，不依赖触摸）
  - `TvKeyboardDialogFragment.kt` —— 承载面板，返回输入结果
- 改造所有 `GuidedStepSupportFragment` 输入页（搜索 / 添加编辑服务器 / 2FA / 密码 / 配对码 / 开发设置）：
  把 `editable(true)` 的行改成「点击 → 弹出自绘键盘 → 回填 `editDescription`」
- 新增 `serverlist` 之外的公共入口，避免 32 处 GuidedStep 各写一遍

> 自绘键盘不依赖 IMM、不依赖 served view、不走 extract UI，一次做好在 Pico 上 100% 可控。
> 真 TV 上保留现有 IME 行为即可（自绘键盘只在检测到 VR/无 IME 环境时启用，或常驻）。

### 阶段 2：UI 适配

- `res/values/dimens.xml` 抽出间距/字号基准，新增 `res/values-sw600dp/`（或按 VR flavor 覆盖）
- Leanback 卡片尺寸、`rowHeaderStyle` 字号整体放大一档
- 焦点态更明显（VR 里观看距离远，Leanback 默认的缩放动画不够）

### 阶段 3：播放器

- 阶段 0 已切 TextureView；验证性能（TextureView 更吃 CPU，4K 可能掉帧）
- 若要做「巨幕影院」：单独做 —— 用 Pico 的系统播放器 intent 或 Pico/OpenXR SDK 承载播放，
  **只改 `TvVideoPlayerActivity` 一个模块**，其余 2D 界面不变

### 阶段 4（长期、可选）：去 Leanback 化

按模块把 `VerticalGridView` / `BrowseSupportFragment` 换成 `RecyclerView` + 自定义焦点控制，
为触摸滚动 / 指针交互留空间。**不要和阶段 0~3 并行。**

---

## 四、工程结构建议：用 productFlavor 隔离

不要在同一份代码里塞 `if (isVr)`。建议：

```kotlin
android {
    flavorDimensions += "device"
    productFlavors {
        create("tv")   { dimension = "device" }
        create("pico") { dimension = "device"; applicationIdSuffix = ".pico" }
    }
}
```

- `src/tv/` 与 `src/pico/` 各自放 `AndroidManifest` 覆盖、dimens、键盘开关
- 共用 `src/main/` 里 95% 的业务代码
- 好处：TV 版零风险回归，Pico 版独立发版

---

## 五、需要拍板的两件事

1. **目标形态**：只要「VR 里的 2D 大屏」（阶段 0~2 即可，约 1~2 天工作量），
   还是必须「沉浸式巨幕影院」（额外 + 阶段 3 的 VR 播放模块）？
2. **是否接受 pico flavor**：还是希望 Pico 版直接复用 `com.nascabos.tv` 这个 applicationId？

---

## 六、已完成的排查资产（不要丢）

- Leanback 反编译产物在 `/tmp/lbx/cls`（重启会丢，需要时可重新解 `leanback-1.0.0.aar`）
- `TvImeHelper.kt` 已重写为「轮询开编辑态 + 守焦点 + 自愈」版本（**尚未编译验证、尚未安装**），
  对真 TV 仍有兜底价值，但**不是 Pico 的最终解法**，Pico 应走自绘键盘
- 关键取证命令：
  ```sh
  adb shell dumpsys input_method | grep -E "mServedView|mNextServedView|mInputShown|mCurFocusedWindow"
  adb logcat -v brief -s TvImeHelper
  adb shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp"
  adb shell dumpsys display | grep -E "displayId|uniqueId"
  ```
  注意：Pico 上 logd 会在高频日志时丢弃 `Log.d`，诊断请用 `Log.w`。
