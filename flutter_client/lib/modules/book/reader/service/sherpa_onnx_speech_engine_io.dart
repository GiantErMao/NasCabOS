import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/local_tts_model_manifest.dart';
import 'local_tts_model_store.dart';
import 'local_tts_worker.dart';
import 'txt_speech_engine.dart';

List<TxtSpeechVoice> buildLocalTtsSpeechVoices() {
  return LocalTtsModelManifest.voices
      .map(
        (voice) => TxtSpeechVoice(
          name: voice.name,
          locale: voice.locale,
          data: <String, String>{
            'id': '${LocalTtsModelManifest.id}-${voice.sid}',
            'sid': voice.sid.toString(),
            'gender': voice.gender,
          },
        ),
      )
      .toList(growable: false);
}

int localTtsSpeakerIdForVoice(TxtSpeechVoice? voice) {
  final sid = int.tryParse(voice?.data['sid'] ?? '');
  if (sid == null) return LocalTtsModelManifest.voices.first.sid;
  final exists = LocalTtsModelManifest.voices.any(
    (preset) => preset.sid == sid,
  );
  return exists ? sid : LocalTtsModelManifest.voices.first.sid;
}

class SherpaOnnxSpeechEngine
    implements TxtSpeechEngine, TxtSpeechPrefetchEngine {
  SherpaOnnxSpeechEngine({required this.modelStore});

  final LocalTtsModelStoreBase modelStore;
  final AudioPlayer _player = AudioPlayer();
  LocalTtsWorker? _worker;
  Directory? _cacheDirectory;
  File? _currentWav;
  String? _prefetchText;
  Future<File?>? _prefetchFuture;
  final Set<int> _activeRequestIds = <int>{};
  double _rate = 1;
  int _speakerId = LocalTtsModelManifest.voices.first.sid;
  int _generation = 0;
  int _requestId = 0;
  int _synthesisEpoch = 0;
  bool _initialized = false;
  bool _disposed = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    if (_disposed) throw StateError('Local TTS engine is disposed');
    await modelStore.refresh();
    if (!modelStore.state.isReady) {
      throw StateError('Local neural TTS model is not installed');
    }
    final paths = await modelStore.resolvePaths();
    final worker = LocalTtsWorker();
    final stopwatch = Stopwatch()..start();
    try {
      await worker.initialize(paths);
    } catch (_) {
      await worker.dispose();
      rethrow;
    }
    stopwatch.stop();
    final cacheRoot = await getTemporaryDirectory();
    _cacheDirectory = Directory(p.join(cacheRoot.path, 'local_tts_wav'));
    await _cacheDirectory!.create(recursive: true);
    await _clearTemporaryWavs();
    _worker = worker;
    _initialized = true;
    debugPrint('[local_tts] initialized_ms=${stopwatch.elapsedMilliseconds}');
  }

  @override
  Future<List<TxtSpeechVoice>> getVoices() async {
    await initialize();
    return buildLocalTtsSpeechVoices();
  }

  @override
  Future<int> getMaxInputLength() async => 180;

  @override
  Future<void> setRate(double rate) async {
    final next = rate.clamp(0.5, 2.0).toDouble();
    if (next == _rate) return;
    _invalidatePrefetch();
    _rate = next;
  }

  @override
  Future<void> setVoice(TxtSpeechVoice? voice) async {
    final next = localTtsSpeakerIdForVoice(voice);
    if (next == _speakerId) return;
    _invalidatePrefetch();
    _speakerId = next;
  }

  @override
  Future<void> speak(String text) => speakWithPrefetch(text, null);

  @override
  Future<void> speakWithPrefetch(String text, String? nextText) async {
    await initialize();
    final generation = ++_generation;
    await _player.stop();
    await _deleteCurrentWav();
    if (_prefetchText != null && _prefetchText != text) {
      _invalidatePrefetch();
    }
    final epoch = _synthesisEpoch;
    final wav = await _takeOrSynthesize(text, epoch);
    if (wav == null || _disposed || epoch != _synthesisEpoch) return;
    _currentWav = wav;
    if (_disposed || generation != _generation) {
      if (await wav.exists()) await wav.delete();
      return;
    }
    await _player.setFilePath(wav.path);
    if (_disposed || generation != _generation) return;
    final playback = _player.play();
    final normalizedNext = nextText?.trim();
    if (normalizedNext != null && normalizedNext.isNotEmpty) {
      _startPrefetch(normalizedNext, epoch);
    }
    await playback;
    if (generation == _generation) await _deleteCurrentWav();
  }

  @override
  Future<void> pause() async {
    final cancelled = _generation++;
    _cancelSynthesis(cancelled);
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    final cancelled = _generation++;
    _cancelSynthesis(cancelled);
    await _player.stop();
    await _deleteCurrentWav();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _player.dispose();
    await _worker?.dispose();
    _worker = null;
    await _clearTemporaryWavs();
  }

  Future<File?> _takeOrSynthesize(String text, int epoch) async {
    final prefetched = _prefetchText == text ? _prefetchFuture : null;
    if (prefetched != null) {
      _prefetchText = null;
      _prefetchFuture = null;
      final file = await prefetched;
      if (file != null) return file;
    }
    return _synthesize(text, epoch, prefetched: false);
  }

  void _startPrefetch(String text, int epoch) {
    if (_disposed || epoch != _synthesisEpoch) return;
    if (_prefetchText == text && _prefetchFuture != null) return;
    _invalidatePrefetch();
    final nextEpoch = _synthesisEpoch;
    _prefetchText = text;
    _prefetchFuture = _synthesizeSafely(text, nextEpoch);
  }

  Future<File?> _synthesizeSafely(String text, int epoch) async {
    try {
      return await _synthesize(text, epoch, prefetched: true);
    } catch (error) {
      debugPrint('[local_tts] prefetch_failed=$error');
      return null;
    }
  }

  Future<File?> _synthesize(
    String text,
    int epoch, {
    required bool prefetched,
  }) async {
    final worker = _worker!;
    final requestId = ++_requestId;
    _activeRequestIds.add(requestId);
    final wav = File(
      p.join(
        _cacheDirectory!.path,
        'segment-$requestId-${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    try {
      final result = await worker.synthesize(
        generation: requestId,
        text: text,
        speed: _rate,
        speakerId: _speakerId,
        wavPath: wav.path,
      );
      if (_disposed || epoch != _synthesisEpoch) {
        if (await wav.exists()) await wav.delete();
        return null;
      }
      debugPrint(
        '[local_tts] kind=${prefetched ? 'prefetch' : 'foreground'} '
        'chars=${text.length} '
        'synthesis_ms=${(result.elapsedSeconds * 1000).round()} '
        'audio_s=${result.durationSeconds.toStringAsFixed(2)} '
        'rtf=${result.rtf.toStringAsFixed(3)}',
      );
      return wav;
    } finally {
      _activeRequestIds.remove(requestId);
    }
  }

  void _cancelSynthesis(int generation) {
    _synthesisEpoch++;
    for (final requestId in _activeRequestIds) {
      _worker?.cancel(requestId);
    }
    _worker?.cancel(generation);
    _invalidatePrefetch(incrementEpoch: false);
  }

  void _invalidatePrefetch({bool incrementEpoch = true}) {
    if (incrementEpoch) _synthesisEpoch++;
    _prefetchText = null;
    _prefetchFuture = null;
  }

  Future<void> _deleteCurrentWav() async {
    final wav = _currentWav;
    _currentWav = null;
    if (wav != null && await wav.exists()) {
      try {
        await wav.delete();
      } catch (_) {}
    }
  }

  Future<void> _clearTemporaryWavs() async {
    final directory = _cacheDirectory;
    if (directory == null || !await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && p.extension(entity.path) == '.wav') {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
