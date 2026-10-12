import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'txt_speech_engine.dart';

class FlutterTtsSpeechEngine implements TxtSpeechEngine {
  FlutterTtsSpeechEngine({FlutterTts? flutterTts})
    : _flutterTts = flutterTts ?? FlutterTts();

  final FlutterTts _flutterTts;
  SpeechRateValidRange? _rateRange;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _flutterTts.awaitSpeakCompletion(true);
    try {
      _rateRange = await _flutterTts.getSpeechRateValidRange;
    } catch (_) {
      _rateRange = null;
    }
    _initialized = true;
  }

  @override
  Future<List<TxtSpeechVoice>> getVoices() async {
    await initialize();
    final raw = await _flutterTts.getVoices;
    if (raw is! Iterable) return const <TxtSpeechVoice>[];

    final result = <TxtSpeechVoice>[];
    for (final value in raw) {
      if (value is! Map) continue;
      final data = <String, String>{};
      for (final entry in value.entries) {
        if (entry.value != null) {
          data[entry.key.toString()] = entry.value.toString();
        }
      }
      final name =
          data['name'] ?? data['identifier'] ?? data['voice'] ?? 'Default';
      final locale = data['locale'] ?? data['language'] ?? '';
      result.add(TxtSpeechVoice(name: name, locale: locale, data: data));
    }
    result.sort((a, b) {
      final locale = a.locale.compareTo(b.locale);
      return locale != 0 ? locale : a.name.compareTo(b.name);
    });
    return result;
  }

  @override
  Future<int> getMaxInputLength() async {
    await initialize();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        return (await _flutterTts.getMaxSpeechInputLength) ?? 3900;
      } catch (_) {
        return 3900;
      }
    }
    return 3000;
  }

  @override
  Future<void> setRate(double rate) async {
    await initialize();
    final speed = rate.clamp(0.5, 2.0).toDouble();
    final range = _rateRange;
    final min = range?.min ?? 0.25;
    final normal = range?.normal ?? 0.5;
    final max = range?.max ?? 1.0;
    final mapped = speed <= 1.0
        ? min + ((speed - 0.5) / 0.5) * (normal - min)
        : normal + (speed - 1.0) * (max - normal);
    await _flutterTts.setSpeechRate(mapped.clamp(min, max).toDouble());
  }

  @override
  Future<void> setVoice(TxtSpeechVoice? voice) async {
    await initialize();
    if (voice == null) {
      await _flutterTts.clearVoice();
      return;
    }
    await _flutterTts.setVoice(voice.data);
  }

  @override
  Future<void> speak(String text) async {
    await initialize();
    await _flutterTts.speak(text, focus: false);
  }

  @override
  Future<void> pause() async {
    await _flutterTts.pause();
  }

  @override
  Future<void> stop() async {
    await _flutterTts.stop();
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}
