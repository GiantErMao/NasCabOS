import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_read/flutter_read.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/api/api_controller.dart';
import '../../../../core/api/api_parts/p2p_channel_util.dart';
import '../../../../core/api/http_client_factory.dart'
    if (dart.library.html) '../../../../core/api/http_client_factory_web.dart'
    if (dart.library.io) '../../../../core/api/http_client_factory_io.dart';
import '../../reader_comic/service/book_comic_reader_api_service.dart';
import '../controller/txt_speech_controller.dart';
import '../service/flutter_tts_speech_engine.dart';
import '../service/local_tts_feature_flag.dart';
import '../service/local_tts_model_store.dart';
import '../service/sherpa_onnx_speech_engine.dart';
import 'txt_continuous_reader_view.dart';
import 'txt_speech_control_sheet.dart';
import 'txt_speech_mini_bar.dart';

class BookTxtReaderPage extends StatefulWidget {
  final String fileHash;
  final String title;
  final String? url;
  final String? localFilePath;
  final int expectedSize;
  final Future<void> Function()? onDispose;

  const BookTxtReaderPage({
    super.key,
    required this.fileHash,
    required this.title,
    this.url,
    this.localFilePath,
    required this.expectedSize,
    this.onDispose,
  });

  @override
  State<BookTxtReaderPage> createState() => _BookTxtReaderPageState();
}

class _BookTxtReaderPageState extends State<BookTxtReaderPage> {
  final ReadController _readController = ReadController.create(
    loadingWidget: const Center(child: CircularProgressIndicator()),
    enableVerticalDrag: true,
    enableTapPage: true,
  );
  final FocusNode _keyboardFocusNode = FocusNode();
  late final TxtSpeechController _speechController;
  LocalTtsModelStoreBase? _localTtsModelStore;

  bool _loading = false;
  String _errorText = '';
  BookProgress _uiProgress = BookProgress.zero;
  ChapterData? _lastLocation;
  bool _showProgressBar = true;
  String _textEncoding = 'auto';
  TxtReadingMode _readingMode = TxtReadingMode.paged;
  bool _continuousViewActivated = false;
  double? _navScrubPage1;
  bool _openingMenu = false;
  Timer? _styleDebounceTimer;
  ReadStyle? _pendingStyle;
  int _dataRevision = 0;
  int _continuousPositionRevision = 0;
  String? _lastSpeechError;

  StreamSubscription<BookProgress>? _progressSub;
  Timer? _persistTimer;
  BookProgress? _pendingPersist;
  int _lastUploadedPageIndex = -1;

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    Navigator.of(context).maybePop();
    return true;
  }

  String get _prefsKey => 'book_txt_progress:${widget.fileHash}';
  String get _stylePrefsKey => 'book_txt_style';
  String get _showProgressPrefsKey => 'book_txt_show_progress';
  String get _encodingPrefsKey => 'book_txt_encoding:${widget.fileHash}';
  String get _readingModePrefsKey => 'book_txt_reading_mode';

  @override
  void initState() {
    super.initState();
    final localModelStore = localTtsAvailable ? LocalTtsModelStore() : null;
    _localTtsModelStore = localModelStore;
    _speechController = TxtSpeechController(
      readController: _readController,
      engine: FlutterTtsSpeechEngine(),
      localEngine: localModelStore == null
          ? null
          : SherpaOnnxSpeechEngine(modelStore: localModelStore),
      bookTitle: widget.title,
      preferredLocale: Get.locale?.toLanguageTag(),
    )..addListener(_onSpeechChanged);
    _progressSub = _readController.onPageIndexChanged.listen((progress) {
      if (_readingMode != TxtReadingMode.paged) return;
      _updateUiProgress(progress);
      _schedulePersist(progress);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keyboardFocusNode.requestFocus();
      unawaited(_initLoad());
    });
  }

  @override
  void dispose() {
    _speechController.removeListener(_onSpeechChanged);
    unawaited(_speechController.close());
    _localTtsModelStore?.dispose();
    _persistTimer?.cancel();
    _persistTimer = null;
    _styleDebounceTimer?.cancel();
    _styleDebounceTimer = null;
    _keyboardFocusNode.dispose();
    unawaited(_flushPersist());
    _progressSub?.cancel();
    _progressSub = null;
    unawaited(widget.onDispose?.call());
    super.dispose();
  }

  void _scheduleApplyStyle(ReadStyle next) {
    _pendingStyle = next;
    _styleDebounceTimer?.cancel();
    _styleDebounceTimer = Timer(const Duration(milliseconds: 280), () {
      final s = _pendingStyle;
      _pendingStyle = null;
      if (s == null) return;
      _readController.readStyle = s;
      if (mounted) setState(() {});
      unawaited(_persistStyle(s));
    });
  }

  void _applyStyleNow(ReadStyle next) {
    _pendingStyle = null;
    _styleDebounceTimer?.cancel();
    _styleDebounceTimer = null;
    _readController.readStyle = next;
    if (mounted) setState(() {});
    unawaited(_persistStyle(next));
  }

  Future<void> _loadAndApplyStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_stylePrefsKey);
      _showProgressBar = prefs.getBool(_showProgressPrefsKey) ?? true;
      _textEncoding = (prefs.getString(_encodingPrefsKey) ?? 'auto').trim();
      _readingMode = prefs.getString(_readingModePrefsKey) == 'continuous'
          ? TxtReadingMode.continuous
          : TxtReadingMode.paged;
      _continuousViewActivated = _readingMode == TxtReadingMode.continuous;
      if (_textEncoding.isEmpty) _textEncoding = 'auto';
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final m = decoded.cast<String, dynamic>();

      final style = _readController.readStyle;
      final textStyle = style.textStyle;
      final titleTextStyle = style.titleTextStyle;

      final fontSize = (m['fontSize'] as num?)?.toDouble();
      final textColorValue = (m['textColor'] as num?)?.toInt();
      final bgColorValue = (m['bgColor'] as num?)?.toInt();
      final lineSpacing = (m['lineSpacing'] as num?)?.toDouble();
      const double wordSpacing = 0.0;

      final paddingL = (m['paddingL'] as num?)?.toDouble();
      final paddingT = (m['paddingT'] as num?)?.toDouble();
      final paddingR = (m['paddingR'] as num?)?.toDouble();
      final paddingB = (m['paddingB'] as num?)?.toDouble();

      final next = style.copyWith(
        textStyle: textStyle.copyWith(
          fontSize: fontSize,
          color: textColorValue == null ? null : Color(textColorValue),
        ),
        titleTextStyle: titleTextStyle.copyWith(
          fontSize: fontSize == null ? null : (fontSize + 2),
          color: textColorValue == null ? null : Color(textColorValue),
        ),
        bgColor: bgColorValue == null ? null : Color(bgColorValue),
        lineSpacing: lineSpacing,
        wordSpacing: wordSpacing,
        padding:
            (paddingL != null &&
                paddingT != null &&
                paddingR != null &&
                paddingB != null)
            ? EdgeInsets.fromLTRB(paddingL, paddingT, paddingR, paddingB)
            : null,
      );
      _readController.readStyle = next;
    } catch (_) {}
  }

  Future<void> _persistStyle(ReadStyle style) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final padding = style.padding;
      await prefs.setString(
        _stylePrefsKey,
        jsonEncode({
          'fontSize': style.textStyle.fontSize ?? 16.0,
          'textColor': style.textStyle.color?.value ?? Colors.black.value,
          'bgColor': style.bgColor.value,
          'lineSpacing': style.lineSpacing,
          'wordSpacing': 0.0,
          'paddingL': padding.left,
          'paddingT': padding.top,
          'paddingR': padding.right,
          'paddingB': padding.bottom,
        }),
      );
    } catch (_) {}
  }

  Future<ChapterData?> _loadSavedChapter() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final m = map.cast<String, dynamic>();
      final chapterIndex = (m['chapterIndex'] as num?)?.toInt() ?? 0;
      final sentenceIndex = (m['sentenceIndex'] as num?)?.toInt() ?? 0;
      final wordIndex = (m['wordIndex'] as num?)?.toInt() ?? 0;
      if (chapterIndex <= 0 && sentenceIndex <= 0 && wordIndex <= 0) {
        return null;
      }
      return ChapterData(
        chapterIndex: chapterIndex.clamp(0, 1 << 30),
        sentenceIndex: sentenceIndex.clamp(0, 1 << 30),
        wordIndex: wordIndex.clamp(0, 1 << 30),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistLocal(BookProgress progress) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'chapterIndex': progress.chapterIndex,
          'sentenceIndex': progress.sentenceIndex,
          'wordIndex': progress.wordIndex,
          'pageIndex': progress.pageIndex,
          'pageTotal': progress.pageTotal,
        }),
      );
    } catch (_) {}
  }

  Future<void> _persistServer(BookProgress progress) async {
    final total = progress.pageTotal;
    if (total <= 0) return;
    final idx = progress.pageIndex.clamp(0, total - 1);
    if (idx == _lastUploadedPageIndex) return;
    _lastUploadedPageIndex = idx;
    await BookComicReaderApiService.instance.upsertProgress(
      fileHash: widget.fileHash,
      currentPage: idx,
      totalPage: total,
      showLoading: false,
    );
  }

  void _updateUiProgress(BookProgress progress) {
    if (!mounted) return;
    _lastLocation = ChapterData(
      chapterIndex: progress.chapterIndex,
      sentenceIndex: progress.sentenceIndex,
      wordIndex: progress.wordIndex,
    );
    final prev = _uiProgress;
    if (prev.pageIndex == progress.pageIndex &&
        prev.pageTotal == progress.pageTotal &&
        prev.chapterIndex == progress.chapterIndex &&
        prev.sentenceIndex == progress.sentenceIndex &&
        prev.wordIndex == progress.wordIndex) {
      return;
    }
    setState(() {
      _uiProgress = progress;
    });
  }

  void _schedulePersist(BookProgress progress) {
    _pendingPersist = progress;
    _persistTimer ??= Timer(const Duration(milliseconds: 600), () {
      _persistTimer = null;
      unawaited(_flushPersist());
    });
  }

  Future<void> _flushPersist() async {
    final p = _pendingPersist;
    if (p == null) return;
    _pendingPersist = null;
    await _persistLocal(p);
    await _persistServer(p);
  }

  ChapterData _currentLocation() {
    final saved = _lastLocation;
    if (saved != null) {
      return ChapterData(
        chapterIndex: saved.chapterIndex,
        sentenceIndex: saved.sentenceIndex,
        wordIndex: saved.wordIndex,
      );
    }
    final p = _uiProgress;
    return ChapterData(
      chapterIndex: p.chapterIndex,
      sentenceIndex: p.sentenceIndex,
      wordIndex: p.wordIndex,
    );
  }

  bool get _isSpeechOutOfSync {
    final speech = _speechController.currentSegment?.location;
    if (speech == null) return false;
    final reading = _currentLocation();
    return speech.chapterIndex != reading.chapterIndex ||
        speech.sentenceIndex != reading.sentenceIndex;
  }

  void _syncReadingToSpeech() {
    final segment = _speechController.currentSegment;
    if (segment == null) return;
    final location = segment.location;
    if (_readingMode == TxtReadingMode.continuous) {
      setState(() {
        _lastLocation = location;
        _continuousPositionRevision++;
      });
      return;
    }
    _readController.jumpToLocation(location);
  }

  bool get _supportsSpeech =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  void _onSpeechChanged() {
    if (!mounted) return;
    final error = _speechController.errorMessage;
    if (error != null && error != _lastSpeechError) {
      _lastSpeechError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'txt_speech_failed'.trParams(<String, String>{'error': error}),
            ),
          ),
        );
      });
    }
    setState(() {});
  }

  Future<void> _openSpeechControls() async {
    try {
      await _speechController.initialize();
    } catch (_) {}
    await _localTtsModelStore?.refresh();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => TxtSpeechControlSheet(
        controller: _speechController,
        modelStore: _localTtsModelStore,
        onStartFromCurrent: () {
          unawaited(_speechController.startAt(_currentLocation()));
        },
      ),
    );
  }

  Future<void> _showSpeechLocationMenu(
    ChapterData location,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'speak',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.record_voice_over),
            title: Text('txt_speech_from_here'.tr),
          ),
        ),
      ],
    );
    if (selected == 'speak') {
      await _speechController.startAt(location);
    }
  }

  Future<void> _setReadingMode(TxtReadingMode mode) async {
    if (_readingMode == mode) return;
    final location = _currentLocation();
    setState(() {
      _readingMode = mode;
      if (mode == TxtReadingMode.continuous) {
        _continuousViewActivated = true;
        _continuousPositionRevision++;
      }
      _navScrubPage1 = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _readingModePrefsKey,
      mode == TxtReadingMode.continuous ? 'continuous' : 'paged',
    );
    if (mode == TxtReadingMode.paged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _readController.jumpToLocation(location);
      });
    }
  }

  Future<Uint8List> _loadRemoteBytes(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Invalid TXT URL');
    }

    if (kIsWeb && uri.origin.trim() == ApiController.p2pBaseUrl) {
      final request = http.Request('GET', uri);
      final resolved = P2pChannelUtil.resolve(uri: uri);
      final response = await ApiController.instance.sendP2pRequestOnChannel(
        request,
        channel: resolved.channel,
      );
      final bytes = await http.ByteStream(response.stream).toBytes();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('TXT request failed: HTTP ${response.statusCode}');
      }
      return Uint8List.fromList(bytes);
    }

    if (kIsWeb) {
      final response = await Dio().get<List<int>>(
        uri.toString(),
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? const <int>[]);
    }

    final client = createHttpClient();
    try {
      final response = await client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('TXT request failed: HTTP ${response.statusCode}');
      }
      return response.bodyBytes;
    } finally {
      client.close();
    }
  }

  Future<void> _initLoad() async {
    setState(() {
      _loading = true;
      _errorText = '';
    });

    try {
      await _loadAndApplyStyle();
      final chapter = await _loadSavedChapter();
      _lastLocation = chapter;
      const split = true;

      BookSource source;
      if (!kIsWeb &&
          widget.localFilePath != null &&
          widget.localFilePath!.trim().isNotEmpty) {
        source = FileSource(
          widget.localFilePath!.trim(),
          widget.title,
          isSplit: split,
          encoding: _textEncoding == 'auto' ? null : _textEncoding,
        );
      } else {
        final u = widget.url?.trim() ?? '';
        final uri = Uri.tryParse(u);
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
          setState(() {
            _errorText = 'operation_failed'.tr;
            _loading = false;
          });
          return;
        }

        final bytes = await _loadRemoteBytes(u);
        if (bytes.isEmpty) {
          setState(() {
            _errorText = 'operation_failed'.tr;
            _loading = false;
          });
          return;
        }

        final data = ByteData.sublistView(bytes);
        source = ByteDataSource(
          data,
          widget.title,
          isSplit: split,
          encoding: _textEncoding == 'auto' ? null : _textEncoding,
        );
      }

      final state = await _readController.startReadBook(
        source,
        chapter: chapter,
      );
      if (state < 0) {
        if (!mounted) return;
        setState(() {
          _errorText = 'operation_failed'.tr;
          _loading = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _dataRevision++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _reloadWithEncoding(String encoding) async {
    final next = encoding.trim();
    if (next.isEmpty) return;
    if (next == _textEncoding) return;
    final speechWasActive = _speechController.hasActiveSpeech;
    final speechLocation =
        _speechController.currentSegment?.location ?? _currentLocation();
    if (speechWasActive) {
      await _speechController.pause();
    }
    _textEncoding = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_encodingPrefsKey, _textEncoding);

    final chapter = _currentLocation();
    if (mounted) {
      setState(() {
        _loading = true;
        _errorText = '';
      });
    }
    try {
      const split = true;
      BookSource source;
      if (!kIsWeb &&
          widget.localFilePath != null &&
          widget.localFilePath!.trim().isNotEmpty) {
        source = FileSource(
          widget.localFilePath!.trim(),
          widget.title,
          isSplit: split,
          encoding: _textEncoding == 'auto' ? null : _textEncoding,
        );
      } else {
        final u = widget.url?.trim() ?? '';
        final uri = Uri.tryParse(u);
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
          if (mounted) {
            setState(() {
              _errorText = 'operation_failed'.tr;
              _loading = false;
            });
          }
          return;
        }

        final bytes = await _loadRemoteBytes(u);
        if (bytes.isEmpty) {
          if (mounted) {
            setState(() {
              _errorText = 'operation_failed'.tr;
              _loading = false;
            });
          }
          return;
        }
        final data = ByteData.sublistView(bytes);
        source = ByteDataSource(
          data,
          widget.title,
          isSplit: split,
          encoding: _textEncoding == 'auto' ? null : _textEncoding,
        );
      }

      final state = await _readController.reopen(source, chapter: chapter);
      if (mounted) {
        if (state < 0) {
          if (speechWasActive) {
            await _speechController.stop();
          }
          // 不提示错误，直接保持旧内容
          _loading = false;
          _errorText = '';
          setState(() {});
          return;
        }
        setState(() {
          _dataRevision++;
          _loading = false;
        });
        if (speechWasActive) {
          await _speechController.startAt(speechLocation);
        }
      }
    } catch (e) {
      if (speechWasActive) {
        await _speechController.stop();
      }
      if (mounted) {
        // 不提示错误，直接保持旧内容
        setState(() {
          _loading = false;
          _errorText = '';
        });
      }
    }
  }

  Future<void> _openMenu() async {
    if (_openingMenu) return;
    _openingMenu = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) {
          final style = _readController.readStyle;
          double menuFontSize = (style.textStyle.fontSize ?? 16.0)
              .clamp(10.0, 32.0)
              .toDouble();
          Color menuFg = style.textStyle.color ?? Colors.black;
          Color menuBg = style.bgColor;
          double menuLineSpacing = style.lineSpacing;
          double menuWordSpacing = 0.0;
          String menuEncoding = _textEncoding;
          TxtReadingMode menuReadingMode = _readingMode;
          final totalPages = _uiProgress.pageTotal;
          double menuJumpPage = totalPages > 0
              ? (_uiProgress.pageIndex + 1).clamp(1, totalPages).toDouble()
              : 1.0;

          final bgCandidates = <Color>[
            const Color(0xFFE2E8DC),
            Colors.white,
            const Color(0xFFF6EBD5),
            Colors.black,
          ];
          final fgCandidates = <Color>[
            Colors.black,
            const Color(0xFF2B2B2B),
            const Color(0xFF404040),
            const Color(0xFF666666),
            const Color(0xFF888888),
            const Color(0xFF5B4636),
            Colors.white,
          ];

          Widget colorDot(Color c, bool selected, VoidCallback onTap) {
            return InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? Theme.of(ctx).colorScheme.primary
                        : Colors.grey,
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
            );
          }

          void applyStyle(ReadStyle next) {
            _scheduleApplyStyle(next);
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                top: 8,
              ),
              child: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (ctx, setModalState) {
                    ReadStyle buildNextStyle(ReadStyle cur) {
                      return cur.copyWith(
                        textStyle: cur.textStyle.copyWith(
                          fontSize: menuFontSize,
                          color: menuFg,
                        ),
                        titleTextStyle: cur.titleTextStyle.copyWith(
                          fontSize: menuFontSize + 2,
                          color: menuFg,
                        ),
                        bgColor: menuBg,
                        lineSpacing: menuLineSpacing,
                        wordSpacing: menuWordSpacing,
                      );
                    }

                    String progressText() {
                      final total = _uiProgress.pageTotal;
                      if (total <= 0) return '';
                      final idx = _uiProgress.pageIndex.clamp(0, total - 1) + 1;
                      final pct = ((idx / total) * 100).clamp(0, 100).round();
                      return '$idx/$total ($pct%)';
                    }

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'txt_reader_settings'.tr,
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text('txt_reader_show_progress'.tr),
                            ),
                            Switch.adaptive(
                              value: _showProgressBar,
                              onChanged: (v) async {
                                setState(() {
                                  _showProgressBar = v;
                                });
                                setModalState(() {});
                                final prefs =
                                    await SharedPreferences.getInstance();
                                await prefs.setBool(_showProgressPrefsKey, v);
                              },
                            ),
                          ],
                        ),
                        Text('comic_reader_reading_mode'.tr),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<TxtReadingMode>(
                            segments: [
                              ButtonSegment<TxtReadingMode>(
                                value: TxtReadingMode.paged,
                                icon: const Icon(Icons.view_carousel_outlined),
                                label: Text('txt_reader_mode_paged'.tr),
                              ),
                              ButtonSegment<TxtReadingMode>(
                                value: TxtReadingMode.continuous,
                                icon: const Icon(Icons.view_stream_outlined),
                                label: Text('txt_reader_mode_continuous'.tr),
                              ),
                            ],
                            selected: <TxtReadingMode>{menuReadingMode},
                            onSelectionChanged: (selected) {
                              if (selected.isEmpty) return;
                              menuReadingMode = selected.first;
                              setModalState(() {});
                              unawaited(_setReadingMode(menuReadingMode));
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(child: Text('txt_reader_encoding'.tr)),
                            DropdownButton<String>(
                              value: menuEncoding,
                              items: [
                                DropdownMenuItem(
                                  value: 'auto',
                                  child: Text('auto'.tr),
                                ),
                                DropdownMenuItem(
                                  value: 'utf8',
                                  child: Text("UTF-8"),
                                ),
                                DropdownMenuItem(
                                  value: 'gbk',
                                  child: Text("GBK"),
                                ),
                              ],
                              onChanged: (v) async {
                                menuEncoding = v ?? 'auto';
                                setModalState(() {});
                                Navigator.of(ctx).pop();
                                await _reloadWithEncoding(menuEncoding);
                              },
                            ),
                          ],
                        ),
                        Text('txt_reader_font_size'.tr),
                        Slider(
                          value: menuFontSize,
                          min: 10,
                          max: 32,
                          divisions: 22,
                          label: menuFontSize.toStringAsFixed(0),
                          onChanged: (v) {
                            menuFontSize = v;
                            final cur = _readController.readStyle;
                            applyStyle(buildNextStyle(cur));
                            setModalState(() {});
                          },
                        ),
                        const SizedBox(height: 12),
                        Text('txt_reader_line_spacing'.tr),
                        Slider(
                          value: menuLineSpacing.clamp(0.0, 24.0),
                          min: 0,
                          max: 24,
                          onChanged: (v) {
                            menuLineSpacing = v;
                            final cur = _readController.readStyle;
                            applyStyle(buildNextStyle(cur));
                            setModalState(() {});
                          },
                        ),
                        const SizedBox(height: 6),
                        Text('txt_reader_text_color'.tr),
                        const SizedBox(height: 6),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final c in fgCandidates)
                                colorDot(c, c.value == menuFg.value, () {
                                  menuFg = c;
                                  final cur = _readController.readStyle;
                                  _applyStyleNow(buildNextStyle(cur));
                                  setModalState(() {});
                                }),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text('txt_reader_background'.tr),
                        const SizedBox(height: 6),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final c in bgCandidates)
                                colorDot(c, c.value == menuBg.value, () {
                                  menuBg = c;
                                  final cur = _readController.readStyle;
                                  _applyStyleNow(buildNextStyle(cur));
                                  setModalState(() {});
                                }),
                            ],
                          ),
                        ),
                        if (_readingMode == TxtReadingMode.paged &&
                            _uiProgress.pageTotal > 0) ...[
                          const SizedBox(height: 12),
                          Text('comic_reader_jump_to_page'.tr),
                          Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  value: menuJumpPage
                                      .clamp(1, _uiProgress.pageTotal)
                                      .toDouble(),
                                  min: 1,
                                  max: _uiProgress.pageTotal.toDouble(),
                                  divisions: (_uiProgress.pageTotal - 1).clamp(
                                    1,
                                    500,
                                  ),
                                  label: menuJumpPage.toStringAsFixed(0),
                                  onChanged: (v) {
                                    menuJumpPage = v;
                                    setModalState(() {});
                                  },
                                  onChangeEnd: (v) {
                                    final page = v.round().clamp(
                                      1,
                                      _uiProgress.pageTotal,
                                    );
                                    _readController.jumpToPage(page - 1);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${menuJumpPage.round().clamp(1, _uiProgress.pageTotal)}/${_uiProgress.pageTotal}',
                                style: Theme.of(ctx).textTheme.labelMedium,
                              ),
                            ],
                          ),
                        ],
                        const SizedBox.shrink(),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      );
    } finally {
      _openingMenu = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorText.isNotEmpty) {
      return Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _handleKeyEvent(event)
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_errorText, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      unawaited(_initLoad());
                    },
                    child: Text('retry'.tr),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_loading) {
      return _buildReader(loading: true);
    }

    return _buildReader();
  }

  Widget _buildReader({bool loading = false}) {
    final total = _uiProgress.pageTotal;
    final page = _uiProgress.pageIndex;
    final isContinuous = _readingMode == TxtReadingMode.continuous;
    final progressText = total > 0
        ? '${(page + 1).clamp(1, total)}/$total'
        : '';

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.pageUp) {
          if (isContinuous) return KeyEventResult.ignored;
          _readController.previousPage();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.pageDown) {
          if (isContinuous) return KeyEventResult.ignored;
          _readController.nextPage();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: (!_showProgressBar || progressText.isEmpty)
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(16),
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: 2,
                    ),
                    child: total > 0
                        ? isContinuous
                              ? Row(
                                  children: [
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: ((page + 1) / total)
                                            .clamp(0.0, 1.0)
                                            .toDouble(),
                                        minHeight: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      progressText,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 2,
                                          overlayShape:
                                              const RoundSliderOverlayShape(
                                                overlayRadius: 0,
                                              ),
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 6,
                                              ),
                                          tickMarkShape:
                                              const RoundSliderTickMarkShape(
                                                tickMarkRadius: 0,
                                              ),
                                          showValueIndicator:
                                              ShowValueIndicator.never,
                                        ),
                                        child: SizedBox(
                                          height: 14,
                                          child: Slider(
                                            value:
                                                (_navScrubPage1 ??
                                                        (page + 1)
                                                            .clamp(1, total)
                                                            .toDouble())
                                                    .clamp(1, total)
                                                    .toDouble(),
                                            min: 1,
                                            max: total.toDouble(),
                                            divisions: (total - 1).clamp(
                                              1,
                                              500,
                                            ),
                                            onChanged: (v) {
                                              setState(() {
                                                _navScrubPage1 = v;
                                              });
                                            },
                                            onChangeEnd: (v) {
                                              final targetPage1 = v
                                                  .round()
                                                  .clamp(1, total);
                                              _readController.jumpToPage(
                                                targetPage1 - 1,
                                              );
                                              setState(() {
                                                _navScrubPage1 = null;
                                              });
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      '${(_navScrubPage1?.round() ?? (page + 1)).clamp(1, total)}/$total',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ],
                                )
                        : const SizedBox.shrink(),
                  ),
                ),
          actions: [
            if (_supportsSpeech)
              IconButton(
                tooltip: 'txt_speech_title'.tr,
                onPressed: _openSpeechControls,
                icon: const Icon(Icons.record_voice_over),
              ),
            if (!isContinuous)
              IconButton(
                onPressed: () async {
                  await _readController.reflow();
                },
                icon: const Icon(Icons.refresh),
              ),
            IconButton(onPressed: _openMenu, icon: const Icon(Icons.tune)),
          ],
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _keyboardFocusNode.requestFocus(),
          child: Stack(
            children: [
              Positioned.fill(
                child: IndexedStack(
                  index: isContinuous ? 1 : 0,
                  children: [
                    ReadView(
                      readController: _readController,
                      onMenu: _openMenu,
                      highlightedLocation:
                          _speechController.currentSegment?.location,
                      onLocationLongPress: _supportsSpeech
                          ? _showSpeechLocationMenu
                          : null,
                    ),
                    if (_continuousViewActivated)
                      TxtContinuousReaderView(
                        readController: _readController,
                        title: widget.title,
                        initialLocation: _currentLocation(),
                        dataRevision: _dataRevision,
                        positionRevision: _continuousPositionRevision,
                        highlightedLocation:
                            _speechController.currentSegment?.location,
                        onLocationLongPress: _supportsSpeech
                            ? _showSpeechLocationMenu
                            : null,
                        onProgressChanged: (progress) {
                          if (_readingMode != TxtReadingMode.continuous) return;
                          _updateUiProgress(progress);
                          _schedulePersist(progress);
                        },
                        onMenu: _openMenu,
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
              if (loading)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: _speechController.hasActiveSpeech
            ? TxtSpeechMiniBar(
                controller: _speechController,
                onOpenSettings: _openSpeechControls,
                showSyncToSpeech: _isSpeechOutOfSync,
                onSyncToSpeech: _syncReadingToSpeech,
              )
            : null,
      ),
    );
  }
}
