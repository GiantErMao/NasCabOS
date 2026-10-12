import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../controllers/video_player_controller.dart';

class TranscodeInfoDialog {
  static void show(BuildContext context, PlayerController controller) {
    Get.dialog(
      AlertDialog(
        title: const Text('转码信息'),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<Map<String, dynamic>?>(
            future: controller.fetchTranscodeInfo(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 96,
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final data = snapshot.data;
              if (data == null || data['exists'] != true) {
                return _InfoColumn(
                  rows: [
                    _InfoRow(
                      '播放质量',
                      controller.qualityLabelShort(
                        controller.currentQuality.value,
                      ),
                    ),
                    _InfoRow(
                      '状态',
                      controller.currentQuality.value == 'original'
                          ? '原画播放，未启动转码'
                          : '暂无转码会话',
                    ),
                  ],
                );
              }

              final session = _asMap(data['session']);
              final request = _asMap(data['request']);
              final output = _asMap(data['output']);
              final hls = _asMap(data['hls']);
              final latest = _asMap(hls['latestSegment']);
              final outputWidth = _toInt(output['width']);
              final outputHeight = _toInt(output['height']);
              final bitRate = _toInt(output['bitRate']);
              final latestSize = _toInt(latest['size']);

              return _InfoColumn(
                rows: [
                  _InfoRow(
                    '播放质量',
                    controller.qualityLabelShort(
                      controller.currentQuality.value,
                    ),
                  ),
                  _InfoRow(
                    '状态',
                    session['isRunning'] == true ? '转码中' : '已暂停/结束',
                  ),
                  _InfoRow('请求', _formatRequest(request)),
                  _InfoRow(
                    '输出',
                    outputWidth > 0 && outputHeight > 0
                        ? '${outputWidth}x$outputHeight · ${_formatRate(output['avgFrameRate'])} · ${output['codec'] ?? ''}'
                        : '等待分片生成',
                  ),
                  _InfoRow('实际码率', bitRate > 0 ? _formatBitrate(bitRate) : '-'),
                  _InfoRow(
                    '像素格式',
                    (output['pixFmt'] ?? '').toString().isEmpty
                        ? '-'
                        : output['pixFmt'].toString(),
                  ),
                  _InfoRow('HLS 分片', '${_toInt(hls['segmentCount'])} 个'),
                  _InfoRow(
                    '最新分片',
                    latest.isEmpty
                        ? '-'
                        : '${latest['name'] ?? ''} · ${_formatBytes(latestSize)}',
                  ),
                  _InfoRow(
                    '最后访问',
                    _formatTime(_toInt(session['lastGetHlsTime'])),
                  ),
                  _InfoRow('Play ID', (data['playId'] ?? '').toString()),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(), child: Text('ok'.tr)),
        ],
      ),
    );
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _formatRequest(Map<String, dynamic> request) {
    final width = _toInt(request['width']);
    final bitrate = (request['bitrate'] ?? '').toString();
    final parts = <String>[];
    if (width > 0) parts.add('${width}w');
    if (bitrate.isNotEmpty) parts.add(bitrate);
    if (request['subtitleBurn'] == true) parts.add('字幕烧录');
    return parts.isEmpty ? '-' : parts.join(' · ');
  }

  static String _formatRate(dynamic value) {
    final raw = value?.toString() ?? '';
    if (raw.isEmpty || raw == '0/0') return '-';
    final parts = raw.split('/');
    if (parts.length == 2) {
      final a = double.tryParse(parts[0]);
      final b = double.tryParse(parts[1]);
      if (a != null && b != null && b > 0) {
        final fps = a / b;
        return '${fps.toStringAsFixed(fps >= 100 ? 0 : 1)}fps';
      }
    }
    return raw;
  }

  static String _formatBitrate(int bitsPerSecond) {
    if (bitsPerSecond <= 0) return '-';
    final mbps = bitsPerSecond / 1000000.0;
    if (mbps >= 1) return '${mbps.toStringAsFixed(2)} Mbps';
    return '${(bitsPerSecond / 1000.0).toStringAsFixed(0)} Kbps';
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '-';
    final mb = bytes / 1024.0 / 1024.0;
    if (mb >= 1) return '${mb.toStringAsFixed(2)} MB';
    return '${(bytes / 1024.0).toStringAsFixed(1)} KB';
  }

  static String _formatTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}

class _InfoColumn extends StatelessWidget {
  final List<_InfoRow> rows;

  const _InfoColumn({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
