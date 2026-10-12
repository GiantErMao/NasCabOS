import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/local_tts_model_manifest.dart';
import 'local_tts_feature_flag.dart';
import 'local_tts_model_store_shared.dart';

class LocalTtsModelStore extends LocalTtsModelStoreBase {
  LocalTtsModelStore({Dio? dio}) : _dio = dio ?? Dio();

  static const MethodChannel _storageChannel = MethodChannel(
    'com.nascabos/storage',
  );

  final Dio _dio;
  LocalTtsModelState _state = const LocalTtsModelState.notInstalled();
  CancelToken? _cancelToken;
  bool _disposed = false;

  @override
  LocalTtsModelState get state => _state;

  @override
  Future<void> refresh() async {
    if (!localTtsAvailable) {
      _update(const LocalTtsModelState.notInstalled());
      return;
    }
    try {
      final root = await _modelRoot();
      await _deleteStaleStaging(root);
      await _deleteLegacyInstallations(root);
      final target = Directory(p.join(root.path, LocalTtsModelManifest.id));
      if (!await _isValidInstallation(target)) {
        _update(const LocalTtsModelState.notInstalled());
        return;
      }
      _update(
        LocalTtsModelState(
          phase: LocalTtsModelPhase.ready,
          installedBytes: await _directorySize(target),
        ),
      );
    } catch (error) {
      _update(
        LocalTtsModelState(
          phase: LocalTtsModelPhase.error,
          message: _message(error),
        ),
      );
    }
  }

  @override
  Future<void> download() async {
    if (!localTtsAvailable) {
      throw UnsupportedError('Local neural TTS is available on Android only');
    }
    if (_state.isBusy) return;

    final root = await _modelRoot();
    try {
      final freeBytes = await _availableBytes(root.path);
      if (freeBytes != null &&
          freeBytes < LocalTtsModelManifest.minimumFreeBytes) {
        throw const LocalTtsModelException(
          'insufficient_storage',
          'At least 350 MB of free app storage is required',
        );
      }

      final downloads = Directory(p.join(root.path, '.downloads'));
      await downloads.create(recursive: true);
      _cancelToken = CancelToken();
      var completedBytes = 0;
      for (final artifact in LocalTtsModelManifest.artifacts) {
        final part = File(p.join(downloads.path, '${artifact.fileName}.part'));
        await _downloadArtifact(artifact, part, completedBytes, _cancelToken!);
        _update(
          LocalTtsModelState(
            phase: LocalTtsModelPhase.verifying,
            currentFile: artifact.fileName,
            downloadedBytes: completedBytes + artifact.length,
            totalBytes: LocalTtsModelManifest.downloadBytes,
          ),
        );
        await _verifyArtifact(part, artifact);
        completedBytes += artifact.length;
      }

      _update(
        LocalTtsModelState(
          phase: LocalTtsModelPhase.extracting,
          downloadedBytes: completedBytes,
          totalBytes: LocalTtsModelManifest.downloadBytes,
        ),
      );
      final generation = DateTime.now().microsecondsSinceEpoch;
      final staging = Directory(p.join(root.path, '.staging-$generation'));
      await Isolate.run(
        () => _installInIsolate(
          root.path,
          staging.path,
          p.join(
            downloads.path,
            '${LocalTtsModelManifest.acousticArchive.fileName}.part',
          ),
          p.join(
            downloads.path,
            '${LocalTtsModelManifest.vocoder.fileName}.part',
          ),
        ),
      );
      await downloads.delete(recursive: true);
      await refresh();
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        _update(const LocalTtsModelState.notInstalled());
        return;
      }
      _fail(error);
      rethrow;
    } catch (error) {
      _fail(error);
      rethrow;
    } finally {
      _cancelToken = null;
    }
  }

  @override
  void cancelDownload() {
    _cancelToken?.cancel('user_cancelled');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelDownload();
    super.dispose();
  }

  @override
  Future<void> deleteInstalledModel() async {
    if (_state.isBusy) {
      throw StateError('Cannot delete the model while it is being installed');
    }
    final root = await _modelRoot();
    final target = Directory(p.join(root.path, LocalTtsModelManifest.id));
    if (await target.exists()) await target.delete(recursive: true);
    _update(const LocalTtsModelState.notInstalled());
  }

  @override
  Future<LocalTtsModelPaths> resolvePaths() async {
    final root = await _modelRoot();
    final target = Directory(p.join(root.path, LocalTtsModelManifest.id));
    if (!await _isValidInstallation(target)) {
      throw const LocalTtsModelException(
        'model_not_ready',
        'Local neural TTS model is not installed or is damaged',
      );
    }
    String file(String relative) => p.join(target.path, relative);
    return LocalTtsModelPaths(
      acousticModel: file('matcha-icefall-zh-baker/model-steps-3.onnx'),
      vocoder: file('vocos-22khz-univ.onnx'),
      lexicon: file('matcha-icefall-zh-baker/lexicon.txt'),
      tokens: file('matcha-icefall-zh-baker/tokens.txt'),
      ruleFsts: <String>[
        file('matcha-icefall-zh-baker/phone.fst'),
        file('matcha-icefall-zh-baker/date.fst'),
        file('matcha-icefall-zh-baker/number.fst'),
      ].join(','),
    );
  }

  Future<void> _downloadArtifact(
    LocalTtsArtifact artifact,
    File destination,
    int completedBytes,
    CancelToken cancelToken,
  ) async {
    var existing = await destination.exists() ? await destination.length() : 0;
    if (existing > artifact.length) {
      await destination.delete();
      existing = 0;
    }
    if (existing == artifact.length) {
      _update(
        LocalTtsModelState(
          phase: LocalTtsModelPhase.downloading,
          progress:
              (completedBytes + existing) / LocalTtsModelManifest.downloadBytes,
          currentFile: artifact.fileName,
          downloadedBytes: completedBytes + existing,
          totalBytes: LocalTtsModelManifest.downloadBytes,
        ),
      );
      return;
    }
    final response = await _dio.get<ResponseBody>(
      artifact.url,
      options: Options(
        responseType: ResponseType.stream,
        headers: existing > 0
            ? <String, String>{'Range': 'bytes=$existing-'}
            : null,
        followRedirects: true,
      ),
      cancelToken: cancelToken,
    );
    final resumed =
        existing > 0 && response.statusCode == HttpStatus.partialContent;
    if (!resumed) existing = 0;
    final sink = destination.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    var received = existing;
    try {
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        final totalDownloaded = completedBytes + received;
        _update(
          LocalTtsModelState(
            phase: LocalTtsModelPhase.downloading,
            progress: totalDownloaded / LocalTtsModelManifest.downloadBytes,
            currentFile: artifact.fileName,
            downloadedBytes: totalDownloaded,
            totalBytes: LocalTtsModelManifest.downloadBytes,
          ),
        );
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> _verifyArtifact(File file, LocalTtsArtifact artifact) async {
    final length = await file.length();
    if (length != artifact.length) {
      await file.delete();
      throw LocalTtsModelException(
        'length_mismatch',
        '${artifact.fileName} has an invalid length',
      );
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != artifact.sha256) {
      await file.delete();
      throw LocalTtsModelException(
        'checksum_mismatch',
        '${artifact.fileName} failed SHA-256 verification',
      );
    }
  }

  Future<Directory> _modelRoot() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'tts_models'));
    await root.create(recursive: true);
    return root;
  }

  Future<bool> _isValidInstallation(Directory target) async {
    final marker = File(p.join(target.path, '.ready.json'));
    if (!await marker.exists()) return false;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map ||
          decoded['manifestVersion'] != LocalTtsModelManifest.version) {
        return false;
      }
      for (final relative in LocalTtsModelManifest.requiredFiles) {
        final file = File(p.join(target.path, relative));
        if (!await file.exists() || await file.length() == 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int?> _availableBytes(String path) async {
    try {
      return await _storageChannel.invokeMethod<int>(
        'availableBytes',
        <String, Object>{'path': path},
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _deleteStaleStaging(Directory root) async {
    await for (final entity in root.list()) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith('.staging-')) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _deleteLegacyInstallations(Directory root) async {
    for (final id in LocalTtsModelManifest.legacyModelIds) {
      final directory = Directory(p.join(root.path, id));
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<int> _directorySize(Directory directory) async {
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  void _update(LocalTtsModelState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  void _fail(Object error) {
    _update(
      LocalTtsModelState(
        phase: LocalTtsModelPhase.error,
        message: _message(error),
      ),
    );
  }

  String _message(Object error) =>
      error is LocalTtsModelException ? error.message : error.toString();
}

class LocalTtsModelException implements Exception {
  const LocalTtsModelException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

void _installInIsolate(
  String rootPath,
  String stagingPath,
  String archivePath,
  String vocoderPath,
) {
  final staging = Directory(stagingPath)..createSync(recursive: true);
  final tarPath = p.join(stagingPath, '.model.tar');
  try {
    final compressed = InputFileStream(archivePath);
    final tarOutput = OutputFileStream(tarPath);
    try {
      BZip2Decoder().decodeStream(compressed, tarOutput);
    } finally {
      compressed.closeSync();
      tarOutput.closeSync();
    }

    final tarInput = InputFileStream(tarPath);
    try {
      TarDecoder().decodeStream(
        tarInput,
        callback: (entry) {
          final normalized = p.posix.normalize(
            entry.name.replaceAll('\\', '/'),
          );
          if (entry.isSymbolicLink ||
              p.posix.isAbsolute(normalized) ||
              normalized == '..' ||
              normalized.startsWith('../')) {
            throw const LocalTtsModelException(
              'unsafe_archive',
              'Model archive contains an unsafe path or link',
            );
          }
          final destination = p.normalize(p.join(stagingPath, normalized));
          if (!p.isWithin(stagingPath, destination)) {
            throw const LocalTtsModelException(
              'unsafe_archive',
              'Model archive escapes the staging directory',
            );
          }
          if (entry.isDirectory) {
            Directory(destination).createSync(recursive: true);
            return;
          }
          File(destination).parent.createSync(recursive: true);
          final output = OutputFileStream(destination);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
        },
      );
    } finally {
      tarInput.closeSync();
      File(tarPath).deleteSync();
    }
    File(
      vocoderPath,
    ).copySync(p.join(stagingPath, LocalTtsModelManifest.vocoder.fileName));

    for (final relative in LocalTtsModelManifest.requiredFiles) {
      final file = File(p.join(stagingPath, relative));
      if (!file.existsSync() || file.lengthSync() == 0) {
        throw LocalTtsModelException(
          'missing_model_file',
          'Installed model is missing $relative',
        );
      }
    }
    File(p.join(stagingPath, '.ready.json')).writeAsStringSync(
      jsonEncode(<String, Object>{
        'manifestVersion': LocalTtsModelManifest.version,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
        'artifacts': <Map<String, Object>>[
          for (final artifact in LocalTtsModelManifest.artifacts)
            <String, Object>{
              'fileName': artifact.fileName,
              'length': artifact.length,
              'sha256': artifact.sha256,
            },
        ],
      }),
      flush: true,
    );

    final target = Directory(p.join(rootPath, LocalTtsModelManifest.id));
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
  } catch (_) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  }
}
