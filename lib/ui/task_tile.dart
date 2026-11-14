import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../utils/url_utils.dart';

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task, required this.onCancel, required this.onRetry});

  final DownloadTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = task;

    final (IconData icon, Color color, String status) = switch (t.status) {
      TaskStatus.queued => (Icons.schedule, cs.onSurfaceVariant, 'Waiting in queue'),
      TaskStatus.fetching => (Icons.search, cs.primary, 'Getting video info...'),
      TaskStatus.downloading => (
          Icons.downloading,
          cs.primary,
          '${t.progress.toStringAsFixed(0)}%'
              '${t.etaSeconds >= 0 ? '  ·  ${UrlUtils.formatEta(t.etaSeconds)} left' : ''}',
        ),
      TaskStatus.converting => (Icons.sync, cs.primary, 'Converting...'),
      TaskStatus.completed => (Icons.check_circle, Colors.green, 'Saved to ${t.savedTo ?? 'device'}'),
      TaskStatus.failed => (Icons.error_outline, cs.error, t.error ?? 'Failed'),
      TaskStatus.cancelled => (Icons.cancel_outlined, cs.onSurfaceVariant, 'Cancelled'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${t.kind.label} · ${t.quality.label}${t.playlist ? ' · playlist' : ''}',
                    style: text.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  if (t.status == TaskStatus.downloading || t.status == TaskStatus.converting)
                    LinearProgressIndicator(
                      value: t.status == TaskStatus.converting || t.progress <= 0 ? null : t.progress / 100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  if (t.status == TaskStatus.fetching) LinearProgressIndicator(borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 4),
                  Text(status, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: color)),
                ],
              ),
            ),
            if (t.status.isActive)
              IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: onCancel)
            else if (t.status == TaskStatus.failed || t.status == TaskStatus.cancelled)
              IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: onRetry)
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
