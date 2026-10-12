import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'read_controller_impl.dart';
import 'read_data.dart';

class ReadPaint extends StatelessWidget {
  final PaintData data;
  final Widget? loadingWidget;

  const ReadPaint({super.key, required this.data, this.loadingWidget});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
        valueListenable: data.picture,
        builder: (BuildContext context, ui.Picture? value, Widget? child) {
          if (value != null) {
            return CustomPaint(
              painter: _Painter(value),
            );
          }
          return SizedBox(
            child: loadingWidget,
          );
        });
  }
}

class ReadHighlightPaint extends StatelessWidget {
  const ReadHighlightPaint({
    super.key,
    required this.data,
    required this.controller,
    required this.location,
    required this.color,
  });

  final PaintData data;
  final ReadControllerImpl controller;
  final ChapterData location;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final page = data.bookPage;
    if (page == null || data.chapterIndex != location.chapterIndex) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        painter: _HighlightPainter(
          page: page,
          controller: controller,
          location: location,
          color: color,
        ),
      ),
    );
  }
}

ChapterData? hitTestBookPageLocation({
  required ReadControllerImpl controller,
  required PaintData data,
  required Offset localPosition,
}) {
  final page = data.bookPage;
  if (page == null) return null;
  final style = controller.readStyle_;
  if (localPosition.dx < style.padding.left ||
      localPosition.dx > controller.contentSize.width - style.padding.right ||
      localPosition.dy < style.padding.top ||
      localPosition.dy > controller.contentSize.height - style.padding.bottom) {
    return null;
  }

  var y = style.padding.top;
  var firstLineSpacing = style.wordSpacing;
  for (final line in page.lines) {
    final lineHeight = controller.zhWordSize.height + style.lineSpacing;
    final spacing = _resolvedWordSpacing(
      controller,
      line,
      firstLineSpacing,
    );
    if (line.endIndex != null && line.startIndex == 0) {
      firstLineSpacing = spacing;
    }
    if (localPosition.dy >= y && localPosition.dy < y + lineHeight) {
      if (line.isTitle) {
        return ChapterData(chapterIndex: data.chapterIndex);
      }
      final index = _wordIndexForDx(
        controller: controller,
        line: line,
        dx: localPosition.dx,
        wordSpacing: spacing,
      );
      return ChapterData(
        chapterIndex: data.chapterIndex,
        sentenceIndex: line.sentence.index,
        wordIndex: index,
      );
    }
    y += lineHeight;
    if (line.endIndex == null) y += style.sentenceSpacing;
  }
  return null;
}

class _Painter extends CustomPainter {
  final ui.Picture picture;

  _Painter(this.picture);

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawPicture(picture);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

class _HighlightPainter extends CustomPainter {
  const _HighlightPainter({
    required this.page,
    required this.controller,
    required this.location,
    required this.color,
  });

  final BookPage page;
  final ReadControllerImpl controller;
  final ChapterData location;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final style = controller.readStyle_;
    var y = style.padding.top;
    var firstLineSpacing = style.wordSpacing;
    for (final line in page.lines) {
      final lineHeight = controller.zhWordSize.height + style.lineSpacing;
      final spacing = _resolvedWordSpacing(
        controller,
        line,
        firstLineSpacing,
      );
      if (line.endIndex != null && line.startIndex == 0) {
        firstLineSpacing = spacing;
      }
      if (!line.isTitle && line.sentence.index == location.sentenceIndex) {
        final layout = _lineLayout(
          controller,
          line,
          wordSpacing: spacing,
        );
        final words = line.sentence.words.sublist(
          line.startIndex,
          line.endIndex,
        );
        var x = layout.start;
        for (final word in words) {
          final painter = TextPainter(
            text: TextSpan(
              text: word.char,
              style: style.textStyle.copyWith(color: color),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          painter.paint(
            canvas,
            Offset(
              x,
              y + (controller.zhWordSize.height - painter.height) / 2,
            ),
          );
          x += painter.width + layout.spacing;
        }
      }
      y += lineHeight;
      if (line.endIndex == null) y += style.sentenceSpacing;
    }
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter oldDelegate) {
    return oldDelegate.page != page ||
        oldDelegate.location.chapterIndex != location.chapterIndex ||
        oldDelegate.location.sentenceIndex != location.sentenceIndex ||
        oldDelegate.location.wordIndex != location.wordIndex ||
        oldDelegate.color != color;
  }
}

int _wordIndexForDx({
  required ReadControllerImpl controller,
  required BookLine line,
  required double dx,
  required double wordSpacing,
}) {
  final words = line.sentence.words.sublist(line.startIndex, line.endIndex);
  if (words.isEmpty) return line.startIndex;
  final layout = _lineLayout(
    controller,
    line,
    wordSpacing: wordSpacing,
  );
  var x = layout.start;
  for (var index = 0; index < words.length; index++) {
    final width = _measureWord(
      words[index].char,
      line.isTitle
          ? controller.readStyle_.titleTextStyle
          : controller.readStyle_.textStyle,
    );
    if (dx < x + width / 2) return line.startIndex + index;
    x += width + layout.spacing;
  }
  return (line.endIndex ?? line.sentence.words.length) - 1;
}

_LineLayout _lineLayout(
  ReadControllerImpl controller,
  BookLine line, {
  required double wordSpacing,
}) {
  final style = controller.readStyle_;
  final words = line.sentence.words.sublist(line.startIndex, line.endIndex);
  var wordWidth = 0.0;
  for (final word in words) {
    wordWidth += _measureWord(
      word.char,
      line.isTitle ? style.titleTextStyle : style.textStyle,
    );
  }
  final spacing = wordSpacing;
  final align = line.isTitle ? style.titleTextAlign : style.textAlign;
  final totalWidth = wordWidth + spacing * (words.length - 1).clamp(0, 1 << 30);
  var x = style.padding.left;
  if (align == TextAlign.center) {
    x = (controller.contentSize.width - totalWidth) / 2;
  } else if (align == TextAlign.end || align == TextAlign.right) {
    x = controller.contentSize.width - style.padding.right - totalWidth;
  }
  return _LineLayout(x, spacing);
}

double _resolvedWordSpacing(
  ReadControllerImpl controller,
  BookLine line,
  double firstLineSpacing,
) {
  final style = controller.readStyle_;
  final align = line.isTitle ? style.titleTextAlign : style.textAlign;
  if (align != TextAlign.justify) return style.wordSpacing;
  if (line.endIndex == null) return firstLineSpacing;
  final words = line.sentence.words.sublist(line.startIndex, line.endIndex);
  var wordWidth = 0.0;
  for (final word in words) {
    wordWidth += _measureWord(
      word.char,
      line.isTitle ? style.titleTextStyle : style.textStyle,
    );
  }
  final available = controller.contentSize.width -
      style.padding.left -
      style.padding.right -
      wordWidth;
  return words.length <= 1 ? 0 : available / (words.length - 1);
}

double _measureWord(String word, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: word, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

class _LineLayout {
  const _LineLayout(this.start, this.spacing);

  final double start;
  final double spacing;
}
