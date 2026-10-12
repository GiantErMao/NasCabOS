import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'local_tts_model_store_shared.dart';
import 'local_tts_wav_writer.dart';

class LocalTtsSynthesisResult {
  const LocalTtsSynthesisResult({
    required this.generation,
    required this.wavPath,
    required this.sampleRate,
    required this.durationSeconds,
    required this.elapsedSeconds,
  });

  final int generation;
  final String wavPath;
  final int sampleRate;
  final double durationSeconds;
  final double elapsedSeconds;

  double get rtf => durationSeconds <= 0 ? 0 : elapsedSeconds / durationSeconds;
}

class LocalTtsWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  StreamSubscription<Object?>? _subscription;
  final Map<int, Completer<Map<Object?, Object?>>> _pending =
      <int, Completer<Map<Object?, Object?>>>{};
  int _requestId = 0;

  Future<void> initialize(LocalTtsModelPaths paths) async {
    if (_isolate != null) return;
    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    _subscription = receivePort.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        return;
      }
      _handleMessage(message);
    });
    _isolate = await Isolate.spawn(_workerMain, receivePort.sendPort);
    _sendPort = await ready.future;
    await _request('initialize', paths.toMessage());
  }

  Future<LocalTtsSynthesisResult> synthesize({
    required int generation,
    required String text,
    required double speed,
    required int speakerId,
    required String wavPath,
  }) async {
    final response = await _request('synthesize', <String, Object>{
      'generation': generation,
      'text': text,
      'speed': speed,
      'speakerId': speakerId,
      'wavPath': wavPath,
    });
    return LocalTtsSynthesisResult(
      generation: response['generation']! as int,
      wavPath: response['wavPath']! as String,
      sampleRate: response['sampleRate']! as int,
      durationSeconds: (response['durationSeconds']! as num).toDouble(),
      elapsedSeconds: (response['elapsedSeconds']! as num).toDouble(),
    );
  }

  void cancel(int generation) {
    _sendPort?.send(<String, Object>{
      'id': 0,
      'command': 'cancel',
      'generation': generation,
    });
  }

  Future<void> dispose() async {
    final isolate = _isolate;
    if (isolate == null) return;
    try {
      await _request(
        'dispose',
        const <String, Object>{},
      ).timeout(const Duration(milliseconds: 500));
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
    }
    await _subscription?.cancel();
    _subscription = null;
    _isolate = null;
    _sendPort = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Local TTS worker was disposed'));
      }
    }
    _pending.clear();
  }

  Future<Map<Object?, Object?>> _request(
    String command,
    Map<String, Object> payload,
  ) {
    final port = _sendPort;
    if (port == null) throw StateError('Local TTS worker is not initialized');
    final id = ++_requestId;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    port.send(<String, Object>{'id': id, 'command': command, ...payload});
    return completer.future;
  }

  void _handleMessage(Object? message) {
    if (message is SendPort) return;
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = message['error'];
    if (error != null) {
      completer.completeError(
        LocalTtsWorkerException(
          message['code']?.toString() ?? 'worker_error',
          error.toString(),
        ),
      );
      return;
    }
    completer.complete(message.cast<Object?, Object?>());
  }
}

class LocalTtsWorkerException implements Exception {
  const LocalTtsWorkerException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

void _workerMain(SendPort mainPort) {
  final commands = ReceivePort();
  mainPort.send(commands.sendPort);
  sherpa.OfflineTts? tts;
  var cancelledGeneration = -1;

  commands.listen((raw) {
    if (raw is! Map) return;
    final id = raw['id'] as int? ?? 0;
    final command = raw['command'];
    if (command == 'cancel') {
      cancelledGeneration = raw['generation'] as int? ?? -1;
      return;
    }
    try {
      switch (command) {
        case 'initialize':
          final stopwatch = Stopwatch()..start();
          sherpa.initBindings();
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                matcha: sherpa.OfflineTtsMatchaModelConfig(
                  acousticModel: raw['acousticModel']! as String,
                  vocoder: raw['vocoder']! as String,
                  lexicon: raw['lexicon']! as String,
                  tokens: raw['tokens']! as String,
                ),
                numThreads: 4,
                debug: false,
              ),
              ruleFsts: raw['ruleFsts']! as String,
              maxNumSenetences: 1,
            ),
          );
          stopwatch.stop();
          mainPort.send(<String, Object>{
            'id': id,
            'elapsedSeconds': stopwatch.elapsedMicroseconds / 1000000,
          });
          break;
        case 'synthesize':
          final engine = tts;
          if (engine == null) {
            throw StateError('Local TTS worker is not initialized');
          }
          final generation = raw['generation']! as int;
          final wavPath = raw['wavPath']! as String;
          final stopwatch = Stopwatch()..start();
          final audio = engine.generateWithConfig(
            text: raw['text']! as String,
            config: sherpa.OfflineTtsGenerationConfig(
              sid: raw['speakerId']! as int,
              speed: (raw['speed']! as num).toDouble(),
              silenceScale: 0.2,
            ),
            onProgress: (_, _) => cancelledGeneration == generation ? 0 : 1,
          );
          stopwatch.stop();
          if (cancelledGeneration == generation) {
            final wav = File(wavPath);
            if (wav.existsSync()) wav.deleteSync();
            throw const LocalTtsWorkerException(
              'cancelled',
              'Synthesis was cancelled',
            );
          }
          if (audio.sampleRate <= 0 || audio.samples.isEmpty) {
            throw const LocalTtsWorkerException(
              'empty_audio',
              'The local TTS model returned no audio',
            );
          }
          writeMonoPcm16Wav(
            path: wavPath,
            samples: audio.samples,
            sampleRate: audio.sampleRate,
          );
          final duration = audio.samples.length / audio.sampleRate;
          mainPort.send(<String, Object>{
            'id': id,
            'generation': generation,
            'wavPath': wavPath,
            'sampleRate': audio.sampleRate,
            'durationSeconds': duration,
            'elapsedSeconds': stopwatch.elapsedMicroseconds / 1000000,
          });
          break;
        case 'dispose':
          tts?.free();
          tts = null;
          mainPort.send(<String, Object>{'id': id});
          commands.close();
          break;
        default:
          throw ArgumentError('Unknown worker command: $command');
      }
    } catch (error) {
      mainPort.send(<String, Object>{
        'id': id,
        'code': error is LocalTtsWorkerException
            ? error.code
            : 'worker_failure',
        'error': error is LocalTtsWorkerException
            ? error.message
            : error.toString(),
      });
    }
  });
}
