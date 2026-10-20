import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/local_tts_model_manifest.dart';
import 'local_tts_feature_flag.dart';
import 'local_tts_model_store_shared.dart';

class LocalTtsModelStore extends LocalTtsModelStoreBase {
  LocalTtsModelStore({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const MethodChannel _storageChannel = MethodChannel(
    'com.nascabos/storage',
  );

  // A reader can close while installation continues. Other readers must wait
  // before cleaning staging files or starting another installation.
  static final Map<String, Future<void>> _rootInstallations = {};

  final AssetBundle _bundle;
  LocalTtsModelState _state = const LocalTtsModelState.notInstalled();
  Future<void>? _installation;
  bool _disposed = false;

  @override
  LocalTtsModelState get state => _state;

  @override
  Future<void> refresh() async {
    if (!localTtsAvailable) {
      _update(const LocalTtsModelState.notInstalled());
      return;
    }
    if (_installation != null) return _installation!;
    try {
      final root = await _modelRoot();
      await _rootInstallations[root.path];
      await _deleteStaleStaging(root);
      await _deleteLegacyInstallations(root);
      final target = Directory(p.join(root.path, LocalTtsModelManifest.id));
      if (!await _isValidInstallation(target)) {
        await installBundledModel();
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
  Future<void> installBundledModel() {
    if (!localTtsAvailable) {
      return Future.error(
        UnsupportedError('Local neural TTS is available on Android only'),
      );
    }
    return _installation ??= _installBundledModel().whenComplete(() {
      _installation = null;
    });
  }

  Future<void> _installBundledModel() async {
    _update(const LocalTtsModelState(phase: LocalTtsModelPhase.extracting));
    try {
      final root = await _modelRoot();
      final pending = _rootInstallations[root.path];
      if (pending != null) {
        await pending;
      } else {
        final installation = _installIntoRoot(root);
        _rootInstallations[root.path] = installation;
        try {
          await installation;
        } finally {
          _rootInstallations.remove(root.path);
        }
      }
      final target = Directory(p.join(root.path, LocalTtsModelManifest.id));
      _update(
        LocalTtsModelState(
          phase: LocalTtsModelPhase.ready,
          installedBytes: await _directorySize(target),
        ),
      );
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  Future<void> _installIntoRoot(Directory root) async {
    Directory? temporary;
    try {
      final freeBytes = await _availableBytes(root.path);
      if (freeBytes != null &&
          freeBytes < LocalTtsModelManifest.minimumFreeBytes) {
        throw const LocalTtsModelException(
          'insufficient_storage',
          'At least 350 MB of free app storage is required',
        );
      }
      temporary = await Directory(
        p.join(root.path, '.bundled'),
      ).create(recursive: true);
      for (final artifact in LocalTtsModelManifest.artifacts) {
        _update(
          LocalTtsModelState(
            phase: LocalTtsModelPhase.verifying,
            currentFile: artifact.fileName,
          ),
        );
        final file = File(p.join(temporary.path, artifact.fileName));
        await _copyBundledArtifact(artifact, file);
        await _verifyArtifact(file, artifact);
      }
      _update(const LocalTtsModelState(phase: LocalTtsModelPhase.extracting));
      final stagingPath = p.join(
        root.path,
        '.staging-${DateTime.now().microsecondsSinceEpoch}',
      );
      final archivePath = p.join(
        temporary.path,
        LocalTtsModelManifest.acousticArchive.fileName,
      );
      final vocoderPath = p.join(
        temporary.path,
        LocalTtsModelManifest.vocoder.fileName,
      );
      final rootPath = root.path;
      await Isolate.run(
        () =>
            _installInIsolate(rootPath, stagingPath, archivePath, vocoderPath),
      );
      final oldDownloads = Directory(p.join(root.path, '.downloads'));
      if (await oldDownloads.exists()) {
        await oldDownloads.delete(recursive: true);
      }
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<void> _copyBundledArtifact(
    LocalTtsArtifact artifact,
    File destination,
  ) async {
    final data = await _bundle.load(artifact.assetPath);
    await destination.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
