import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../base/views/app_video_list_scaffold.dart';
import '../controller/video_list_controller.dart';

/// Mobile metadata links open their own list without a desktop overlay host.
class AppVideoMetadataVideosPage extends StatelessWidget {
  final String value;
  final String mediaType;
  final bool isRegion;

  const AppVideoMetadataVideosPage.genre({
    super.key,
    required this.value,
    this.mediaType = '',
  }) : isRegion = false;

  const AppVideoMetadataVideosPage.region({
    super.key,
    required this.value,
    this.mediaType = '',
  }) : isRegion = true;

  @override
  Widget build(BuildContext context) {
    final label =
        (isRegion ? 'video_detail_regions' : 'video_detail_genres').tr;
    final filterValue = value.trim();
    return AppVideoListScaffold(
      title: '$label-$filterValue',
      controllerTagSeed:
          'metadata_${isRegion ? 'region' : 'genre'}_${mediaType}_$filterValue',
      controllerBuilder: () => VideoListController(
        initialMediaType: mediaType,
        initialGenres: isRegion ? const [] : [filterValue],
        initialRegions: isRegion ? [filterValue] : const [],
      ),
    );
  }
}
