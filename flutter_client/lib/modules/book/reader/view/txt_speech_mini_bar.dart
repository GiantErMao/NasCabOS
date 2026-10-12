import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controller/txt_speech_controller.dart';

class TxtSpeechMiniBar extends StatelessWidget {
  const TxtSpeechMiniBar({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    required this.showSyncToSpeech,
    required this.onSyncToSpeech,
  });

  final TxtSpeechController controller;
  final VoidCallback onOpenSettings;
  final bool showSyncToSpeech;
  final VoidCallback onSyncToSpeech;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                tooltip: 'txt_speech_previous'.tr,
                onPressed: controller.previousSegment,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: controller.isPlaying
                    ? 'txt_speech_pause'.tr
                    : 'txt_speech_play'.tr,
                onPressed: controller.isPlaying
                    ? controller.pause
                    : controller.play,
                icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
              ),
              IconButton(
                tooltip: 'txt_speech_next'.tr,
                onPressed: controller.nextSegment,
                icon: const Icon(Icons.skip_next),
              ),
              Expanded(
                child: InkWell(
                  onTap: onOpenSettings,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${controller.backend == TxtSpeechBackend.localNeural ? 'txt_speech_source_local'.tr : 'txt_speech_source_system'.tr} · '
                      '${controller.currentSegment?.text ?? 'txt_speech_reading'.tr}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              Visibility(
                visible: showSyncToSpeech,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: IconButton(
                  key: const ValueKey<String>('txt-speech-sync-reading'),
                  tooltip: 'txt_speech_sync_reading'.tr,
                  onPressed: onSyncToSpeech,
                  icon: const Icon(Icons.my_location),
                ),
              ),
              IconButton(
                tooltip: 'txt_speech_stop'.tr,
                onPressed: controller.stop,
                icon: const Icon(Icons.stop),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
