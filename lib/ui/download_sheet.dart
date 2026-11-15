import 'package:flutter/material.dart';

import '../models/quality.dart';
import '../state/download_controller.dart';
import 'cast_sheet.dart';
import 'link_actions.dart';
import 'theme.dart';

/// Bottom sheet used by the Browse tab: choose MP3 / MP4 and quality for the
/// page that is open, then download it.
Future<void> showDownloadSheet(BuildContext context, DownloadController c, String url) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _DownloadSheet(controller: c, url: url, hostContext: context),
  );
}

class _DownloadSheet extends StatelessWidget {
  const _DownloadSheet({required this.controller, required this.url, required this.hostContext});

  final DownloadController controller;
  final String url;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Download this', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 16),
              SegmentedButton<MediaKind>(
                showSelectedIcon: false,
                segments: [
                  for (final k in MediaKind.values)
                    ButtonSegment(value: k, label: Text('${k.label}  ${k.subtitle}')),
                ],
                selected: {c.kind},
                onSelectionChanged: (s) => c.setKind(s.first),
              ),
              const SizedBox(height: 14),
              Text('Quality', style: text.labelLarge),
              const SizedBox(height: 8),
              SizedBox(
                height: 42,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: c.qualityOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final o = c.qualityOptions[i];
                    return ChoiceChip(
                      label: Text(o.label),
                      selected: o.value == c.quality.value,
                      onSelected: (_) => c.setQuality(o),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              DecoratedBox(
                decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(28)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: () async {
                    Navigator.of(context).pop();
                    if (!hostContext.mounted) return;
                    final n = await downloadLinks(hostContext, c, [url]);
                    if (n > 0 && hostContext.mounted) c.notice('Download started');
                  },
                  child: SizedBox(
                    height: 56,
                    child: Center(
                      child: Text(
                        'Download ${c.kind.label} · ${c.quality.label}',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.tv_rounded),
                  label: const Text('Play on TV instead'),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    if (hostContext.mounted) await castYoutube(hostContext, c, [url]);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
