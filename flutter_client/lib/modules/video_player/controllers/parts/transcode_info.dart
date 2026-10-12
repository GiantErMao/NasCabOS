part of '../video_player_controller.dart';

extension PlayerTranscodeInfo on PlayerController {
  bool get hasTranscodeSession =>
      currentQuality.value != 'original' &&
      (_playId != null && _playId!.trim().isNotEmpty);

  String? get currentTranscodePlayId => _playId;

  Future<Map<String, dynamic>?> fetchTranscodeInfo() async {
    final playId = _playId?.trim();
    if (playId == null || playId.isEmpty) return null;

    final url = ApiController.instance.buildAuthedApiUrl(
      '/api/videoPlayer/transcode-info',
      queryParameters: {'playId': playId},
      p2pChannel: 'video',
    );
    if (url.isEmpty) return null;

    final res = await HttpUtil.apiGet<Map<String, dynamic>>(
      url,
      dataParser: (data) => data,
      timeout: const Duration(seconds: 5),
      maxRetries: 0,
    );
    if (!res.success) return null;
    return res.data;
  }
}
