import 'dart:io';

import 'package:NasCabOS/modules/book/reader/model/local_tts_model_manifest.dart';
import 'package:NasCabOS/modules/book/reader/service/local_tts_model_store_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FileBundle extends CachingAssetBundle {
  int loads = 0;
  bool corrupt = false;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    if (corrupt) return ByteData(1);
    return ByteData.sublistView(await File(key).readAsBytes());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const storageChannel = MethodChannel('com.nascabos/storage');

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    support = await Directory.systemTemp.createTemp('bundled-tts-test-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => support.path);
    messenger.setMockMethodCallHandler(
      storageChannel,
      (_) async => 1024 * 1024 * 1024,
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(storageChannel, null);
    await support.delete(recursive: true);
  });

  test(
    'first use installs real bundled models offline and reuses installation',
    () async {
      final bundle = _FileBundle();
      final store = LocalTtsModelStore(bundle: bundle);
      addTearDown(store.dispose);
      final secondStore = LocalTtsModelStore(bundle: bundle);
      addTearDown(secondStore.dispose);
      await Future.wait([store.refresh(), secondStore.refresh()]);
      expect(
        secondStore.state.isReady,
        isTrue,
        reason: secondStore.state.message,
      );
      expect(store.state.isReady, isTrue, reason: store.state.message);
      final paths = await store.resolvePaths();
      expect(await File(paths.acousticModel).length(), greaterThan(0));
      expect(
        await File(paths.vocoder).length(),
        LocalTtsModelManifest.vocoder.length,
      );
      expect(bundle.loads, 2);
      await store.refresh();
      expect(bundle.loads, 2);
      expect(
        await Directory('${support.path}/tts_models/.bundled').exists(),
        isFalse,
      );
    },
  );

  test(
    'corrupted bundled asset fails verification and can be retried',
    () async {
      final bundle = _FileBundle()..corrupt = true;
      final store = LocalTtsModelStore(bundle: bundle);
      addTearDown(store.dispose);
      await store.refresh();
      expect(store.state.isReady, isFalse);
      expect(store.state.message, contains('invalid length'));
      expect(
        await Directory('${support.path}/tts_models/.bundled').exists(),
        isFalse,
      );
      bundle.corrupt = false;
      await store.installBundledModel();
      expect(store.state.isReady, isTrue, reason: store.state.message);
    },
  );
}
