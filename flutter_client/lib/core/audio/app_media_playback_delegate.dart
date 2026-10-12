import 'package:audio_service/audio_service.dart';

abstract class AppMediaPlaybackDelegate {
  String get ownerId;

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  Future<void> skipToNext() async {}

  Future<void> skipToPrevious() async {}

  Future<void> skipToQueueItem(int index) async {}

  Future<void> seek(Duration position) async {}

  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  Future<void> onActivated() async {}

  Future<void> onDeactivated(String? nextOwnerId) async {
    await pause();
  }

  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button == MediaButton.media) {
      await play();
    }
  }
}
