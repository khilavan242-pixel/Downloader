import 'package:flutter/material.dart';

import '../models/quality.dart';

/// MP3 / MP4 switch plus the quality list ordered from lowest to highest.
class QualitySelector extends StatelessWidget {
  const QualitySelector({
    super.key,
    required this.kind,
    required this.selected,
    required this.onKind,
    required this.onQuality,
  });

  final MediaKind kind;
  final QualityOption selected;
  final ValueChanged<MediaKind> onKind;
  final ValueChanged<QualityOption> onQuality;

  @override
  Widget build(BuildContext context) {
    final options = QualityOption.forKind(kind);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<MediaKind>(
            showSelectedIcon: false,
            segments: [
              for (final k in MediaKind.values)
                ButtonSegment(
                  value: k,
                  icon: Icon(k == MediaKind.mp3 ? Icons.music_note : Icons.movie_outlined),
                  label: Text('${k.label}  ·  ${k.subtitle}'),
                ),
            ],
            selected: {kind},
            onSelectionChanged: (s) => onKind(s.first),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Quality', style: text.titleSmall),
            const SizedBox(width: 8),
            Text('low  →  high', style: text.labelMedium?.copyWith(color: Theme.of(context).hintColor)),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in options)
              ChoiceChip(
                label: Text(o.label),
                selected: o.value == selected.value,
                onSelected: (_) => onQuality(o),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(selected.hint, style: text.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      ],
    );
  }
}
