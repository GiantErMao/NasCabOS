import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../../core/routes/app_routes.dart';
import '../../controller/video_detail_controller.dart';

class VideoDetailMoviePartsSection extends StatelessWidget {
  final VideoDetailController ctrl;

  const VideoDetailMoviePartsSection({super.key, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final parts = ctrl.movieParts;
    if (parts.length < 2) return const SizedBox.shrink();
    final playlist = ctrl.buildMoviePartPlaylist();
    final duration = (ctrl.item?['movie_total_duration'] as num?)?.toInt() ?? 0;
    final count = parts.length.toString();
    final totalMinutes = Duration(seconds: duration).inMinutes.toString();
    final title = duration > 0
        ? 'video_detail_movie_parts_duration'.trParams({'count': count, 'minutes': totalMinutes})
        : 'video_detail_movie_parts'.trParams({'count': count});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(parts.length, (index) {
            final part = parts[index];
            final seconds = (part['duration'] as num?)?.toInt() ?? 0;
            final number = part['number']?.toString() ?? (index + 1).toString();
            final label = seconds > 0
                ? 'video_detail_movie_part_duration'.trParams({
                    'number': number,
                    'minutes': Duration(seconds: seconds).inMinutes.toString(),
                  })
                : 'video_detail_movie_part'.trParams({'number': number});
            return ActionChip(
              avatar: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(label),
              onPressed: () => AppRoutes.toVideoPlayer(
                playlist: playlist,
                initialIndex: index,
                ignoreFindSub: 0,
              ),
            );
          }),
        ),
      ],
    );
  }
}
