import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/playlist_entry.dart';
import '../state/download_controller.dart';
import 'theme.dart';

/// Shows every song of a playlist with checkboxes, so only the wanted ones are
/// downloaded. Pops `true` when downloads were started.
class PlaylistPickerPage extends StatefulWidget {
  const PlaylistPickerPage({super.key, required this.controller, required this.url});

  final DownloadController controller;
  final String url;

  @override
  State<PlaylistPickerPage> createState() => _PlaylistPickerPageState();
}

class _PlaylistPickerPageState extends State<PlaylistPickerPage> {
  List<PlaylistEntry>? _entries;
  String? _error;
  final Set<int> _picked = {};
  bool _busy = false;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final list = await c.fetchPlaylist(widget.url);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _picked
          ..clear()
          ..addAll([
            for (var i = 0; i < list.length; i++)
              if (!c.isDownloaded(list[i].url)) i,
          ]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is PlatformException ? (e.message ?? 'Could not read the playlist.') : '$e');
    }
  }

  String get _name {
    final e = _entries;
    if (e == null) return 'Playlist';
    final n = e.map((x) => x.playlist).firstWhere((s) => s.isNotEmpty, orElse: () => '');
    return n.isEmpty ? 'Playlist' : n;
  }

  Future<void> _download() async {
    final list = _entries;
    if (list == null || _picked.isEmpty || _busy) return;
    setState(() => _busy = true);
    final chosen = [for (final i in _picked.toList()..sort()) list[i]];
    await c.addEntries(chosen, playlistName: _name);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = _entries;
    final allPicked = list != null && _picked.length == list.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(list == null ? 'Playlist' : _name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (list != null && list.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (allPicked) {
                  _picked.clear();
                } else {
                  _picked
                    ..clear()
                    ..addAll(List<int>.generate(list.length, (i) => i));
                }
              }),
              child: Text(allPicked ? 'Select none' : 'Select all'),
            ),
        ],
      ),
      body: _body(context),
      bottomNavigationBar: list == null || list.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: _picked.isEmpty ? null : Brand.gradient,
                    color: _picked.isEmpty ? cs.surfaceContainerHighest : null,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: SizedBox(
                    height: 56,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: _picked.isEmpty || _busy ? null : _download,
                      child: Center(
                        child: Text(
                          _picked.isEmpty
                              ? 'Choose songs to download'
                              : 'Download ${_picked.length} ${c.kind.label} · ${c.quality.label}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _picked.isEmpty ? cs.onSurfaceVariant : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _body(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = _entries;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 44, color: cs.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (list == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Reading the playlist...'),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return const Center(child: Text('No songs found in this playlist.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final e = list[i];
        final done = c.isDownloaded(e.url);
        return CheckboxListTile(
          value: _picked.contains(i),
          onChanged: (v) => setState(() {
            if (v == true) {
              _picked.add(i);
            } else {
              _picked.remove(i);
            }
          }),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(e.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (e.duration.isNotEmpty) e.duration,
              if (done) 'Already downloaded',
            ].join('  ·  '),
            style: TextStyle(color: done ? cs.tertiary : cs.onSurfaceVariant),
          ),
        );
      },
    );
  }
}
