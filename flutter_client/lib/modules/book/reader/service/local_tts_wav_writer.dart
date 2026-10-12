import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void writeMonoPcm16Wav({
  required String path,
  required Float32List samples,
  required int sampleRate,
}) {
  final dataLength = samples.length * 2;
  final bytes = ByteData(44 + dataLength);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i].clamp(-1.0, 1.0);
    final pcm = sample < 0
        ? (sample * 32768).round()
        : (sample * 32767).round();
    bytes.setInt16(
      44 + i * 2,
      math.max(-32768, math.min(32767, pcm)),
      Endian.little,
    );
  }
  File(path).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
}
