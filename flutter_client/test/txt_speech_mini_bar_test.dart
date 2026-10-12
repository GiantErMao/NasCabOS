import 'package:NasCabOS/modules/book/reader/controller/txt_speech_controller.dart';
import 'package:NasCabOS/modules/book/reader/service/txt_speech_engine.dart';
import 'package:NasCabOS/modules/book/reader/view/txt_speech_mini_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sync button is visible only when reading is out of sync', (
    tester,
  ) async {
    final controller = TxtSpeechController(
      readController: _FakeReadController(),
      engine: _FakeSpeechEngine(),
      bookTitle: 'Book',
    );
    var syncCount = 0;

    Widget buildBar(bool showSyncToSpeech) {
      return MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TxtSpeechMiniBar(
            controller: controller,
            onOpenSettings: () {},
            showSyncToSpeech: showSyncToSpeech,
            onSyncToSpeech: () => syncCount++,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildBar(false));
    var visibility = tester.widget<Visibility>(
      find.ancestor(
        of: find.byKey(
          const ValueKey<String>('txt-speech-sync-reading'),
          skipOffstage: false,
        ),
        matching: find.byType(Visibility),
      ),
    );
    expect(visibility.visible, isFalse);
    expect(visibility.maintainSize, isTrue);

    await tester.pumpWidget(buildBar(true));
    visibility = tester.widget<Visibility>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('txt-speech-sync-reading')),
        matching: find.byType(Visibility),
      ),
    );
    expect(visibility.visible, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('txt-speech-sync-reading')),
    );
    expect(syncCount, 1);

    await controller.close();
  });
}

class _FakeSpeechEngine implements TxtSpeechEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<int> getMaxInputLength() async => 3000;

  @override
  Future<List<TxtSpeechVoice>> getVoices() async => const <TxtSpeechVoice>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVoice(TxtSpeechVoice? voice) async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _FakeReadController implements ReadController {
  @override
  int getChapterNum() => 0;

  @override
  List<BookSentence>? getSentenceFromIndex(int chapterIndex) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
