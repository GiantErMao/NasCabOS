import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../controllers/video_player_controller.dart';
import '../playback/playback_video_surface.dart';
import 'components/web_subtitle_overlay.dart';
import 'app_components/app_video_player_top_bar.dart';
import 'app_components/app_video_player_bottom_bar.dart';
import 'app_components/app_video_center_controls.dart';
import '../../../utils/device_utils.dart';

class AppVideoPlayerPage extends StatefulWidget {
  final List<Map<String, dynamic>>? playlist;
  final int initialIndex;

  const AppVideoPlayerPage({super.key, this.playlist, this.initialIndex = 0});

  @override
  State<AppVideoPlayerPage> createState() => _AppVideoPlayerPageState();
}

class _AppVideoPlayerPageState extends State<AppVideoPlayerPage> {
  static const MethodChannel _mobileControlsChannel = MethodChannel(
    'com.nascabos/mobile_player_controls',
  );
  static const double _maxSeekFractionPerScreen = 0.25;
  static const Duration _maxSeekPerScreen = Duration(minutes: 10);

  late final PlayerController controller;
  bool _isControllerCreated = false;
  bool _handlingBack = false;

  final GlobalKey _scrubLayoutKey = GlobalKey();

  /// 横向滑动进度预览（松手后 seek）
  bool _scrubActive = false;
  Duration _scrubOrigin = Duration.zero;
  double _scrubAccumDx = 0;
  Duration? _scrubPreview;
  Offset? _scrubLastGlobalPosition;

  bool _verticalDragActive = false;
  bool _verticalDragControlsBrightness = false;
  double _verticalDragValue = 0.5;
  double _brightnessValue = 0.5;
  double _systemVolumeValue = 0.5;
  IconData? _verticalDragIcon;

  @override
  void initState() {
    super.initState();
    _initController();
    _loadMobileControlValues();
  }

  Future<void> _loadMobileControlValues() async {
    if (!DeviceUtils.isMobile) return;
    try {
      final values = await Future.wait<num?>([
        _mobileControlsChannel.invokeMethod<num>('getBrightness'),
        _mobileControlsChannel.invokeMethod<num>('getVolume'),
      ]);
      _brightnessValue = (values[0]?.toDouble() ?? 0.5).clamp(0.0, 1.0);
      _systemVolumeValue = (values[1]?.toDouble() ?? 0.5).clamp(0.0, 1.0);
    } on PlatformException {
      // 非 Android 平台或通道尚未就绪时沿用安全默认值。
    }
  }

  void _initController() {
    if (Get.isRegistered<PlayerController>()) {
      Get.delete<PlayerController>(force: true);
    }
    controller = PlayerController();
    Get.put(controller);
    _isControllerCreated = true;

    final args = Get.arguments as Map<String, dynamic>?;
    final playlist =
        widget.playlist ?? args?['playlist'] as List<Map<String, dynamic>>?;
    final initialIndex = widget.playlist != null
        ? widget.initialIndex
        : (args?['initialIndex'] as int?) ?? 0;
    if (args != null) {
      final raw = args['ignoreFindSub'];
      final parsed = raw == null ? null : int.tryParse(raw.toString());
      controller.ignoreFindSub = (parsed == 0) ? 0 : 1;
    } else {
      controller.ignoreFindSub = 1;
    }

    int? maxRetryFromArgs;
    if (args != null) {
      final raw = args['maxRetryCount'] ?? args['maxReloadRetries'];
      if (raw != null) {
        final parsed = int.tryParse(raw.toString());
        if (parsed != null && parsed >= 0) {
          maxRetryFromArgs = parsed;
        }
      }
    }

    if (playlist != null && playlist.isNotEmpty) {
      controller.openPlaylist(
        items: playlist,
        initialIndex: initialIndex,
        maxRetryCount: maxRetryFromArgs,
      );
    }
  }

  @override
  void dispose() {
    if (DeviceUtils.isMobile) {
      unawaited(
        _mobileControlsChannel
            .invokeMethod<void>('resetBrightness')
            .catchError((_) {}),
      );
    }
    if (_isControllerCreated && Get.isRegistered<PlayerController>()) {
      controller.setCtrlSpeedBoost(false);
      Get.delete<PlayerController>(force: true);
    }
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    final twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    return '${twoDigits(d.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
  }

  void _onMobileLongPressStart(LongPressStartDetails details) {
    if (controller.isLocked.value) return;
    controller.setCtrlSpeedBoost(true);
  }

  void _onMobileLongPressEnd(LongPressEndDetails details) {
    controller.setCtrlSpeedBoost(false);
  }

  void _onMobileLongPressCancel() {
    controller.setCtrlSpeedBoost(false);
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (controller.isLocked.value) return;
    if (!controller.isInitialized.value) return;
    if (controller.duration.value <= Duration.zero) return;
    _scrubActive = true;
    _scrubOrigin = controller.position.value;
    _scrubAccumDx = 0;
    _scrubLastGlobalPosition = details.globalPosition;
    setState(() => _scrubPreview = _scrubOrigin);
    HapticFeedback.lightImpact();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_scrubActive) return;
    _scrubLastGlobalPosition = details.globalPosition;
    final w = MediaQuery.sizeOf(context).width;
    if (w < 1) return;
    _scrubAccumDx += details.delta.dx;
    final totalMs = controller.duration.value.inMilliseconds;
    final seekRangeMs = (totalMs * _maxSeekFractionPerScreen)
        .clamp(0, _maxSeekPerScreen.inMilliseconds)
        .round();
    final deltaMs = (_scrubAccumDx / w * seekRangeMs).round();
    final ms = (_scrubOrigin.inMilliseconds + deltaMs).clamp(0, totalMs);
    setState(() => _scrubPreview = Duration(milliseconds: ms));
  }

  /// 手指是否在顶部 25% 取消区内（相对播放器全屏区域）
  bool _isPointerInScrubCancelZone(Offset? global) {
    if (global == null) return false;
    final box =
        _scrubLayoutKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return false;
    final local = box.globalToLocal(global);
    final h = box.size.height;
    final w = box.size.width;
    if (local.dy < 0 || local.dy > h * 0.25) return false;
    if (local.dx < 0 || local.dx > w) return false;
    return true;
  }

  void _endScrub({required bool applySeek}) {
    if (!_scrubActive) return;
    _scrubActive = false;
    _scrubLastGlobalPosition = null;
    final target = _scrubPreview;
    setState(() => _scrubPreview = null);
    if (applySeek && target != null) {
      controller.seekTo(target);
      HapticFeedback.selectionClick();
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final cancel = _isPointerInScrubCancelZone(_scrubLastGlobalPosition);
    if (cancel) {
      HapticFeedback.lightImpact();
    }
    _endScrub(applySeek: !cancel);
  }

  void _onHorizontalDragCancel() {
    _endScrub(applySeek: false);
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (controller.isLocked.value) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width < 1 || size.height < 1) return;
    _verticalDragControlsBrightness = details.localPosition.dx < size.width / 2;
    _verticalDragValue = _verticalDragControlsBrightness
        ? _brightnessValue
        : _systemVolumeValue;
    _verticalDragActive = true;
    setState(() {
      _verticalDragIcon = _verticalDragControlsBrightness
          ? Icons.brightness_6_rounded
          : Icons.volume_up_rounded;
    });
    HapticFeedback.lightImpact();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_verticalDragActive) return;
    final h = MediaQuery.sizeOf(context).height;
    if (h < 1) return;
    _verticalDragValue = (_verticalDragValue - details.delta.dy / h).clamp(
      0.0,
      1.0,
    );
    final method = _verticalDragControlsBrightness
        ? 'setBrightness'
        : 'setVolume';
    if (_verticalDragControlsBrightness) {
      _brightnessValue = _verticalDragValue;
    } else {
      _systemVolumeValue = _verticalDragValue;
    }
    unawaited(
      _mobileControlsChannel
          .invokeMethod<void>(method, {'value': _verticalDragValue})
          .catchError((_) {}),
    );
    setState(() {});
  }

  void _endVerticalDrag() {
    if (!_verticalDragActive) return;
    _verticalDragActive = false;
    HapticFeedback.selectionClick();
    setState(() => _verticalDragIcon = null);
  }

  Widget _buildVerticalDragOverlay() {
    final icon = _verticalDragIcon;
    if (icon == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 150,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xCC0D0D0D),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 30),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _verticalDragValue,
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
                backgroundColor: Colors.white.withValues(alpha: 0.2),
                color: const Color(0xFF448AFF),
              ),
              const SizedBox(height: 8),
              Text(
                '${(_verticalDragValue * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (!DeviceUtils.isMobile) return true;
    if (_handlingBack) return false;
    if (!controller.isLandscape.value) return true;
    _handlingBack = true;
    await controller.prepareExitIfLandscape();
    _handlingBack = false;
    Get.back();
    return false;
  }

  Widget _buildMobileScrubOverlay() {
    final preview = _scrubPreview;
    if (preview == null) return const SizedBox.shrink();
    final total = controller.duration.value;
    final totalMs = total.inMilliseconds;
    final progress = totalMs > 0 ? preview.inMilliseconds / totalMs : 0.0;
    final delta = preview - _scrubOrigin;
    final forward = delta >= Duration.zero;

    // Positioned 必须是 Stack 的直接子节点；放在 LayoutBuilder 内会导致布局异常（全屏异常底色、顶部区高度为 0）。
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: 0.25,
            alignment: Alignment.topCenter,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.82),
                      Colors.black.withValues(alpha: 0.48),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  minimum: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                    child: Center(
                      child: Text(
                        'player_scrub_cancel_zone_hint'.tr,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.94),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.55),
                              blurRadius: 8,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              decoration: BoxDecoration(
                color: const Color(0xCC0D0D0D),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        forward
                            ? Icons.fast_forward_rounded
                            : Icons.fast_rewind_rounded,
                        color: Colors.white.withValues(alpha: 0.85),
                        size: 26,
                      ),
                      const SizedBox(width: 14),
                      Flexible(
                        child: Text(
                          '${_formatDuration(preview)} / ${_formatDuration(total)}',
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 4,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(
                            color: Colors.white.withValues(alpha: 0.18),
                          ),
                          FractionallySizedBox(
                            widthFactor: progress.clamp(0.0, 1.0),
                            heightFactor: 1,
                            alignment: Alignment.centerLeft,
                            child: const ColoredBox(color: Color(0xFF448AFF)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerStack(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: Obx(() {
            final engine = controller.playbackEngine.value;
            if (engine == null || !controller.shouldMountVideoSurface) {
              return const Center(child: CircularProgressIndicator());
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                PlaybackVideoSurface(
                  engine: engine,
                  onNativeViewCreated: controller.onMedia3SurfaceReady,
                  onSurfaceTap: controller.handlePlayerTap,
                ),
                if (!controller.isInitialized.value)
                  const Center(child: CircularProgressIndicator()),
              ],
            );
          }),
        ),
        Positioned.fill(
          child: Obx(
            () => WebSubtitleOverlay(
              text: controller.webActiveSubtitleText.value,
              bottomPadding: controller.transcodeSubtitleBottomPadding(context),
            ),
          ),
        ),
        const AppVideoPlayerTopBar(),
        const AppVideoCenterControls(),
        const AppVideoPlayerBottomBar(),
        Obx(() {
          if (!controller.isCtrlSpeedBoost.value) {
            return const SizedBox.shrink();
          }
          return Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    'player_speed_boost_tip'.tr,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: DeviceUtils.isMobile
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: controller.handlePlayerTap,
                onLongPressStart: _onMobileLongPressStart,
                onLongPressEnd: _onMobileLongPressEnd,
                onLongPressCancel: _onMobileLongPressCancel,
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                onHorizontalDragCancel: _onHorizontalDragCancel,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: (_) => _endVerticalDrag(),
                onVerticalDragCancel: _endVerticalDrag,
                child: Stack(
                  key: _scrubLayoutKey,
                  fit: StackFit.expand,
                  children: [
                    _buildPlayerStack(context),
                    _buildMobileScrubOverlay(),
                    _buildVerticalDragOverlay(),
                  ],
                ),
              )
            : KeyboardListener(
                focusNode: FocusNode(),
                autofocus: true,
                onKeyEvent: (event) {
                  if (event is KeyDownEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                      controller.rewind(seconds: 10);
                    } else if (event.logicalKey ==
                        LogicalKeyboardKey.arrowRight) {
                      controller.fastForward(seconds: 30);
                    } else if (event.logicalKey == LogicalKeyboardKey.space) {
                      controller.togglePlay();
                    } else if (event.logicalKey ==
                            LogicalKeyboardKey.controlLeft ||
                        event.logicalKey == LogicalKeyboardKey.controlRight) {
                      controller.setCtrlSpeedBoost(true);
                    }
                  } else if (event is KeyUpEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
                        event.logicalKey == LogicalKeyboardKey.controlRight) {
                      controller.setCtrlSpeedBoost(false);
                    }
                  }
                },
                child: GestureDetector(
                  onTap: controller.handlePlayerTap,
                  child: _buildPlayerStack(context),
                ),
              ),
      ),
    );
  }
}
