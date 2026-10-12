class TxtSpeechVoice {
  const TxtSpeechVoice({
    required this.name,
    required this.locale,
    required this.data,
  });

  final String name;
  final String locale;
  final Map<String, String> data;

  String get id => '$locale::$name';
}

abstract class TxtSpeechEngine {
  Future<void> initialize();

  Future<List<TxtSpeechVoice>> getVoices();

  Future<int> getMaxInputLength();

  Future<void> setRate(double rate);

  Future<void> setVoice(TxtSpeechVoice? voice);

  Future<void> speak(String text);

  Future<void> pause();

  Future<void> stop();

  Future<void> dispose();
}

abstract class TxtSpeechPrefetchEngine {
  Future<void> speakWithPrefetch(String text, String? nextText);
}
