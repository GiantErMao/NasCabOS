import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_read/flutter_read.dart';

import '../../../../core/audio/app_media_playback_coordinator.dart';
import '../../../../core/audio/app_media_playback_delegate.dart';
import '../../../../utils/cache_manager.dart';
import '../model/txt_speech_segment.dart';
import '../service/txt_speech_engine.dart';

enum TxtSpeechState { idle, loading, playing, paused, error, completed }

enum TxtSpeechBackend { system, localNeural }

class TxtSpeechController extends ChangeNotifier {
  TxtSpeechController({
    required this.readController,
    required this.engine,
    this.localEngine,
    required this.bookTitle,
    this.preferredLocale,
    AppMediaPlaybackCoordinator? mediaCoordinator,
  }) : _mediaCoordinator =
           mediaCoordinator ?? AppMediaPlaybackCoordinator.instance {
    _activeEngine = engine;
    _mediaDelegate = _TxtSpeechMediaDelegate(this);
  }

  static const String mediaOwnerId = 'txt_speech';
  static const String _rateCacheKey = 'txt_speech_rate';
  static const String _legacyVoiceCacheKey = 'txt_speech_voice';
  static const String _backendCacheKey = 'txt_speech_backend';

  final ReadController readController;
  final TxtSpeechEngine engine;
  final TxtSpeechEngine? localEngine;
  final String bookTitle;
  final String? preferredLocale;
  final AppMediaPlaybackCoordinator _mediaCoordinator;

  late final _TxtSpeechMediaDelegate _mediaDelegate;
  final List<TxtSpeechSegment> _history = <TxtSpeechSegment>[];

  TxtSpeechState _state = TxtSpeechState.idle;
  TxtSpeechSegment? _currentSegment;
  List<TxtSpeechVoice> _voices = const <TxtSpeechVoice>[];
  TxtSpeechVoice? _selectedVoice;
  String? _errorMessage;
  double _rate = 1.0;
  int _maxInputLength = 3000;
  int _generation = 0;
  late TxtSpeechEngine _activeEngine;
  TxtSpeechBackend _backend = TxtSpeechBackend.system;
  final Set<TxtSpeechEngine> _initializedEngines = <TxtSpeechEngine>{};
  bool _initialized = false;
  bool _closed = false;
  bool _resumeAfterInterruption = false;
  Future<void> _interruptionQueue = Future<void>.value();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  TxtSpeechState get state => _state;
  TxtSpeechSegment? get currentSegment => _currentSegment;
  List<TxtSpeechVoice> get voices => _voices;
  TxtSpeechVoice? get selectedVoice => _selectedVoice;
  String? get errorMessage => _errorMessage;
  double get rate => _rate;
  TxtSpeechBackend get backend => _backend;
  bool get hasLocalBackend => localEngine != null;
  bool get isPlaying => _state == TxtSpeechState.playing;
  bool get isPaused => _state == TxtSpeechState.paused;
  bool get hasActiveSpeech =>
      _state == TxtSpeechState.playing ||
      _state == TxtSpeechState.paused ||
      _state == TxtSpeechState.loading;

  Future<void> initialize() async {
    if (_initialized || _closed) return;
    _setState(TxtSpeechState.loading);
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final session = await AudioSession.instance;
        _interruptionSubscription = session.interruptionEventStream.listen((
          event,
        ) {
          unawaited(handleAudioInterruption(event));
        });
        _becomingNoisySubscription = session.becomingNoisyEventStream.listen((
          _,
        ) {
          if (isPlaying) unawaited(pause());
        });
      }
      _rate = (CacheManager().getDouble(_rateCacheKey) ?? 1.0)
          .clamp(0.5, 2.0)
          .toDouble();
      final savedBackend = CacheManager().getString(_backendCacheKey);
      if (savedBackend == TxtSpeechBackend.localNeural.name &&
          localEngine != null) {
        try {
          await _activateEngine(TxtSpeechBackend.localNeural, localEngine!);
        } catch (_) {
          await CacheManager().remove(_backendCacheKey);
          await _activateEngine(TxtSpeechBackend.system, engine);
        }
      } else {
        await _activateEngine(TxtSpeechBackend.system, engine);
      }
      _initialized = true;
      _setState(TxtSpeechState.idle);
    } catch (error) {
      _setError(error);
      rethrow;
    }
  }

  Future<void> startAt(ChapterData location) async {
    if (_closed) return;
    _resumeAfterInterruption = false;
    try {
      await initialize();
      _generation++;
      await _activeEngine.stop();
      final segment = _findSegmentAtOrAfter(location);
      if (segment == null) {
        _currentSegment = null;
        _history.clear();
        _setState(TxtSpeechState.completed);
        await _mediaCoordinator.release(mediaOwnerId);
        return;
      }

      _history.clear();
      _currentSegment = segment;
      _errorMessage = null;
      _mediaCoordinator.registerDelegate(_mediaDelegate);
      await _mediaCoordinator.activate(mediaOwnerId);
      await _activateSpeechSession();
      await _speakCurrent();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> play() async {
    if (_closed) return;
    _resumeAfterInterruption = false;
    final segment = _currentSegment;
    if (segment == null) return;
    try {
      await initialize();
      _mediaCoordinator.registerDelegate(_mediaDelegate);
      await _mediaCoordinator.activate(mediaOwnerId);
      await _activateSpeechSession();
      _generation++;
      await _speakCurrent();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> pause() async {
    _resumeAfterInterruption = false;
    if (_state != TxtSpeechState.playing) return;
    _generation++;
    try {
      await _activeEngine.pause();
      _setState(TxtSpeechState.paused);
      _publishMediaState();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> stop() async {
    if (_closed && !_initialized) return;
    _resumeAfterInterruption = false;
    _generation++;
    try {
      if (_initialized) await _activeEngine.stop();
    } finally {
      _currentSegment = null;
      _history.clear();
      _setState(TxtSpeechState.idle);
      await _mediaCoordinator.release(mediaOwnerId);
    }
  }

  Future<void> previousSegment() async {
    if (_currentSegment == null) return;
    _resumeAfterInterruption = false;
    _generation++;
    await _activeEngine.stop();
    if (_history.isNotEmpty) {
      _currentSegment = _history.removeLast();
    }
    await _speakCurrent();
  }

  Future<void> nextSegment() async {
    final current = _currentSegment;
    if (current == null) return;
    _resumeAfterInterruption = false;
    _generation++;
    await _activeEngine.stop();
    final next = _findNextSegment(current);
    if (next == null) {
      await _complete();
      return;
    }
    _history.add(current);
    _currentSegment = next;
    await _speakCurrent();
  }

  Future<void> setRate(double value) async {
    final next = value.clamp(0.5, 2.0).toDouble();
    await initialize();
    await _activeEngine.setRate(next);
    _rate = next;
    await CacheManager().setDouble(_rateCacheKey, next);
    notifyListeners();
    if (isPlaying) {
      _generation++;
      await _activeEngine.stop();
      await _speakCurrent();
    }
  }

  Future<void> setVoice(TxtSpeechVoice? voice) async {
    await initialize();
    await _activeEngine.setVoice(voice);
    _selectedVoice = voice;
    final voiceCacheKey = _voiceCacheKey(_backend);
    if (voice == null) {
      await CacheManager().remove(voiceCacheKey);
    } else {
      await CacheManager().setString(voiceCacheKey, voice.id);
    }
    notifyListeners();
    if (isPlaying) {
      _generation++;
      await _activeEngine.stop();
      await _speakCurrent();
    }
  }

  Future<void> switchBackend(TxtSpeechBackend backend) async {
    if (_closed || backend == _backend) return;
    _resumeAfterInterruption = false;
    final target = backend == TxtSpeechBackend.system ? engine : localEngine;
    if (target == null) {
      throw StateError('The requested speech backend is unavailable');
    }
    _generation++;
    await _activeEngine.stop();
    await _mediaCoordinator.release(mediaOwnerId);
    try {
      await _activateEngine(backend, target);
      _errorMessage = null;
      await CacheManager().setString(_backendCacheKey, backend.name);
      _setState(
        _currentSegment == null ? TxtSpeechState.idle : TxtSpeechState.paused,
      );
    } catch (error) {
      _errorMessage = error.toString();
      _setState(TxtSpeechState.error);
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await stop();
    _closed = true;
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await engine.dispose();
    if (localEngine != null && !identical(localEngine, engine)) {
      await localEngine!.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  Future<void> _speakCurrent() async {
    final segment = _currentSegment;
    if (segment == null || _closed) return;
    final generation = ++_generation;
    _setState(TxtSpeechState.playing);
    _publishMediaItem();
    _publishMediaState();
    try {
      final next = _findNextSegment(segment);
      final engine = _activeEngine;
      if (engine is TxtSpeechPrefetchEngine) {
        await (engine as TxtSpeechPrefetchEngine).speakWithPrefetch(
          segment.text,
          next?.text,
        );
      } else {
        await engine.speak(segment.text);
      }
      if (_closed ||
          generation != _generation ||
          _state != TxtSpeechState.playing) {
        return;
      }
      if (next == null) {
        await _complete();
        return;
      }
      _history.add(segment);
      _currentSegment = next;
      await _speakCurrent();
    } catch (error) {
      if (generation == _generation) _setError(error);
    }
  }

  Future<void> _complete() async {
    _generation++;
    _currentSegment = null;
    _setState(TxtSpeechState.completed);
    _publishMediaState();
    await _mediaCoordinator.release(mediaOwnerId);
  }

  Future<void> _stopForOwnerSwitch() async {
    _resumeAfterInterruption = false;
    _generation++;
    if (_initialized) await _activeEngine.stop();
    _currentSegment = null;
    _history.clear();
    _setState(TxtSpeechState.idle);
  }

  Future<void> _activateSpeechSession() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    await session.setActive(true);
  }

  @visibleForTesting
  Future<void> handleAudioInterruption(AudioInterruptionEvent event) {
    final task = _interruptionQueue.then(
      (_) => _handleAudioInterruption(event),
    );
    _interruptionQueue = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return task;
  }

  Future<void> _handleAudioInterruption(AudioInterruptionEvent event) async {
    if (_closed) return;
    if (event.begin) {
      if (!isPlaying) return;
      _resumeAfterInterruption = event.type != AudioInterruptionType.unknown;
      _generation++;
      try {
        await _activeEngine.pause();
        _setState(TxtSpeechState.paused);
        _publishMediaState();
      } catch (error) {
        _resumeAfterInterruption = false;
        _setError(error);
      }
      return;
    }

    final shouldResume =
        _resumeAfterInterruption &&
        event.type != AudioInterruptionType.unknown &&
        _state == TxtSpeechState.paused &&
        _currentSegment != null;
    _resumeAfterInterruption = false;
    if (shouldResume) {
      unawaited(play());
    }
  }

  TxtSpeechVoice? _resolveInitialVoice(String? savedId) {
    if (_voices.isEmpty) return null;
    if (savedId != null) {
      for (final voice in _voices) {
        if (voice.id == savedId) return voice;
      }
    }
    final locale = preferredLocale?.replaceAll('_', '-').toLowerCase();
    if (locale != null && locale.isNotEmpty) {
      for (final voice in _voices) {
        if (voice.locale
            .replaceAll('_', '-')
            .toLowerCase()
            .startsWith(locale.split('-').first)) {
          return voice;
        }
      }
    }
    return null;
  }

  Future<void> _activateEngine(
    TxtSpeechBackend backend,
    TxtSpeechEngine target,
  ) async {
    if (!_initializedEngines.contains(target)) {
      await target.initialize();
      _initializedEngines.add(target);
    }
    _activeEngine = target;
    _backend = backend;
    _maxInputLength = (await target.getMaxInputLength()).clamp(100, 100000);
    _voices = await target.getVoices();
    await target.setRate(_rate);
    final savedVoice =
        CacheManager().getString(_voiceCacheKey(backend)) ??
        (backend == TxtSpeechBackend.system
            ? CacheManager().getString(_legacyVoiceCacheKey)
            : null);
    _selectedVoice = _resolveInitialVoice(savedVoice);
    await target.setVoice(_selectedVoice);
  }

  String _voiceCacheKey(TxtSpeechBackend backend) =>
      'txt_speech_voice:${backend == TxtSpeechBackend.system ? 'system' : 'local_neural'}';

  TxtSpeechSegment? _findSegmentAtOrAfter(ChapterData location) {
    final chapterCount = readController.getChapterNum();
    for (
      var chapterIndex = location.chapterIndex.clamp(0, chapterCount);
      chapterIndex < chapterCount;
      chapterIndex++
    ) {
      final sentences = readController.getSentenceFromIndex(chapterIndex);
      if (sentences == null) continue;
      for (final sentence in sentences) {
        if (chapterIndex == location.chapterIndex &&
            sentence.index < location.sentenceIndex) {
          continue;
        }
        final start =
            chapterIndex == location.chapterIndex &&
                sentence.index == location.sentenceIndex
            ? location.wordIndex
            : 0;
        final segments = _splitSentence(chapterIndex, sentence, start);
        if (segments.isNotEmpty) return segments.first;
      }
    }
    return null;
  }

  TxtSpeechSegment? _findNextSegment(TxtSpeechSegment current) {
    final sameSentence = readController
        .getSentenceFromIndex(current.chapterIndex)
        ?.where((sentence) => sentence.index == current.sentenceIndex)
        .firstOrNull;
    if (sameSentence != null) {
      final remaining = _splitSentence(
        current.chapterIndex,
        sameSentence,
        current.endWordIndex,
      );
      if (remaining.isNotEmpty) return remaining.first;
    }
    return _findSegmentAtOrAfter(
      ChapterData(
        chapterIndex: current.chapterIndex,
        sentenceIndex: current.sentenceIndex + 1,
      ),
    );
  }

  List<TxtSpeechSegment> _splitSentence(
    int chapterIndex,
    BookSentence sentence,
    int requestedStart,
  ) {
    final text = sentence.toString();
    if (text.isEmpty) return const <TxtSpeechSegment>[];
    var start = requestedStart.clamp(0, text.length);
    final result = <TxtSpeechSegment>[];
    while (start < text.length) {
      while (start < text.length && text[start].trim().isEmpty) {
        start++;
      }
      if (start >= text.length) break;
      var end = (start + _maxInputLength).clamp(start + 1, text.length);
      if (end < text.length) {
        final preferred = _findPreferredSplit(text, start, end);
        if (preferred > start) end = preferred;
      }
      var speechEnd = end;
      while (speechEnd > start && text[speechEnd - 1].trim().isEmpty) {
        speechEnd--;
      }
      if (speechEnd > start) {
        result.add(
          TxtSpeechSegment(
            chapterIndex: chapterIndex,
            sentenceIndex: sentence.index,
            startWordIndex: start,
            endWordIndex: end,
            text: text.substring(start, speechEnd),
          ),
        );
      }
      start = end;
    }
    return result;
  }

  int _findPreferredSplit(String text, int start, int end) {
    final minimum = start + ((end - start) ~/ 2);
    const punctuation = '。！？；.!?;，,、:\\n';
    for (var index = end - 1; index >= minimum; index--) {
      if (punctuation.contains(text[index])) return index + 1;
    }
    return end;
  }

  void _publishMediaItem() {
    final segment = _currentSegment;
    if (segment == null) return;
    _mediaCoordinator.publishMediaItem(
      mediaOwnerId,
      MediaItem(
        id: 'txt://${segment.chapterIndex}/${segment.sentenceIndex}/${segment.startWordIndex}',
        title: bookTitle,
        artist: 'TXT',
      ),
    );
  }

  void _publishMediaState() {
    final playing = _state == TxtSpeechState.playing;
    _mediaCoordinator.publishPlaybackState(
      mediaOwnerId,
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: _state == TxtSpeechState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
        playing: playing,
        speed: _rate,
        systemActions: const <MediaAction>{
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
      ),
    );
  }

  void _setState(TxtSpeechState value) {
    _state = value;
    if (!_closed) notifyListeners();
  }

  void _setError(Object error) {
    _generation++;
    _errorMessage = error.toString();
    _currentSegment = null;
    _history.clear();
    _setState(TxtSpeechState.error);
    _publishMediaState();
    unawaited(_mediaCoordinator.release(mediaOwnerId));
  }
}

class _TxtSpeechMediaDelegate extends AppMediaPlaybackDelegate {
  _TxtSpeechMediaDelegate(this.controller);

  final TxtSpeechController controller;

  @override
  String get ownerId => TxtSpeechController.mediaOwnerId;

  @override
  Future<void> play() => controller.play();

  @override
  Future<void> pause() => controller.pause();

  @override
  Future<void> stop() => controller.stop();

  @override
  Future<void> skipToNext() => controller.nextSegment();

  @override
  Future<void> skipToPrevious() => controller.previousSegment();

  @override
  Future<void> onActivated() async {
    await controller._activateSpeechSession();
    controller._publishMediaItem();
    controller._publishMediaState();
  }

  @override
  Future<void> onDeactivated(String? nextOwnerId) {
    return controller._stopForOwnerSwitch();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button != MediaButton.media) return;
    if (controller.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }
}
