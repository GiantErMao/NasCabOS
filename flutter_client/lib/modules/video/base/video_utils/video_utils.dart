import '../../../../core/api/api_controller.dart';
import '../beans/video_item_bean.dart';

class VideoUtils {
  static bool isMetaTubeMovie(VideoHomeItemBean item) {
    final mediaType = item.mediaType.trim().toLowerCase();
    return item.nfoSource.trim().toLowerCase() == 'metatube' &&
        (mediaType == 'movie' ||
            mediaType == 'bdmv' ||
            mediaType == 'video_ts');
  }

  static String getCardImagePath(VideoHomeItemBean item) {
    if (isMetaTubeMovie(item) && item.fanartPath.trim().isNotEmpty) {
      return item.fanartPath.trim();
    }
    return item.posterPath.trim();
  }

  static String getPosterUrl(VideoHomeItemBean item, {int? size}) {
    final posterPath = getCardImagePath(item);
    size ??= 500;
    if (posterPath.isNotEmpty) {
      return ApiController.instance.getTinyUrl(posterPath, size: size);
    }

    final fallbackFilePath = item.firstFilePath.isNotEmpty
        ? item.firstFilePath
        : item.fullPath;
    if (fallbackFilePath.trim().isEmpty) return '';
    return ApiController.instance.getTinyUrl(fallbackFilePath, size: size);
  }

  static String getLargeCardPosterUrl(VideoHomeItemBean item) {
    final posterPath = getLargeCardImagePath(item);
    if (posterPath.isNotEmpty) {
      return ApiController.instance.getTinyUrl(posterPath, size: 800);
    }
    return getPosterUrl(item, size: 800);
  }

  static String getLargeCardImagePath(VideoHomeItemBean item) {
    return item.posterPath.trim();
  }

  static String getDetailImagePath(VideoHomeItemBean item) {
    if (isMetaTubeMovie(item) && item.posterPath.trim().isNotEmpty) {
      return item.posterPath.trim();
    }
    final fanart = item.fanartPath.trim();
    return fanart.isNotEmpty ? fanart : item.posterPath.trim();
  }

  static String getDetailImageUrl(VideoHomeItemBean item, {int? size}) {
    final imagePath = getDetailImagePath(item);
    if (imagePath.isNotEmpty) {
      return ApiController.instance.getRawFileUrl(imagePath);
    }
    return getFanartUrl(item, size: size);
  }

  static String getFanartUrl(VideoHomeItemBean item, {int? size}) {
    size ??= 1600;
    final fanartPath = item.fanartPath.trim();
    if (fanartPath.isNotEmpty) {
      return ApiController.instance.getRawFileUrl(fanartPath);
    }
    // 没有 fanart 时回退到 poster，用 rawFile 避免加载 tiny 缩略图
    final posterPath = item.posterPath.trim();
    if (posterPath.isNotEmpty) {
      return ApiController.instance.getRawFileUrl(posterPath);
    }
    return getPosterUrl(item, size: size);
  }
}
