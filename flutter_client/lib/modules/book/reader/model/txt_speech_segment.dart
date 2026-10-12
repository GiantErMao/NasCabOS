import 'package:flutter_read/flutter_read.dart';

class TxtSpeechSegment {
  const TxtSpeechSegment({
    required this.chapterIndex,
    required this.sentenceIndex,
    required this.startWordIndex,
    required this.endWordIndex,
    required this.text,
  });

  final int chapterIndex;
  final int sentenceIndex;
  final int startWordIndex;
  final int endWordIndex;
  final String text;

  ChapterData get location => ChapterData(
    chapterIndex: chapterIndex,
    sentenceIndex: sentenceIndex,
    wordIndex: startWordIndex,
  );
}
