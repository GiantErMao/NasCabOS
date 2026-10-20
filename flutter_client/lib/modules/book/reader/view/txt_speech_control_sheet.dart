import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controller/txt_speech_controller.dart';
import '../model/local_tts_model_manifest.dart';
import '../service/local_tts_model_store.dart';
import '../service/txt_speech_engine.dart';

class TxtSpeechControlSheet extends StatelessWidget {
  const TxtSpeechControlSheet({
    super.key,
    required this.controller,
    this.modelStore,
    required this.onStartFromCurrent,
  });

  static const List<double> rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final TxtSpeechController controller;
  final LocalTtsModelStoreBase? modelStore;
  final VoidCallback onStartFromCurrent;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          controller,
          if (modelStore != null) modelStore!,
        ]),
        builder: (context, _) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'txt_speech_title'.tr,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  if (controller.errorMessage != null) ...[
                    Text(
                      'txt_speech_failed'.trParams(<String, String>{
                        'error': controller.errorMessage!,
                      }),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    if (controller.backend == TxtSpeechBackend.localNeural)
                      TextButton.icon(
                        onPressed: () =>
                            controller.switchBackend(TxtSpeechBackend.system),
                        icon: const Icon(Icons.settings_voice),
                        label: Text('txt_speech_switch_to_system'.tr),
                      ),
                    const SizedBox(height: 12),
                  ],
                  if (modelStore != null) ...[
                    Text('txt_speech_engine'.tr),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<TxtSpeechBackend>(
                        segments: <ButtonSegment<TxtSpeechBackend>>[
                          ButtonSegment<TxtSpeechBackend>(
                            value: TxtSpeechBackend.system,
                            label: Text('txt_speech_engine_system'.tr),
                            icon: const Icon(Icons.settings_voice),
                          ),
                          ButtonSegment<TxtSpeechBackend>(
                            value: TxtSpeechBackend.localNeural,
                            label: Text('txt_speech_engine_local'.tr),
                            icon: const Icon(Icons.memory),
                            enabled: modelStore!.state.isReady,
                          ),
                        ],
                        selected: <TxtSpeechBackend>{controller.backend},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) async {
                          if (selection.isEmpty) return;
                          try {
                            await controller.switchBackend(selection.first);
                          } catch (_) {}
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildModelManager(context, modelStore!),
                    const SizedBox(height: 16),
                  ],
                  if (controller.hasActiveSpeech)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'txt_speech_previous'.tr,
                          onPressed: controller.previousSegment,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: controller.isPlaying
                              ? controller.pause
                              : controller.play,
                          icon: Icon(
                            controller.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                          label: Text(
                            controller.isPlaying
                                ? 'txt_speech_pause'.tr
                                : 'txt_speech_play'.tr,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'txt_speech_next'.tr,
                          onPressed: controller.nextSegment,
                          icon: const Icon(Icons.skip_next),
                        ),
                        IconButton(
                          tooltip: 'txt_speech_stop'.tr,
                          onPressed: controller.stop,
                          icon: const Icon(Icons.stop),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onStartFromCurrent,
                        icon: const Icon(Icons.record_voice_over),
                        label: Text('txt_speech_from_current'.tr),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text('txt_speech_rate'.tr),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<double>(
                      segments: rates
                          .map(
                            (rate) => ButtonSegment<double>(
                              value: rate,
                              label: Text('${rate}x'),
                            ),
                          )
                          .toList(growable: false),
                      selected: <double>{controller.rate},
                      onSelectionChanged: (values) {
                        if (values.isNotEmpty) {
                          controller.setRate(values.first);
                        }
                      },
                      showSelectedIcon: false,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('txt_speech_voice'.tr),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: DropdownButton<TxtSpeechVoice?>(
                      isExpanded: true,
                      value: controller.selectedVoice,
                      hint: Text(
                        controller.voices.isEmpty
                            ? 'txt_speech_no_voices'.tr
                            : 'txt_speech_system_default'.tr,
                      ),
                      items: <DropdownMenuItem<TxtSpeechVoice?>>[
                        DropdownMenuItem<TxtSpeechVoice?>(
                          value: null,
                          child: Text('txt_speech_system_default'.tr),
                        ),
                        ...controller.voices.map(
                          (voice) => DropdownMenuItem<TxtSpeechVoice?>(
                            value: voice,
                            child: Text(
                              voice.locale.isEmpty
                                  ? voice.name
                                  : '${voice.locale} · ${voice.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: controller.voices.isEmpty
                          ? null
                          : controller.setVoice,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildModelManager(
    BuildContext context,
    LocalTtsModelStoreBase store,
  ) {
    final state = store.state;
    switch (state.phase) {
      case LocalTtsModelPhase.notInstalled:
      case LocalTtsModelPhase.verifying:
      case LocalTtsModelPhase.extracting:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(
            state.phase == LocalTtsModelPhase.verifying
                ? 'txt_speech_model_verifying'.tr
                : 'txt_speech_model_extracting'.tr,
          ),
          subtitle: state.currentFile == null ? null : Text(state.currentFile!),
        );
      case LocalTtsModelPhase.ready:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.offline_bolt_outlined),
          title: const Text(LocalTtsModelManifest.displayName),
          trailing: IconButton(
            tooltip: 'txt_speech_license_title'.tr,
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Text('txt_speech_license_title'.tr),
                content: const Text(LocalTtsModelManifest.licenseNotice),
                actions: [
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse(LocalTtsModelManifest.licenseUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Text('txt_speech_license_source'.tr),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text('confirm'.tr),
                  ),
                ],
              ),
            ),
          ),
          subtitle: Text(
            'txt_speech_model_installed_size'.trParams(<String, String>{
              'size': _formatBytes(state.installedBytes),
            }),
          ),
        );
      case LocalTtsModelPhase.error:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text('txt_speech_model_failed'.tr),
          subtitle: Text(state.message ?? ''),
          trailing: TextButton(
            onPressed: () => _installBundledModel(store),
            child: Text('txt_speech_model_retry'.tr),
          ),
        );
    }
  }

  Future<void> _installBundledModel(LocalTtsModelStoreBase store) async {
    try {
      await store.installBundledModel();
    } catch (_) {}
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
