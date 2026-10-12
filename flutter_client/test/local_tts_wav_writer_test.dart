import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:NasCabOS/modules/book/reader/service/local_tts_wav_writer.dart';

void main() {
  test('writes a valid mono PCM16 WAV file', () {
    final directory = Directory.systemTemp.createTempSync('local_tts_wav_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sample.wav');

    writeMonoPcm16Wav(
      path: file.path,
      samples: Float32List.fromList(<double>[-1, 0, 1]),
      sampleRate: 22050,
    );

    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 22050);
    expect(data.getUint16(34, Endian.little), 16);
    expect(data.getInt16(44, Endian.little), -32768);
    expect(data.getInt16(46, Endian.little), 0);
    expect(data.getInt16(48, Endian.little), 32767);
  });
}
