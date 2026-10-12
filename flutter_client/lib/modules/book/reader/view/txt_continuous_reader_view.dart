import 'package:flutter/material.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

enum TxtReadingMode { paged, continuous }

class TxtContinuousReaderView extends StatefulWidget {
  final ReadController readController;
  final String title;
  final ChapterData? initialLocation;
  final int dataRevision;
  final int positionRevision;
  final ValueChanged<BookProgress> onProgressChanged;
  final VoidCallback onMenu;
  final ReadLocationLongPressCallback? onLocationLongPress;
  final ChapterData? highlightedLocation;

  const TxtContinuousReaderView({
    super.key,
    required this.readController,
    required this.title,
    required this.initialLocation,
    required this.dataRevision,
    this.positionRevision = 0,
    required this.onProgressChanged,
    required this.onMenu,
    this.onLocationLongPress,
    this.highlightedLocation,
  });

  @override
  State<TxtContinuousReaderView> createState() =>
      _TxtContinuousReaderViewState();
}

class _TxtContinuousReaderViewState extends State<TxtContinuousReaderView> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  final List<_TxtContinuousChapter> _chapters = <_TxtContinuousChapter>[];

  ChapterData? _pendingLocation;
  int _blockCount = 0;
  int _initialIndex = 0;
  int _lastReportedIndex = -1;
  bool _jumpScheduled = false;

  @override
  void initState() {
    super.initState();
    _pendingLocation = widget.initialLocation;
    _rebuildBlocks();
    _initialIndex = _indexForLocation(widget.initialLocation);
    _pendingLocation = null;
    _itemPositionsListener.itemPositions.addListener(_reportVisiblePosition);
  }

  @override
  void didUpdateWidget(covariant TxtContinuousReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataRevision != widget.dataRevision ||
        oldWidget.readController != widget.readController) {
      _pendingLocation = widget.initialLocation;
      _lastReportedIndex = -1;
      _rebuildBlocks();
      _schedulePendingJump();
    } else if (oldWidget.positionRevision != widget.positionRevision) {
      _pendingLocation = widget.initialLocation;
      _schedulePendingJump();
    }
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_reportVisiblePosition);
    super.dispose();
  }

  void _rebuildBlocks() {
    _chapters.clear();
    _blockCount = 0;
    final chapterCount = widget.readController.getChapterNum();
    for (var chapterIndex = 0; chapterIndex < chapterCount; chapterIndex++) {
      final sentences = widget.readController.getSentenceFromIndex(
        chapterIndex,
      );
      if (sentences == null || sentences.isEmpty) continue;
      _chapters.add(
        _TxtContinuousChapter(
          chapterIndex: chapterIndex,
          startIndex: _blockCount,
          sentences: sentences,
        ),
      );
      _blockCount += sentences.length;
    }
  }

  TextStyle _effectiveTextStyle(ReadStyle style) {
    final fontSize = style.textStyle.fontSize ?? 16;
    final height = ((fontSize + style.lineSpacing) / fontSize)
        .clamp(1.0, 3.0)
        .toDouble();
    return style.textStyle.copyWith(
      height: height,
      wordSpacing: style.wordSpacing,
    );
  }

  int _indexForLocation(ChapterData? location) {
    if (_blockCount == 0 || location == null) return 0;
    final chapterPosition = _chapters.indexWhere(
      (chapter) => chapter.chapterIndex == location.chapterIndex,
    );
    if (chapterPosition < 0) return 0;
    final chapter = _chapters[chapterPosition];
    final sentences = chapter.sentences;
    var low = 0;
    var high = sentences.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (sentences[mid].index < location.sentenceIndex) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return chapter.startIndex + low.clamp(0, sentences.length - 1);
  }

  _TxtContinuousBlock _blockAt(int index) {
    var low = 0;
    var high = _chapters.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_chapters[mid].startIndex <= index) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    final chapter = _chapters[high.clamp(0, _chapters.length - 1)];
    final sentence = chapter.sentences[index - chapter.startIndex];
    return _TxtContinuousBlock(
      chapterIndex: chapter.chapterIndex,
      sentenceIndex: sentence.index,
      originalSentenceIndex: sentence.originalIndex,
      text: sentence.toString(),
    );
  }

  void _schedulePendingJump() {
    final pending = _pendingLocation;
    if (pending == null) return;
    _scheduleJump(_indexForLocation(pending));
    _pendingLocation = null;
  }

  void _scheduleJump(int index) {
    if (index < 0 || index >= _blockCount || _jumpScheduled) return;
    _jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: index);
    });
  }

  void _reportVisiblePosition() {
    if (_blockCount == 0) return;
    final visible = _itemPositionsListener.itemPositions.value
        .where(
          (position) =>
              position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
        )
        .toList();
    if (visible.isEmpty) return;
    visible.sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    final index = visible.first.index;
    if (index < 0 || index == _lastReportedIndex) return;
    _lastReportedIndex = index;
    final block = _blockAt(index);
    widget.onProgressChanged(
      BookProgress(
        widget.title,
        block.chapterIndex,
        index,
        _blockCount,
        block.sentenceIndex,
        block.originalSentenceIndex,
        0,
        null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.readController.readStyle;
    final textStyle = _effectiveTextStyle(style);
    return ColoredBox(
      color: style.bgColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              final width = constraints.maxWidth;
              if (details.localPosition.dx >= width / 3 &&
                  details.localPosition.dx <= width * 2 / 3) {
                widget.onMenu();
              }
            },
            child: ScrollablePositionedList.builder(
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              initialScrollIndex: _initialIndex,
              padding: style.padding,
              itemCount: _blockCount,
              itemBuilder: (context, index) {
                final block = _blockAt(index);
                final highlighted = _matchesLocation(
                  block,
                  widget.highlightedLocation,
                );
                return Padding(
                  padding: EdgeInsets.only(bottom: style.sentenceSpacing),
                  child: LayoutBuilder(
                    builder: (context, blockConstraints) {
                      return GestureDetector(
                        key: ValueKey<String>(
                          'txt-continuous-${block.chapterIndex}-${block.sentenceIndex}',
                        ),
                        behavior: HitTestBehavior.opaque,
                        onLongPressStart: widget.onLocationLongPress == null
                            ? null
                            : (details) {
                                final painter = TextPainter(
                                  text: TextSpan(
                                    text: block.text,
                                    style: textStyle,
                                  ),
                                  textAlign: style.textAlign,
                                  textDirection: Directionality.of(context),
                                  textScaler: MediaQuery.textScalerOf(context),
                                )..layout(maxWidth: blockConstraints.maxWidth);
                                final position = painter.getPositionForOffset(
                                  details.localPosition,
                                );
                                widget.onLocationLongPress!(
                                  ChapterData(
                                    chapterIndex: block.chapterIndex,
                                    sentenceIndex: block.sentenceIndex,
                                    wordIndex: position.offset.clamp(
                                      0,
                                      block.text.length,
                                    ),
                                  ),
                                  details.globalPosition,
                                );
                              },
                        child: Text(
                          block.text,
                          style: highlighted
                              ? textStyle.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : textStyle,
                          textAlign: style.textAlign,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  bool _matchesLocation(_TxtContinuousBlock block, ChapterData? location) {
    return location != null &&
        block.chapterIndex == location.chapterIndex &&
        block.sentenceIndex == location.sentenceIndex;
  }
}

class _TxtContinuousBlock {
  final int chapterIndex;
  final int sentenceIndex;
  final int originalSentenceIndex;
  final String text;

  const _TxtContinuousBlock({
    required this.chapterIndex,
    required this.sentenceIndex,
    required this.originalSentenceIndex,
    required this.text,
  });
}

class _TxtContinuousChapter {
  final int chapterIndex;
  final int startIndex;
  final List<BookSentence> sentences;

  const _TxtContinuousChapter({
    required this.chapterIndex,
    required this.startIndex,
    required this.sentences,
  });
}
