import 'local_tts_model_store_shared.dart';

class LocalTtsModelStore extends LocalTtsModelStoreBase {
  LocalTtsModelState _state = const LocalTtsModelState.notInstalled();
  bool _disposed = false;

  @override
  LocalTtsModelState get state => _state;

  @override
  void cancelDownload() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  @override
  Future<void> deleteInstalledModel() async {}

  @override
  Future<void> download() async {
    throw UnsupportedError('Local neural TTS is available on Android only');
  }

  @override
  Future<void> refresh() async {
    _state = const LocalTtsModelState.notInstalled();
    if (!_disposed) notifyListeners();
  }

  @override
  Future<LocalTtsModelPaths> resolvePaths() async {
    throw StateError('Local neural TTS model is not installed');
  }
}
