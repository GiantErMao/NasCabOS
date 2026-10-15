import 'package:NasCabOS/core/api/api_controller.dart';
import 'package:NasCabOS/modules/video/detail/controller/video_detail_controller.dart';
import 'package:NasCabOS/modules/video/detail/view/parts/app_video_detail_top_section.dart';
import 'package:NasCabOS/modules/video/list/service/video_list_api_service.dart';
import 'package:NasCabOS/modules/video/list/view/app_video_metadata_videos_page.dart';
import 'package:NasCabOS/modules/video/video_main/controller/video_main_controller.dart';
import 'package:NasCabOS/utils/cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QuietApiController extends ApiController {
  @override
  // Keep connectivity and authentication timers out of widget tests.
  // ignore: must_call_super
  void onInit() {}
}

class RecordingListApi extends VideoListApiService {
  final requests = <Map<String, dynamic>>[];

  @override
  Future<VideoListPagedResult> listPaged({
    required int page,
    required int pageSize,
    String? listType,
    String? mediaType,
    int? albumId,
    int? collectionId,
    int? smartAlbumId,
    String? search,
    List<String>? genres,
    List<String>? regions,
    List<String>? actors,
    List<String>? directors,
    List<int>? years,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
    bool showLoading = false,
  }) async {
    requests.add({
      'mediaType': mediaType,
      'genres': genres,
      'regions': regions,
    });
    return const VideoListPagedResult.empty();
  }
}

void main() {
  for (final value in ['中文字幕', '破解版本', '日本']) {
    testWidgets(
      'mobile detail $value opens a filtered list and returns to detail',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await CacheManager().init();
        Get.put<ApiController>(QuietApiController());
        final api = RecordingListApi();
        Get.put<VideoListApiService>(api);
        final ctrl = VideoDetailController();
        ctrl.raw.value = {
          'item': {
            'media_type': 'movie',
            'nfo_name': 'Test movie',
            'nfo_genres': '中文字幕,破解版本',
            'nfo_regions': '日本',
          },
        };
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 460,
                child: AppVideoDetailTopSection(ctrl: ctrl),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(Get.isRegistered<VideoMainController>(), isFalse);
        await tester.tap(find.text(value));
        await tester.pumpAndSettle();
        expect(find.byType(AppVideoMetadataVideosPage), findsOneWidget);
        expect(api.requests, isNotEmpty);
        expect(api.requests.last['mediaType'], 'movie');
        expect(api.requests.last[value == '日本' ? 'regions' : 'genres'], [
          value,
        ]);
        Get.back<void>();
        await tester.pumpAndSettle();
        expect(find.text('Test movie'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        Get.reset();
      },
    );
  }
}
