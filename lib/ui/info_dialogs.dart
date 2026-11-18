import 'package:flutter/material.dart';

import 'logo_mark.dart';

/// "How to use" sheet, shared by Home and Settings.
void showHowTo(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to use Tapnab', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            const _Step(n: 1, text: 'In YouTube tap Share, then Tapnab. A small window opens right over YouTube.'),
            const _Step(n: 2, text: 'Pick MP3 or MP4 and a quality, then tap Download.'),
            const _Step(n: 3, text: 'Or open the Browse tab, find a video, and tap the Download button.'),
            const _Step(n: 4, text: 'Playlist links let you choose which songs to download.'),
            const _Step(n: 5, text: 'Follow progress in Downloads. Tap a finished item to play it.'),
            const _Step(n: 6, text: 'Long-press items to select several: play, share or delete them together.'),
            const _Step(n: 7, text: 'Play on TV: turn on DLNA on your TV or set-top box (same Wi-Fi). In Browse tap the cast icon once to connect; then tap any video and it plays on the TV, followed by related videos. A floating window (drag it, tap to open) follows you while the TV plays. You stay connected until you choose Disconnect. The menu also plays local files from your phone.'),
          ],
        ),
      ),
    ),
  );
}

void showAbout(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'Tapnab',
    applicationVersion: '1.9.1',
    applicationIcon: const LogoMark(size: 48),
    children: const [
      SizedBox(height: 12),
      Text(
        'Download only content you have the right to save: your own uploads, '
        'Creative Commons or public-domain videos, or anything the owner permits.',
      ),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: cs.primaryContainer,
            child: Text(
              '$n',
              style: TextStyle(fontSize: 13, color: cs.onPrimaryContainer, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
