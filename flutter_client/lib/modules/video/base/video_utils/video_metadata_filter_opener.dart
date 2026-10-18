import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../list/view/app_video_metadata_videos_page.dart';
import '../../list/view/app_video_person_videos_page.dart';
import '../../video_main/controller/video_main_controller.dart';

/// 从详情页按元数据（类型 / 地区 / 演员 / 导演）打开「同类影片」筛选列表。
///
/// 桌面布局下筛选列表由 [VideoMainController] 承载为浮层；但从文件模块、收藏等入口
/// 直接打开详情时该 controller **并未注册**（没有浮层宿主），
/// 此时必须退化为独立筛选页，否则点击会静默失效（没有任何反馈）。
class VideoMetadataFilterOpener {
  VideoMetadataFilterOpener._();

  static void open({
    required VideoFilterOverlayKind kind,
    required String value,
    String? mediaType,
  }) {
    final v = value.trim();
    if (v.isEmpty) return;
    final mt = (mediaType ?? '').trim();

    final hasHost = Get.isRegistered<VideoMainController>();
    if (kDebugMode) {
      debugPrint(
        '[MetaFilter] kind=${kind.name} value="$v" mediaType="$mt" overlayHost=$hasHost',
      );
    }

    if (hasHost) {
      Get.find<VideoMainController>().openFilterOverlay(
        kind: kind,
        value: v,
        mediaType: mt,
      );
      return;
    }

    switch (kind) {
      case VideoFilterOverlayKind.genre:
      case VideoFilterOverlayKind.region:
        final isRegion = kind == VideoFilterOverlayKind.region;
        Get.to(
          () => isRegion
              ? AppVideoMetadataVideosPage.region(value: v, mediaType: mt)
              : AppVideoMetadataVideosPage.genre(value: v, mediaType: mt),
          preventDuplicates: false,
        );
        return;
      case VideoFilterOverlayKind.actor:
      case VideoFilterOverlayKind.director:
        final isDirector = kind == VideoFilterOverlayKind.director;
        Get.to(
          () => isDirector
              ? AppVideoPersonVideosPage.director(name: v, mediaType: mt)
              : AppVideoPersonVideosPage.actor(name: v, mediaType: mt),
          preventDuplicates: false,
        );
        return;
    }
  }
}
