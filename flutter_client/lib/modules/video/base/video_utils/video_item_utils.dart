import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import '../../../../utils/browse_path_utils.dart';
import '../beans/video_item_bean.dart';

String extractVideoCodeFromFilename(String filename) {
  final base = p.basenameWithoutExtension(filename).trim();
  if (base.isEmpty) return '';

  final patterns = <RegExp>[
    RegExp(
      r'(^|[^0-9a-z])((?:fc2[-_\s]?(?:ppv[-_\s]?)?\d{5,8}))(?=$|[^0-9a-z])',
      caseSensitive: false,
    ),
    RegExp(
      r'(^|[^0-9a-z])((?:1pondo[-_\s]?\d{6}[-_]\d{2,4}))(?=$|[^0-9a-z])',
      caseSensitive: false,
    ),
    RegExp(
      r'(^|[^0-9a-z])([a-z]{2,8}[-_\s]\d{2,6}(?:[-_]\d{1,3})?)(?:ch)?(?=$|[^0-9a-z])',
      caseSensitive: false,
    ),
  ];

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(base)) {
      final raw = (match.group(2) ?? '').trim();
      final code = _normalizeVideoCode(raw);
      if (_isLikelyVideoCode(code)) return code;
    }
  }

  return '';
}

String resolveVideoDisplayTitle({
  required String filename,
  required String nfoName,
}) {
  final fallback = filename.trim();
  final title = nfoName.trim().isNotEmpty ? nfoName.trim() : fallback;
  final code = extractVideoCodeFromFilename(filename);
  if (code.isEmpty || title.isEmpty) return title;

  if (title.toLowerCase().contains(code.toLowerCase())) return title;
  return '$code $title';
}

String resolveVideoItemDisplayTitle(VideoHomeItemBean item) {
  return resolveVideoDisplayTitle(
    filename: item.filename,
    nfoName: item.nfoName,
  );
}

String resolveVideoMapDisplayTitle(Map<dynamic, dynamic>? item) {
  final filename = (item?['filename']?.toString() ?? '').trim();
  final nfoName = (item?['nfo_name']?.toString() ?? '').trim();
  return resolveVideoDisplayTitle(filename: filename, nfoName: nfoName);
}

String _normalizeVideoCode(String value) {
  return value
      .trim()
      .replaceAll(RegExp(r'[\s_]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .toUpperCase();
}

bool _isLikelyVideoCode(String code) {
  if (code.isEmpty) return false;
  final parts = code.split('-');
  if (parts.length < 2) return false;

  final prefix = parts.first.toLowerCase();
  final lastNumber = int.tryParse(parts.last);
  if (lastNumber == null) return false;

  const denyPrefixes = {
    'bd',
    'bluray',
    'dvd',
    'hdr',
    'remux',
    'uhd',
    'web',
    'webrip',
  };
  if (denyPrefixes.contains(prefix)) return false;

  const resolutionNumbers = {480, 540, 720, 1080, 1440, 2160, 4320};
  if (resolutionNumbers.contains(lastNumber)) return false;
  if (lastNumber >= 1900 && lastNumber <= 2099) return false;

  return true;
}

String videoMediaTypeText(String mediaType) {
  final t = mediaType.toLowerCase();
  if (t == 'tv' || t == 'episod' || t == 'season') {
    return 'video_home_type_tv'.tr;
  }
  if (t == 'movie' || t == 'bdmv' || t == 'video_ts') {
    return 'video_home_type_movie'.tr;
  }
  return mediaType;
}

String buildVideoHomeMeta(VideoHomeItemBean item) {
  String pickFirst(String s) {
    final parts = s
        .split(RegExp(r'[,，/|、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? '' : parts.first;
  }

  final country = pickFirst(item.nfoRegions);
  final genre = pickFirst(item.nfoGenres);
  if (country.isEmpty && genre.isEmpty) return '';
  if (country.isEmpty) return genre;
  if (genre.isEmpty) return country;
  return '$country · $genre';
}

String resolveVideoBrowsePath(VideoHomeItemBean item) {
  final t = item.mediaType.toLowerCase().trim();
  if (t == 'movie' || t == 'bdmv' || t == 'video_ts') {
    final full = item.fullPath.trim().isNotEmpty
        ? item.fullPath.trim()
        : (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty)
        ? p.join(item.path.trim(), item.filename.trim())
        : '';
    return full.isNotEmpty ? browseFolderPathVideo(full) : '';
  }
  if (t == 'tv' || t == 'season' || t == 'episod') {
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return browseFolderPathVideo(full);
  }
  final base = item.path.trim();
  if (base.isNotEmpty) return browseFolderPathVideo(base);
  final full = item.fullPath.trim();
  return full.isNotEmpty ? browseFolderPathVideo(full) : '';
}

String resolveVideoDeletePath(VideoHomeItemBean item) {
  final t = item.mediaType.toLowerCase().trim();
  if (t == 'movie' || t == 'bdmv' || t == 'video_ts') {
    if (item.fullPath.trim().isNotEmpty) return item.fullPath.trim();
    if (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty) {
      return p.join(item.path.trim(), item.filename.trim());
    }
  }
  if (t == 'tv' || t == 'season') {
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
  }
  final base = item.path.trim();
  if (base.isNotEmpty) return base;
  return item.fullPath.trim();
}

String resolveVideoDownloadPath(VideoHomeItemBean item) {
  final t = item.mediaType.toLowerCase().trim();
  if (t == 'movie' || t == 'bdmv' || t == 'video_ts') {
    if (item.fullPath.trim().isNotEmpty) return item.fullPath.trim();
    if (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty) {
      return p.join(item.path.trim(), item.filename.trim());
    }
    return '';
  }

  if (t == 'tv' || t == 'season') {
    if (item.fullPath.trim().isNotEmpty) return item.fullPath.trim();
    if (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty) {
      return p.join(item.path.trim(), item.filename.trim());
    }
    return item.path.trim();
  }

  if (item.fullPath.trim().isNotEmpty) return item.fullPath.trim();
  if (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty) {
    return p.join(item.path.trim(), item.filename.trim());
  }
  return item.path.trim();
}
