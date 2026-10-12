import 'package:NasCabOS/modules/book/reader/service/local_tts_feature_flag.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('local neural TTS is available by default on Android', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    expect(localTtsAvailable, isTrue);
  });

  test('local neural TTS remains unavailable on unsupported platforms', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    expect(localTtsAvailable, isFalse);
  });
}
