import 'package:flutter/material.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'playlist_picker_page.dart';

/// Starts downloads for [urls], asking first where it matters:
///  * a video that was already downloaded (or is queued) asks before repeating,
///  * a playlist opens the song picker.
/// Returns how many links were started or handed to the picker and confirmed.
Future<int> downloadLinks(BuildContext context, DownloadController c, List<String> urls) async {
  var started = 0;
  final playlists = <String>[];

  for (final url in urls) {
    if (_wantsPicker(c, url)) {
      playlists.add(url);
      continue;
    }
    if (c.existingFor(url) != null) {
      if (!context.mounted) return started;
      if (!await _askAgain(context, c, url)) continue;
    }
    await c.addUrl(url);
    started++;
  }

  for (final url in playlists) {
    if (!context.mounted) break;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => PlaylistPickerPage(controller: c, url: url)),
    );
    if (ok == true) started++;
  }
  return started;
}

/// A pure playlist page always opens the picker; a video that merely sits
/// inside a playlist does so only when "Pick from playlist" is on.
bool _wantsPicker(DownloadController c, String url) {
  if (!UrlUtils.hasPlaylist(url)) return false;
  return UrlUtils.isPlaylistPage(url) || c.playlist;
}

Future<bool> _askAgain(BuildContext context, DownloadController c, String url) async {
  final t = c.existingFor(url);
  final running = t?.status.isActive ?? false;
  final answer = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.copy_all_rounded),
      title: Text(running ? 'Already in the queue' : 'Already downloaded'),
      content: Text(
        running
            ? '"${t?.displayTitle ?? url}" is already being downloaded as ${c.kind.label}.'
            : '"${t?.displayTitle ?? url}" is already on your device as ${c.kind.label}. Download it again?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Download again')),
      ],
    ),
  );
  return answer == true;
}
