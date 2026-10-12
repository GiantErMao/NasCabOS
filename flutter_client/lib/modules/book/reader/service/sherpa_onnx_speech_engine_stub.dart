import 'local_tts_model_store.dart';
import 'txt_speech_engine.dart';

class SherpaOnnxSpeechEngine implements TxtSpeechEngine {
  SherpaOnnxSpeechEngine({required LocalTtsModelStoreBase modelStore});

  Never _unsupported() =>
      throw UnsupportedError('Local neural TTS is available on Android only');

  @override
  Future<void> dispose() async {}

  @override
  Future<int> getMaxInputLength() async => 180;

  @override
  Future<List<TxtSpeechVoice>> getVoices() async => _unsupported();

  @override
  Future<void> initialize() async => _unsupported();

  @override
  Future<void> pause() async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVoice(TxtSpeechVoice? voice) async {}

  @override
  Future<void> speak(String text) async => _unsupported();

  @override
  Future<void> stop() async {}
}
