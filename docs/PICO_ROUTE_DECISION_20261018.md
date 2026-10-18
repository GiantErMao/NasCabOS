# Pico 路线选型：改 Flutter 版还是改 TV 版？

日期：2026-10-18
**结论：改非 TV 版（Flutter）。不要为 Pico 去改 `tv_android`。**

---

## 一、结论与核心理由

| 维度 | A：改 Flutter 版为横屏/大屏 | B：改 TV 版适配 Pico |
|---|---|---|
| Pico 兼容性 | **已验证可用**（IME 正常、所有功能正常） | 未验证，已知至少 2 个 P0 阻塞 |
| 长期维护 | 主线即产物，新功能自动到 Pico | 第 4 个客户端，永远落后，要反复移植 |
| 视频渲染 | Flutter 自己走 texture 注册，已验证 | `SurfaceView` 在虚拟显示上大概率黑屏，需改 TextureView |
| 输入 | 系统 IME 已可用，零工作量 | 必须自绘应用内键盘 |
| 交互 | 手柄射线 = 触摸，手机 UI 直接可用 | Leanback D-pad 模型，需额外适配 |
| 主要工作量 | 解锁横屏 + 设备类判定统一 + 排版 QA | Manifest + TextureView + 自绘键盘 + dimens |

**决定性的三条：**

1. **NasCabOS 已经有 5 个客户端**：`flutter_client`（mobile/desktop/web）、`electron_server`、
   `harmony_client`、`tv_android`、`tv_apple`。`flutter_client` 是主线。
   为 Pico 把 `tv_android` 变成"第 4 个需要维护的客户端"，等于把一次适配变成长期负债。
   （此前把 Flutter 分支改动同步到 TV 端，光 3 个批次就涉及 25 个文件 +372/−28，而主线仍在演进。）

2. **Pico 上"非 TV 版能用"这个事实价值极高**。它意味着：Flutter 引擎的渲染路径在 VR 虚拟显示上是通的、
   PicoIME 能正常工作、触摸/射线交互可用。这三件事在 `tv_android` 上**全部要重做**。

3. **竖屏不是"排版问题"，是一行代码**。见下。

---

## 二、决定性发现：竖屏是 `main.dart` 一行代码锁的

`flutter_client/lib/main.dart:68-71`：

```dart
// 手机端固定竖屏，禁止自动横屏（视频播放器内可手动横屏）
if (DeviceUtils.isMobile && !DeviceUtils.isWeb) {
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
}
```

而 `flutter_client/lib/utils/device_utils.dart:69-77`：

```dart
static bool get isMobile {
  if (kIsWeb) { ... }
  return defaultTargetPlatform == TargetPlatform.android ||
         defaultTargetPlatform == TargetPlatform.iOS;   // ← Android 一律 true
}
```

`isMobile` 是**按平台**判定，不看屏幕尺寸 → **所有 Android 设备都被锁竖屏** → Pico 上就是 506×900 竖屏小窗。

## 三、更大的好消息：放开横屏后会自动命中桌面布局

同一个文件里：

```dart
static const double phoneBreakpoint  = 600;
static const double desktopBreakpoint = 600;

static bool isDesktopLayout(BuildContext context) =>
    MediaQuery.of(context).size.width >= desktopBreakpoint;   // 1600 → true
```

`isDesktopLayout` 是**按宽度**判定。Pico 面板 1600×900 → **直接走桌面（大屏）布局分支**。
那么"大屏排版"其实**已经写好了**，只是被竖屏锁挡住没机会生效。

### 但有一个必须修的逻辑冲突

```dart
static bool isPhone(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  return !isDesktopOrWeb && (width < phoneBreakpoint || isMobile);
}
```

`isMobile` 在 Android 恒为 true → **1600 宽的 Pico 面板上 `isPhone == true` 且 `isDesktopLayout == true` 同时成立**。

实测引用量：

```
DeviceUtils.isPhone          42 处
DeviceUtils.isDesktopLayout  11 处
DimensUtil.isMobile/isTablet/isDesktop  0 处（工具类写了但没用上）
```

所以 A 路线的真实工作量是**收敛这个分类**，而不是重写排版。

---

## 四、A 路线落地步骤

### 步骤 1：设备分类收敛（核心，1~2 处文件）

在 `lib/utils/device_utils.dart` 增加"大屏 Android（含 VR 一体机）"这个设备类：

- 新增 `isLargeScreenAndroid`（或 `isVrHeadset`）：Android 且最短边/宽度 ≥ 600（或按 VR 特征判定）
- 修正 `isPhone(context)`：大屏 Android 返回 `false`
- 修正 `isMobile` 的语义，或新增 `isPhoneFormFactor` 专门描述"手机形态"，避免方向锁误伤
- `main.dart`：大屏 Android 不再锁 `portraitUp`，改为 `landscapeLeft/landscapeRight` 或不限制

### 步骤 2：放行横屏后做一次体检（半天，先出结论）

打 debug 包装到 Pico，逐页检查 1600×900 横屏下：
- 首页 / 各模块列表：列数是否按大屏铺开
- 详情页：是否走两栏
- 播放器：横屏全屏是否正常（**必须验证**，这是 A 路线唯一未证实的高风险项）
- 输入框：大屏布局下 PicoIME 是否仍正常

### 步骤 3：VR 观看距离适配

1600×900 @ ~200dpi + 几米观看距离 → 需要放大：
- 命中目标（列表项、按钮）放大
- 字号/间距按 VR 场景再提一档（可复用 `DimensUtil`，目前它 0 引用，正好接上）
- 焦点/选中态要更明显（射线悬停态）

### 步骤 4（可选）：手柄增强

Pico 控制器同时上报 `TOUCH|CURSOR|DPAD|GAMEPAD`，射线即触摸，所以**不强制要求**做 D-pad 导航。
若要加，可用 Flutter `FocusTraversalGroup` + `DirectionalFocusIntent` 逐步补。

---

## 五、风险与应对

| 风险 | 说明 | 应对 |
|---|---|---|
| 横屏后排版错乱 | `isPhone` 42 处与 `isDesktopLayout` 11 处可能给出矛盾分支 | 步骤 1 先统一分类，再逐页 QA |
| 播放器全屏未知 | 用户"所有功能正常"是否已含全屏播放未确认 | 步骤 2 第一优先验证 |
| 桌面布局在 1600 宽下可能偏挤 | 桌面断点 600 是按 PC 定的 | 必要时为 VR 单设断点（如 ≥1280 且 Android） |
| 鸿蒙端 / 手机端回归 | 改 `isMobile` 语义影响面大 | 用新增 getter 而非改原语义，手机端行为不变 |

---

## 六、建议的第一步（成本极低，先验证再投入）

只做两件事，不改任何排版：

1. `main.dart`：加条件，大屏 Android 不锁竖屏
2. `device_utils.dart`：加 `isLargeScreenAndroid`，让 `isPhone(context)` 在其上返回 false

然后打一个 debug 包装上 Pico，看 1600×900 横屏下桌面布局自动生效后的真实样子。
**这一轮就能拿到全部决策信息**——如果排版已经能看，A 路线工作量比想象的小得多；
如果惨不忍睹，再回头考虑 B 也不迟（TV 版适配方案另见 `PICO_ADAPTATION_PLAN_20261018.md`，已降级为备选）。

---

## 七、`tv_android` 怎么办

- **停止**为 Pico 投入（已做的 `TvImeHelper` 保留，对真 Android TV 仍有兜底价值）
- `tv_android` 回归它的本分：真实 Android TV / 电视盒子
- 若将来真要"巨幕影院"，只做播放器那一层（Pico 系统播放器 intent 或 OpenXR），不要动整个客户端
