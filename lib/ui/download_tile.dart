import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_task.dart';
import '../models/quality.dart';
import '../state/download_controller.dart';
import '../utils/format_utils.dart';
import '../utils/url_utils.dart';
import 'theme.dart';

/// One download, shown the same way on Home (recent) and on the Downloads page.
/// Completed items play on tap, like a browser's download manager.
class DownloadTile extends StatelessWidget {
  const DownloadTile({
    super.key,
    required this.task,
    required this.controller,
    this.selectable = false,
  });

  final DownloadTask task;
  final DownloadController controller;

  /// On the Downloads page: long-press starts selecting several items.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = task;
    final c = controller;
    final missing = t.status == TaskStatus.completed && c.isMissing(t);
    final playable = t.status == TaskStatus.completed && !missing;
    final selecting = selectable && c.selecting;
    final selected = selectable && c.isSelected(t.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(cs.primary.withValues(alpha: 0.16), cs.surfaceContainerHigh)
            : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selecting ? () => c.toggleSelect(t.id) : (playable ? () => c.play(t) : null),
        onLongPress: selectable ? () => c.toggleSelect(t.id) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Leading(task: t, missing: missing, selected: selected),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _meta(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    ..._status(context, t, missing),
                  ],
                ),
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 12, 0),
                  child: Icon(
                    selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    color: selected ? cs.primary : cs.outline,
                  ),
                )
              else
                _Actions(task: t, controller: c, playable: playable, missing: missing),
            ],
          ),
        ),
      ),
    );
  }

  static String _meta(DownloadTask t) {
    final parts = <String>[
      '${t.kind.label} ${t.quality.label}',
      if (t.status == TaskStatus.completed) Fmt.bytes(t.fileSize),
      if (t.status.isFinished) Fmt.time(t.when),
    ].where((s) => s.trim().isNotEmpty);
    return parts.join('  ·  ');
  }

  List<Widget> _status(BuildContext context, DownloadTask t, bool missing) {
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    switch (t.status) {
      case TaskStatus.queued:
        return [_line(t.note ?? 'Waiting in queue', small?.copyWith(color: t.note != null ? cs.tertiary : cs.onSurfaceVariant))];
      case TaskStatus.fetching:
        return [
          const SizedBox(height: 8),
          _bar(null),
          _line('Getting video info...', small?.copyWith(color: cs.primary)),
        ];
      case TaskStatus.downloading:
        final eta = t.etaSeconds >= 0 ? '  ·  ${UrlUtils.formatEta(t.etaSeconds)} left' : '';
        return [
          const SizedBox(height: 8),
          _bar(t.progress <= 0 ? null : t.progress / 100),
          _line('${t.progress.toStringAsFixed(0)}%$eta', small?.copyWith(color: cs.primary)),
        ];
      case TaskStatus.converting:
        return [
          const SizedBox(height: 8),
          _bar(null),
          _line('Converting...', small?.copyWith(color: cs.primary)),
        ];
      case TaskStatus.completed:
        if (missing) {
          return [_line('File is no longer on this device', small?.copyWith(color: cs.tertiary))];
        }
        if (t.savedTo == null) return const [];
        return [_line('Saved in ${t.savedTo}', small?.copyWith(color: cs.onSurfaceVariant))];
      case TaskStatus.failed:
        return [_line(t.error ?? 'Download failed', small?.copyWith(color: cs.error), lines: 3)];
      case TaskStatus.cancelled:
        return [_line('Cancelled', small?.copyWith(color: cs.onSurfaceVariant))];
    }
  }

  static Widget _line(String s, TextStyle? style, {int lines = 1}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, style: style),
      );

  static Widget _bar(double? value) => LinearProgressIndicator(
        value: value,
        minHeight: 5,
        borderRadius: BorderRadius.circular(4),
      );
}

class _Leading extends StatelessWidget {
  const _Leading({required this.task, required this.missing, required this.selected});

  final DownloadTask task;
  final bool missing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isAudio = task.kind == MediaKind.mp3;
    final accent = isAudio ? Brand.violet : Brand.coral;

    if (selected) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(16)),
        child: Icon(Icons.check_rounded, color: cs.onPrimary, size: 28),
      );
    }

    Widget? badge;
    if (task.status == TaskStatus.completed) {
      badge = _badge(missing ? Icons.help_rounded : Icons.check_rounded, missing ? cs.tertiary : Colors.green);
    } else if (task.status == TaskStatus.failed) {
      badge = _badge(Icons.priority_high_rounded, cs.error);
    } else if (task.status == TaskStatus.cancelled) {
      badge = _badge(Icons.close_rounded, cs.outline);
    }

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                isAudio ? Icons.music_note_rounded : Icons.movie_rounded,
                color: accent,
                size: 26,
              ),
            ),
          ),
          if (task.status == TaskStatus.downloading)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: CircularProgressIndicator(
                  value: task.progress <= 0 ? null : task.progress / 100,
                  strokeWidth: 3,
                  color: accent,
                ),
              ),
            ),
          if (badge != null) Positioned(right: -4, bottom: -4, child: badge),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, Color color) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black.withValues(alpha: 0.15), width: 1),
        ),
        child: Icon(icon, size: 13, color: Colors.white),
      );
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.task,
    required this.controller,
    required this.playable,
    required this.missing,
  });

  final DownloadTask task;
  final DownloadController controller;
  final bool playable;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final t = task;
    final c = controller;

    if (t.status.isActive) {
      return IconButton(
        tooltip: 'Cancel',
        icon: const Icon(Icons.close_rounded),
        onPressed: () => c.cancel(t.id),
      );
    }

    final primary = switch (t.status) {
      TaskStatus.completed => IconButton.filledTonal(
          tooltip: 'Play',
          icon: const Icon(Icons.play_arrow_rounded),
          onPressed: playable ? () => c.play(t) : null,
        ),
      _ => IconButton.filledTonal(
          tooltip: 'Retry',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => c.retry(t.id),
        ),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        primary,
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert_rounded),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onSelected: (v) => _onMenu(context, v),
          itemBuilder: (_) => [
            if (t.status == TaskStatus.completed && !missing) ...[
              _item('play', Icons.play_arrow_rounded, 'Play'),
              _item('share', Icons.share_rounded, 'Share'),
            ],
            if (t.status != TaskStatus.completed) _item('retry', Icons.refresh_rounded, 'Retry'),
            _item('copy', Icons.link_rounded, 'Copy link'),
            const PopupMenuDivider(),
            _item('remove', Icons.playlist_remove_rounded, 'Remove from list'),
            if (t.status == TaskStatus.completed)
              _item('delete', Icons.delete_outline_rounded, 'Delete from device', danger: true),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label, {bool danger = false}) {
    return PopupMenuItem<String>(
      value: value,
      child: Builder(builder: (context) {
        final color = danger ? Theme.of(context).colorScheme.error : null;
        return Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: color)),
          ],
        );
      }),
    );
  }

  Future<void> _onMenu(BuildContext context, String value) async {
    final c = controller;
    final t = task;
    switch (value) {
      case 'play':
        await c.play(t);
      case 'share':
        await c.share(t);
      case 'retry':
        await c.retry(t.id);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: t.url));
        c.notice('Link copied');
      case 'remove':
        c.remove(t);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete file?'),
            content: Text('"${t.displayTitle}" will be permanently deleted from your device.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) await c.deleteFile(t);
    }
  }
}
