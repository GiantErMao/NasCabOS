import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:NasCabOS/core/audio/app_media_playback_coordinator.dart';
import 'package:NasCabOS/core/audio/app_media_playback_delegate.dart';
import 'package:NasCabOS/modules/book/reader/controller/txt_speech_controller.dart';
import 'package:NasCabOS/modules/book/reader/service/txt_speech_engine.dart';
import 'package:NasCabOS/utils/cache_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CacheManager().init();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('starts at the requested stable text location', () async {
    final engine = _FakeSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['abcdef'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(
      controller.startAt(
        ChapterData(chapterIndex: 0, sentenceIndex: 0, wordIndex: 2),
      ),
    );
    await _flush();

    expect(engine.spoken, <String>['cdef']);
    expect(controller.currentSegment?.startWordIndex, 2);
    await controller.close();
  });

  test('advances across sentences and chapters', () async {
    final engine = _FakeSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['first', 'second'],
        <String>['third'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();
    engine.completeCurrent();
    await _flush();
    engine.completeCurrent();
    await _flush();

    expect(engine.spoken, <String>['first', 'second', 'third']);
    expect(controller.currentSegment?.chapterIndex, 1);
    await controller.close();
  });

  test('prefetch engine receives the next segment while playing', () async {
    final engine = _FakePrefetchSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['first', 'second', 'third'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();

    expect(engine.spoken, <String>['first']);
    expect(engine.prefetched, <String?>['second']);

    engine.completeCurrent();
    await _flush();

    expect(engine.spoken, <String>['first', 'second']);
    expect(engine.prefetched, <String?>['second', 'third']);
    await controller.close();
  });

  test('skips blank text and splits long sentences', () async {
    final engine = _FakeSpeechEngine(maxInputLength: 100);
    final longText =
        '${List<String>.filled(70, 'a').join()}。'
        '${List<String>.filled(70, 'b').join()}';
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['   ', longText],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();
    expect(engine.spoken.single.length, lessThanOrEqualTo(100));
    expect(controller.currentSegment?.sentenceIndex, 1);

    engine.completeCurrent();
    await _flush();
    expect(engine.spoken.length, 2);
    expect(engine.spoken.last.length, lessThanOrEqualTo(100));
    await controller.close();
  });

  test('stop ignores a late completion callback', () async {
    final engine = _FakeSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['first', 'second'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();
    await controller.stop();
    await _flush();

    expect(engine.spoken, <String>['first']);
    expect(controller.state, TxtSpeechState.idle);
    expect(controller.currentSegment, isNull);
    await controller.close();
  });

  test('persists rate and voice selection', () async {
    final voice = const TxtSpeechVoice(
      name: 'Test',
      locale: 'en-US',
      data: <String, String>{'name': 'Test', 'locale': 'en-US'},
    );
    final engine = _FakeSpeechEngine(voices: <TxtSpeechVoice>[voice]);
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['text'],
      ]),
      engine: engine,
      bookTitle: 'Book',
      preferredLocale: 'en-US',
    );

    await controller.initialize();
    await controller.setRate(1.5);
    await controller.setVoice(voice);

    expect(engine.rate, 1.5);
    expect(engine.voice, voice);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('txt_speech_rate'), 1.5);
    expect(prefs.getString('txt_speech_voice:system'), voice.id);
    await controller.close();
  });

  test(
    'switches backend without resuming and preserves text position',
    () async {
      final system = _FakeSpeechEngine();
      final local = _FakeSpeechEngine(maxInputLength: 180);
      final controller = TxtSpeechController(
        readController: _FakeReadController(<List<String>>[
          <String>['first', 'second'],
        ]),
        engine: system,
        localEngine: local,
        bookTitle: 'Book',
      );

      unawaited(controller.startAt(ChapterData()));
      await _flush();
      final location = controller.currentSegment?.location;

      await controller.switchBackend(TxtSpeechBackend.localNeural);

      expect(controller.backend, TxtSpeechBackend.localNeural);
      expect(controller.state, TxtSpeechState.paused);
      expect(
        controller.currentSegment?.location.chapterIndex,
        location?.chapterIndex,
      );
      expect(
        controller.currentSegment?.location.sentenceIndex,
        location?.sentenceIndex,
      );
      expect(
        controller.currentSegment?.location.wordIndex,
        location?.wordIndex,
      );
      expect(local.spoken, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('txt_speech_backend'),
        TxtSpeechBackend.localNeural.name,
      );
      await controller.close();
    },
  );

  test('resumes speech after a transient audio interruption', () async {
    final engine = _FakeSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['first'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();
    await controller.handleAudioInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );

    expect(controller.state, TxtSpeechState.paused);
    expect(engine.spoken, <String>['first']);

    await controller.handleAudioInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await _flush();

    expect(controller.state, TxtSpeechState.playing);
    expect(engine.spoken, <String>['first', 'first']);
    await controller.close();
  });

  test('user pause cancels interruption auto-resume', () async {
    final engine = _FakeSpeechEngine();
    final controller = TxtSpeechController(
      readController: _FakeReadController(<List<String>>[
        <String>['first'],
      ]),
      engine: engine,
      bookTitle: 'Book',
    );

    unawaited(controller.startAt(ChapterData()));
    await _flush();
    await controller.handleAudioInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await controller.pause();
    await controller.handleAudioInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await _flush();

    expect(controller.state, TxtSpeechState.paused);
    expect(engine.spoken, <String>['first']);
    await controller.close();
  });

  test('media coordinator deactivates the previous owner', () async {
    final coordinator = AppMediaPlaybackCoordinator.instance;
    final first = _FakeMediaDelegate('test_first');
    final second = _FakeMediaDelegate('test_second');
    coordinator.registerDelegate(first);
    coordinator.registerDelegate(second);

    await coordinator.activate(first.ownerId);
    await coordinator.activate(second.ownerId);

    expect(first.activated, 1);
    expect(first.deactivatedFor, second.ownerId);
    expect(second.activated, 1);
    expect(coordinator.activeOwnerId, second.ownerId);
    await coordinator.release(second.ownerId);
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeSpeechEngine implements TxtSpeechEngine {
  _FakeSpeechEngine({
    this.maxInputLength = 3000,
    this.voices = const <TxtSpeechVoice>[],
  });

  final int maxInputLength;
  final List<TxtSpeechVoice> voices;
  final List<String> spoken = <String>[];
  Completer<void>? _current;
  double rate = 1.0;
  TxtSpeechVoice? voice;

  void completeCurrent() {
    final current = _current;
    if (current != null && !current.isCompleted) current.complete();
  }

  @override
  Future<void> dispose() async {
    completeCurrent();
  }

  @override
  Future<int> getMaxInputLength() async => maxInputLength;

  @override
  Future<List<TxtSpeechVoice>> getVoices() async => voices;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause() async {
    completeCurrent();
  }

  @override
  Future<void> setRate(double rate) async {
    this.rate = rate;
  }

  @override
  Future<void> setVoice(TxtSpeechVoice? voice) async {
    this.voice = voice;
  }

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    _current = Completer<void>();
    return _current!.future;
  }

  @override
  Future<void> stop() async {
    completeCurrent();
  }
}

class _FakePrefetchSpeechEngine extends _FakeSpeechEngine
    implements TxtSpeechPrefetchEngine {
  final List<String?> prefetched = <String?>[];

  @override
  Future<void> speakWithPrefetch(String text, String? nextText) {
    prefetched.add(nextText);
    return speak(text);
  }
}

class _FakeReadController implements ReadController {
  _FakeReadController(List<List<String>> chapters)
    : _chapters = <List<BookSentence>>[
        for (final chapter in chapters)
          <BookSentence>[
            for (var index = 0; index < chapter.length; index++)
              BookSentence.fromText(chapter[index], index, index),
          ],
      ];

  final List<List<BookSentence>> _chapters;

  @override
  int getChapterNum() => _chapters.length;

  @override
  List<BookSentence>? getSentenceFromIndex(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return null;
    return _chapters[chapterIndex];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaDelegate extends AppMediaPlaybackDelegate {
  _FakeMediaDelegate(this.ownerId);

  @override
  final String ownerId;
  int activated = 0;
  String? deactivatedFor;

  @override
  Future<void> onActivated() async {
    activated++;
  }

  @override
  Future<void> onDeactivated(String? nextOwnerId) async {
    deactivatedFor = nextOwnerId;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> stop() async {}
}
