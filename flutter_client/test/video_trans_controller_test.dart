import 'package:NasCabOS/core/api/base_api_service.dart';
import 'package:NasCabOS/modules/mediaTool/video_trans/controller/video_trans_controller.dart';
import 'package:NasCabOS/modules/mediaTool/video_trans/service/video_trans_api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class RecordingVideoApi extends VideoTransApiService {
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<ApiResponse<Map<String, dynamic>>> upsert({
    int? id,
    required String sourcePath,
    required String targetPath,
    required Map<String, dynamic> transConfig,
    required String nonVideoPolicy,
  }) async {
    requests.add({
      'id': id,
      'source_path': sourcePath,
      'target_path': targetPath,
      'trans_config': transConfig,
    });
    return ApiResponse.success({'id': id ?? 1});
  }

  @override
  Future<ApiResponse<Map<String, dynamic>>> list({int page = 1}) async {
    return ApiResponse.success({'items': <Map<String, dynamic>>[]});
  }
}

void main() {
  Future<void> prepare(WidgetTester tester) async {
    await tester.pumpWidget(GetMaterialApp(home: const Scaffold()));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    Get.reset();
  }

  testWidgets('replacement with no output directory reaches the API', (
    tester,
  ) async {
    await prepare(tester);
    final api = RecordingVideoApi();
    final controller = VideoTransController(api: api);
    final saved = await controller.upsert(
      sourcePath: ' /media/video.mp4 ',
      targetPath: '',
      transConfig: {'replace_source': true, 'out_format': 'source'},
      nonVideoPolicy: 'skip',
    );
    expect(saved, isTrue);
    expect(api.requests, hasLength(1));
    expect(api.requests.single['source_path'], '/media/video.mp4');
    expect(api.requests.single['target_path'], '');
    await finish(tester);
  });

  testWidgets('replacement edits discard any hidden output directory', (
    tester,
  ) async {
    await prepare(tester);
    final api = RecordingVideoApi();
    final saved = await VideoTransController(api: api).upsert(
      id: 42,
      sourcePath: '/media/video.mp4',
      targetPath: '/old-output',
      transConfig: {'replace_source': true},
      nonVideoPolicy: 'skip',
    );
    expect(saved, isTrue);
    expect(api.requests.single['id'], 42);
    expect(api.requests.single['target_path'], '');
    await finish(tester);
  });

  testWidgets('ordinary conversion still requires an output directory', (
    tester,
  ) async {
    await prepare(tester);
    final api = RecordingVideoApi();
    final controller = VideoTransController(api: api);
    expect(
      await controller.upsert(
        sourcePath: '/media/video.mp4',
        targetPath: ' ',
        transConfig: {'replace_source': false},
        nonVideoPolicy: 'skip',
      ),
      isFalse,
    );
    expect(api.requests, isEmpty);
    expect(
      await controller.upsert(
        sourcePath: '/media/video.mp4',
        targetPath: ' /output ',
        transConfig: {},
        nonVideoPolicy: 'skip',
      ),
      isTrue,
    );
    expect(api.requests.single['target_path'], '/output');
    await finish(tester);
  });

  testWidgets('replacement still rejects an empty source', (tester) async {
    await prepare(tester);
    final api = RecordingVideoApi();
    expect(
      await VideoTransController(api: api).upsert(
        sourcePath: ' ',
        targetPath: '',
        transConfig: {'replace_source': true},
        nonVideoPolicy: 'skip',
      ),
      isFalse,
    );
    expect(api.requests, isEmpty);
    await finish(tester);
  });
}
