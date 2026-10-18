import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_controller.dart';
import '../../../modules/user/service/user_api_service.dart';
import '../../../utils/device_utils.dart';

/// 视频播放方式。
enum VideoPlayerMode {
  /// 应用内置播放器（FVP / Media3），支持字幕、转码、连播、进度记忆等全部能力。
  inApp,

  /// 设备自带播放器（VR 一体机如 Pico 上是 `com.picovr.wing.videoplayer`）。
  ///
  /// 直接定位到包名启动，避免 VR 环境下系统选择器无法交互。
  vrPlayer,

  /// 系统选择器：列出所有能播放该视频的应用，每次询问（可设为默认）。
  systemChooser,
}

extension VideoPlayerModeX on VideoPlayerMode {
  /// 传给 Android 端的启动目标；`inApp` **不映射到任何原生目标**（返回 null）。
  ///
  /// 内置播放器根本不走原生侧——把它映射成 'chooser' 会让「内置播放器」变成
  /// 「系统选择器」，语义是反的。调用方必须先判 mode != inApp。
  String? get nativeTarget => switch (this) {
    VideoPlayerMode.vrPlayer => 'vr',
    VideoPlayerMode.systemChooser => 'chooser',
    VideoPlayerMode.inApp => null,
  };

  static VideoPlayerMode fromPreference(String? raw) => switch (raw) {
    'vrPlayer' => VideoPlayerMode.vrPlayer,
    'systemChooser' => VideoPlayerMode.systemChooser,
    _ => VideoPlayerMode.inApp,
  };
}

/// 播放方式的进程内缓存：避免每次进入播放都读一次 SharedPreferences。
class ExternalPlayerModeCache {
  ExternalPlayerModeCache._();

  static VideoPlayerMode? _cached;

  static Future<VideoPlayerMode> mode() async {
    final cached = _cached;
    if (cached != null) return cached;
    final loaded = await ExternalPlayer.loadMode();
    _cached = loaded;
    return loaded;
  }

  static void update(VideoPlayerMode mode) => _cached = mode;
}

/// 拉起外部播放器。
///
/// 用途：在 Pico 这类 VR 一体机上，用设备自带的播放器播放可以获得更好的
/// 巨幕 / 全景播放体验，且不受应用内渲染路径限制。
class ExternalPlayer {
  ExternalPlayer._();

  static const MethodChannel _channel = MethodChannel(
    'com.nascabos/external_player',
  );
  static const String _prefKey = 'video_player_mode';

  /// 仅 Android 支持拉起系统播放器。
  static bool get supported => DeviceUtils.isAndroid;

  static Future<VideoPlayerMode> loadMode() async {
    if (!supported) return VideoPlayerMode.inApp;
    try {
      final prefs = await SharedPreferences.getInstance();
      return VideoPlayerModeX.fromPreference(prefs.getString(_prefKey));
    } catch (_) {
      return VideoPlayerMode.inApp;
    }
  }

  static Future<void> saveMode(VideoPlayerMode mode) async {
    ExternalPlayerModeCache.update(mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (_) {}
  }

  /// 原画直链，与内置播放器「原画」档一致。
  ///
  /// 该 URL 会通过 ACTION_VIEW 交给**第三方**播放器：Intent 的 data 对目标应用完全可见，
  /// 还可能落进日志。因此这里只使用**受限令牌**（仅允许 /api/videoPlayer/rawFile
  /// 和当前文件路径）。申请失败时返回空 URL，由调用方回退到应用内播放器。
  static Future<String> buildDirectUrl(Map<String, dynamic> item) async {
    final p = item['path']?.toString().trim() ?? '';
    if (p.isEmpty) return '';
    if (_isHttpUrl(p)) return p;
    final api = ApiController.instance;
    final internalPath = item['internalPath']?.toString().trim() ?? '';
    // rawFile 的权限检查针对 query.path；internalPath 只是播放附加信息。
    final token = await _tokenForExternalPlayback(<String>[p]);
    if (token.isEmpty) return '';
    var url =
        '${api.baseUrl}/api/videoPlayer/rawFile?raw=1&path=${Uri.encodeComponent(p)}';
    if (internalPath.isNotEmpty) {
      url += '&internalPath=${Uri.encodeComponent(internalPath)}';
    }
    url += '&accessToken=${Uri.encodeComponent(token)}';
    return url;
  }

  /// 交给外部播放器使用的令牌：申请失败时不暴露普通访问令牌。
  static Future<String> _tokenForExternalPlayback(List<String> rawPaths) async {
    final paths = rawPaths
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (paths.isNotEmpty) {
      try {
        final res = await UserApiService.instance.createScopedToken(
          allowApi: const <String>['/api/videoPlayer/rawFile'],
          allowPath: paths,
        );
        if (res.success) {
          final scoped = res.data?['accessToken']?.toString().trim() ?? '';
          if (scoped.isNotEmpty) return scoped;
        }
      } catch (_) {}
    }
    return '';
  }

  /// 拉起系统播放器播放单个视频。返回是否成功发起。
  static Future<bool> launch(
    Map<String, dynamic> item, {
    int startPositionSeconds = 0,
    VideoPlayerMode? mode,
  }) async {
    if (!supported) return false;
    // 内置播放器不走原生侧；这里拿不到原生目标就直接拒绝，避免静默拉起系统选择器。
    final target = (mode ?? VideoPlayerMode.systemChooser).nativeTarget;
    if (target == null) return false;
    try {
      final url = await buildDirectUrl(item);
      if (url.isEmpty) return false;
      final ok = await _channel.invokeMethod<bool>('launch', <String, dynamic>{
        'url': url,
        'title': titleOf(item),
        'mimeType': mimeTypeOf(item),
        'startPositionSeconds': startPositionSeconds,
        'target': target,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 设备是否装了已知的 VR 自带播放器（Pico 等）。
  static Future<bool> hasVrPlayer() async {
    if (!supported) return false;
    try {
      final pkg = await _channel.invokeMethod<String>('vrPlayer');
      return pkg != null && pkg.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static String titleOf(Map<String, dynamic> item) {
    for (final key in const ['name', 'title', 'fileName']) {
      final v = item[key]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    final p = item['path']?.toString() ?? '';
    final parts = p.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? '' : parts.last;
  }

  static String mimeTypeOf(Map<String, dynamic> item) {
    final p = item['path']?.toString().toLowerCase() ?? '';
    final dot = p.lastIndexOf('.');
    if (dot < 0 || dot >= p.length - 1) return 'video/*';
    switch (p.substring(dot)) {
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.ts':
        return 'video/mp2ts';
      case '.avi':
        return 'video/avi';
      case '.mov':
        return 'video/quicktime';
      case '.flv':
        return 'video/x-flv';
      case '.m3u8':
        return 'application/x-mpegURL';
      default:
        return 'video/*';
    }
  }

  static bool _isHttpUrl(String value) {
    final v = value.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }
}
