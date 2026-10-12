import 'package:NasCabOS/modules/book/reader/view/txt_continuous_reader_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:flutter_read/src/read_controller_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
  testWidgets('continuous reader scrolls and restores a stable location', (
    tester,
  ) async {
    final controller = ReadControllerImpl(
      readStyle: ReadStyle(
        textStyle: const TextStyle(fontSize: 18, color: Colors.black),
        titleTextStyle: const TextStyle(fontSize: 20, color: Colors.black),
        textAlign: TextAlign.start,
        titleTextAlign: TextAlign.center,
        bgColor: Colors.white,
        sentenceSpacing: 12,
        lineSpacing: 8,
        wordSpacing: 0,
        padding: const EdgeInsets.all(20),
      ),
    );
    final sentences = List<BookSentence>.generate(
      30,
      (index) => BookSentence.fromText(
        'Paragraph $index contains enough text for scrolling.',
        index,
        index,
      ),
    );
    controller.chapterSentences[0] = sentences;
    await controller.addChapter(ChapterSource(sentences, 'Continuous test'), 0);

    final progress = <BookProgress>[];
    final longPressLocations = <ChapterData>[];
    var menuTapCount = 0;

    Widget buildReader({
      required ChapterData location,
      required int revision,
      int positionRevision = 0,
      ChapterData? highlightedLocation,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: TxtContinuousReaderView(
            readController: controller,
            title: 'Continuous test',
            initialLocation: location,
            dataRevision: revision,
            positionRevision: positionRevision,
            onProgressChanged: progress.add,
            onMenu: () => menuTapCount++,
            highlightedLocation: highlightedLocation,
            onLocationLongPress: (location, _) {
              longPressLocations.add(location);
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(
      buildReader(
        location: ChapterData(chapterIndex: 0, sentenceIndex: 8),
        revision: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Paragraph 8 '), findsOneWidget);
    expect(progress.last.sentenceIndex, 8);

    await tester.drag(
      find.byType(ScrollablePositionedList),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();

    expect(progress.last.sentenceIndex, greaterThan(8));

    await tester.pumpWidget(
      buildReader(
        location: ChapterData(chapterIndex: 0, sentenceIndex: 4),
        revision: 1,
        positionRevision: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(progress.last.sentenceIndex, 4);

    await tester.pumpWidget(
      buildReader(
        location: ChapterData(chapterIndex: 0, sentenceIndex: 3),
        revision: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Paragraph 3 '), findsOneWidget);
    expect(progress.last.sentenceIndex, 3);

    final reader = tester.getRect(find.byType(TxtContinuousReaderView));
    await tester.tapAt(reader.center);
    await tester.pump();
    expect(menuTapCount, 1);

    final readingPositionBeforeHighlight = progress.last.sentenceIndex;
    await tester.pumpWidget(
      buildReader(
        location: ChapterData(chapterIndex: 0, sentenceIndex: 3),
        revision: 2,
        highlightedLocation: ChapterData(
          chapterIndex: 0,
          sentenceIndex: 20,
          wordIndex: 4,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(progress.last.sentenceIndex, readingPositionBeforeHighlight);

    await tester.pumpWidget(
      buildReader(
        location: ChapterData(chapterIndex: 0, sentenceIndex: 3),
        revision: 2,
        highlightedLocation: ChapterData(
          chapterIndex: 0,
          sentenceIndex: 3,
          wordIndex: 4,
        ),
      ),
    );
    await tester.pump();

    final highlightedBlock = find.byKey(
      const ValueKey<String>('txt-continuous-0-3'),
    );
    expect(highlightedBlock, findsOneWidget);
    final highlightedText = tester.widget<Text>(
      find.descendant(of: highlightedBlock, matching: find.byType(Text)),
    );
    final primary = Theme.of(
      tester.element(highlightedBlock),
    ).colorScheme.primary;
    expect(highlightedText.style?.color, primary);

    await tester.longPress(find.textContaining('Paragraph 3 '));
    await tester.pump();
    expect(longPressLocations.last.sentenceIndex, 3);
    expect(longPressLocations.last.wordIndex, greaterThan(0));
  });

  testWidgets('continuous reader lazily builds a large novel', (tester) async {
    final controller = ReadControllerImpl(
      readStyle: ReadStyle(
        textStyle: const TextStyle(fontSize: 18, color: Colors.black),
        titleTextStyle: const TextStyle(fontSize: 20, color: Colors.black),
        textAlign: TextAlign.start,
        titleTextAlign: TextAlign.center,
        bgColor: Colors.white,
        sentenceSpacing: 12,
        lineSpacing: 8,
        wordSpacing: 0,
        padding: const EdgeInsets.all(20),
      ),
    );
    final sentences = List<BookSentence>.generate(
      10000,
      (index) => BookSentence.fromText(
        'Large paragraph $index contains enough text for layout.',
        index,
        index,
      ),
    );
    controller.chapterSentences[0] = sentences;
    await controller.addChapter(ChapterSource(sentences, 'Large novel'), 0);

    final stopwatch = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TxtContinuousReaderView(
            readController: controller,
            title: 'Large novel',
            initialLocation: ChapterData(chapterIndex: 0, sentenceIndex: 5000),
            dataRevision: 1,
            onProgressChanged: (_) {},
            onMenu: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    stopwatch.stop();

    expect(find.textContaining('Large paragraph 5000 '), findsOneWidget);
    expect(find.textContaining('Large paragraph '), findsWidgets);
    expect(
      find.textContaining('Large paragraph ').evaluate().length,
      lessThan(100),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
