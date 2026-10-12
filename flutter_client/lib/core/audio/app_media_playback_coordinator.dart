import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'app_media_playback_delegate.dart';

class AppMediaPlaybackCoordinator {
  AppMediaPlaybackCoordinator._();

  static final AppMediaPlaybackCoordinator instance =
      AppMediaPlaybackCoordinator._();

  final Map<String, AppMediaPlaybackDelegate> _delegates =
      <String, AppMediaPlaybackDelegate>{};

  _AppAudioHandler? _handler;
  Future<void>? _initFuture;
  String? _activeOwnerId;

  bool get supportsBackground =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  String? get activeOwnerId => _activeOwnerId;

  bool isActive(String ownerId) => _activeOwnerId == ownerId;

  void registerDelegate(AppMediaPlaybackDelegate delegate) {
    _delegates[delegate.ownerId] = delegate;
  }

  Future<void> ensureInitialized() async {
    if (!supportsBackground) return;
    final existing = _initFuture;
    if (existing != null) return existing;

    final future = () async {
      _handler = await AudioService.init(
        builder: () => _AppAudioHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'nascab.music.playback',
          androidNotificationChannelName: 'Music Playback',
          androidNotificationChannelDescription:
              'Background media playback controls',
          androidStopForegroundOnPause: false,
          androidShowNotificationBadge: false,
          androidNotificationClickStartsActivity: true,
          androidResumeOnClick: true,
        ),
      );
    }();
    _initFuture = future;
    try {
      await future;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> activate(String ownerId) async {
    final next = _delegates[ownerId];
    if (next == null) {
      throw StateError('Media delegate is not registered: $ownerId');
    }
    await ensureInitialized();
    if (_activeOwnerId == ownerId) return;

    final previous = _delegates[_activeOwnerId];
    await previous?.onDeactivated(ownerId);
    _activeOwnerId = ownerId;
    await next.onActivated();
  }

  Future<void> release(String ownerId) async {
    if (_activeOwnerId != ownerId) {
      _delegates.remove(ownerId);
      return;
    }
    _activeOwnerId = null;
    _delegates.remove(ownerId);
    publishQueue(ownerId, const <MediaItem>[], allowInactive: true);
    publishMediaItem(ownerId, null, allowInactive: true);
    publishPlaybackState(
      ownerId,
      PlaybackState(processingState: AudioProcessingState.idle, playing: false),
      allowInactive: true,
    );
  }

  void publishQueue(
    String ownerId,
    List<MediaItem> items, {
    bool allowInactive = false,
  }) {
    if (!allowInactive && !isActive(ownerId)) return;
    _handler?.queue.add(items);
  }

  void publishMediaItem(
    String ownerId,
    MediaItem? item, {
    bool allowInactive = false,
  }) {
    if (!allowInactive && !isActive(ownerId)) return;
    _handler?.mediaItem.add(item);
  }

  void publishPlaybackState(
    String ownerId,
    PlaybackState state, {
    bool allowInactive = false,
  }) {
    if (!allowInactive && !isActive(ownerId)) return;
    _handler?.playbackState.add(state);
  }

  AppMediaPlaybackDelegate? get _activeDelegate => _delegates[_activeOwnerId];
}

class _AppAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  _AppAudioHandler(this.coordinator);

  final AppMediaPlaybackCoordinator coordinator;

  @override
  Future<void> play() async => coordinator._activeDelegate?.play();

  @override
  Future<void> pause() async => coordinator._activeDelegate?.pause();

  @override
  Future<void> stop() async {
    await coordinator._activeDelegate?.stop();
    await super.stop();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    final delegate = coordinator._activeDelegate;
    if (delegate == null) return super.click(button);
    await delegate.click(button);
  }

  @override
  Future<void> seek(Duration position) async {
    await coordinator._activeDelegate?.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await coordinator._activeDelegate?.skipToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    await coordinator._activeDelegate?.skipToPrevious();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await coordinator._activeDelegate?.skipToQueueItem(index);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await coordinator._activeDelegate?.setRepeatMode(repeatMode);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await coordinator._activeDelegate?.setShuffleMode(shuffleMode);
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    queue.add(newQueue);
  }
}
