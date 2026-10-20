import 'package:flutter/foundation.dart';

enum LocalTtsModelPhase { notInstalled, verifying, extracting, ready, error }

@immutable
class LocalTtsModelState {
  const LocalTtsModelState({
    required this.phase,
    this.currentFile,
    this.installedBytes = 0,
    this.message,
  });

  const LocalTtsModelState.notInstalled()
    : this(phase: LocalTtsModelPhase.notInstalled);

  final LocalTtsModelPhase phase;
  final String? currentFile;
  final int installedBytes;
  final String? message;

  bool get isReady => phase == LocalTtsModelPhase.ready;
  bool get isBusy =>
      phase == LocalTtsModelPhase.verifying ||
      phase == LocalTtsModelPhase.extracting;
}

@immutable
class LocalTtsModelPaths {
  const LocalTtsModelPaths({
    required this.acousticModel,
    required this.vocoder,
    required this.lexicon,
    required this.tokens,
    required this.ruleFsts,
  });

  final String acousticModel;
  final String vocoder;
  final String lexicon;
  final String tokens;
  final String ruleFsts;

  Map<String, String> toMessage() => <String, String>{
    'acousticModel': acousticModel,
    'vocoder': vocoder,
    'lexicon': lexicon,
    'tokens': tokens,
    'ruleFsts': ruleFsts,
  };
}

abstract class LocalTtsModelStoreBase extends ChangeNotifier {
  LocalTtsModelState get state;

  Future<void> refresh();

  Future<void> installBundledModel();

  Future<void> deleteInstalledModel();

  Future<LocalTtsModelPaths> resolvePaths();
}
