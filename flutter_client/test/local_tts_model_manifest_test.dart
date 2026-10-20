import 'package:NasCabOS/modules/book/reader/model/local_tts_model_manifest.dart';
import 'package:NasCabOS/modules/book/reader/service/sherpa_onnx_speech_engine_io.dart';
import 'package:NasCabOS/modules/book/reader/service/txt_speech_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Matcha manifest uses verified acoustic and vocoder artifacts', () {
    expect(LocalTtsModelManifest.id, 'matcha-icefall-zh-baker-v1');
    expect(LocalTtsModelManifest.artifacts, hasLength(2));
    expect(LocalTtsModelManifest.acousticArchive.length, 75480460);
    expect(
      LocalTtsModelManifest.acousticArchive.sha256,
      'c3e1889c1b745180445daba6c1f51fb4aeceaff8500da425da6c5ff80e8620c5',
    );
    expect(LocalTtsModelManifest.vocoder.length, 53884024);
    expect(
      LocalTtsModelManifest.vocoder.sha256,
      '0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081',
    );
  });

  test('Matcha exposes its single Baker voice', () {
    final voices = LocalTtsModelManifest.voices;

    expect(voices, hasLength(1));
    expect(voices.single.sid, 0);
    expect(voices.single.locale, 'zh-CN');
    expect(voices.single.gender, 'female');
  });

  test('Matcha required files cover acoustic model and normalization', () {
    expect(
      LocalTtsModelManifest.requiredFiles,
      containsAll(<String>[
        'matcha-icefall-zh-baker/model-steps-3.onnx',
        'matcha-icefall-zh-baker/lexicon.txt',
        'matcha-icefall-zh-baker/tokens.txt',
        'matcha-icefall-zh-baker/phone.fst',
        'vocos-22khz-univ.onnx',
      ]),
    );
  });

  test('speech voice preserves the Matcha speaker ID', () {
    final voices = buildLocalTtsSpeechVoices();

    expect(voices, hasLength(1));
    expect(localTtsSpeakerIdForVoice(voices.single), 0);
    expect(voices.single.data['gender'], 'female');
  });

  test('invalid or missing voice selection falls back to Baker', () {
    const invalid = TxtSpeechVoice(
      name: 'invalid',
      locale: 'zh-CN',
      data: <String, String>{'sid': '999'},
    );

    expect(localTtsSpeakerIdForVoice(null), 0);
    expect(localTtsSpeakerIdForVoice(invalid), 0);
  });
}
