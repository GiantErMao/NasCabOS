import 'package:flutter/material.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:flutter_read/src/read_controller_impl.dart';
import 'package:flutter_read/src/read_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paged reader maps a long press to sentence and word coordinates', () {
    final controller = ReadControllerImpl();
    controller.contentSize = const Size(320, 480);
    controller.zhWordSize = const Size(16, 24);
    controller.readStyle = controller.readStyle.copyWith(
      textAlign: TextAlign.left,
      padding: const EdgeInsets.all(20),
      wordSpacing: 0,
    );

    final sentence = BookSentence.fromText('abcdefgh', 3, 3);
    final line = BookLine(sentence, 2)..endIndex = 7;
    final page = BookPage()..lines.add(line);
    final data = PaintData(1, 'Chapter', bookPage: page);

    final first = hitTestBookPageLocation(
      controller: controller,
      data: data,
      localPosition: const Offset(21, 25),
    );
    final later = hitTestBookPageLocation(
      controller: controller,
      data: data,
      localPosition: const Offset(60, 25),
    );

    expect(first?.chapterIndex, 1);
    expect(first?.sentenceIndex, 3);
    expect(first?.wordIndex, 2);
    expect(later?.wordIndex, greaterThan(2));
  });

  test('paged reader ignores long presses outside text bounds', () {
    final controller = ReadControllerImpl();
    controller.contentSize = const Size(320, 480);
    controller.zhWordSize = const Size(16, 24);
    final sentence = BookSentence.fromText('text', 0, 0);
    final line = BookLine(sentence, 0)..endIndex = 4;
    final page = BookPage()..lines.add(line);

    final location = hitTestBookPageLocation(
      controller: controller,
      data: PaintData(0, 'Chapter', bookPage: page),
      localPosition: const Offset(5, 5),
    );

    expect(location, isNull);
  });

  test('paged reader locates a speech offset inside a rendered line', () {
    final controller = ReadControllerImpl();
    final sentence = BookSentence.fromText('abcdefghijklmnop', 3, 3);
    final firstLine = BookLine(sentence, 0)..endIndex = 8;
    final secondLine = BookLine(sentence, 8)..endIndex = 16;
    final pages = <PaintData>[
      PaintData(0, 'Chapter', bookPage: BookPage()..lines.add(firstLine)),
      PaintData(0, 'Chapter', bookPage: BookPage()..lines.add(secondLine)),
    ];

    expect(
      controller.findChapterPageIndex(
        ChapterData(chapterIndex: 0, sentenceIndex: 3, wordIndex: 4),
        pages,
      ),
      0,
    );
    expect(
      controller.findChapterPageIndex(
        ChapterData(chapterIndex: 0, sentenceIndex: 3, wordIndex: 12),
        pages,
      ),
      1,
    );
  });
}
