import 'package:flutter/material.dart';

import '../state/download_controller.dart';

/// Shown above the navigation bar while something is playing on the TV.
class CastBar extends StatelessWidget {
  const CastBar({super.key, required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.cast;
    if (!s.active) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final busy = s.status == 'connecting' || s.status == 'loading';
    final position = s.count > 1 ? '  ·  ${s.index + 1}/${s.count}' : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            child: Row(
              children: [
                Icon(Icons.cast_connected_rounded, color: cs.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.title ?? 'Playing on TV',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${s.device}$position',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelSmall?.copyWith(color: cs.onPrimaryContainer.withValues(alpha: 0.75)),
                      ),
                    ],
                  ),
                ),
                if (s.count > 1)
                  IconButton(
                    tooltip: 'Previous',
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: () => controller.castControl('previous'),
                  ),
                IconButton(
                  tooltip: s.paused ? 'Play' : 'Pause',
                  icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  onPressed: busy ? null : () => controller.castControl(s.paused ? 'resume' : 'pause'),
                ),
                if (s.count > 1)
                  IconButton(
                    tooltip: 'Next',
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: () => controller.castControl('next'),
                  ),
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop_rounded),
                  onPressed: () => controller.castControl('stop'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
