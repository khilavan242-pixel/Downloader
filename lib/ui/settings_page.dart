import 'package:flutter/material.dart';

import '../state/download_controller.dart';
import 'info_dialogs.dart';

/// App settings. Everything saves immediately.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _version = '...';
  int _lastUpdate = 0;
  bool _updating = false;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await c.engineInfo();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _lastUpdate = info.lastUpdate;
      });
    } catch (_) {
      if (mounted) setState(() => _version = 'unavailable');
    }
  }

  Future<void> _updateNow() async {
    setState(() => _updating = true);
    try {
      await c.updateEngine();
    } catch (_) {
      c.notice('Update failed. Check your internet and try again.');
    }
    await _loadInfo();
    if (mounted) setState(() => _updating = false);
  }

  String get _lastText {
    if (_lastUpdate <= 0) return 'Never updated automatically';
    final d = DateTime.fromMillisecondsSinceEpoch(_lastUpdate);
    final days = DateTime.now().difference(d).inDays;
    return days == 0 ? 'Updated today' : 'Updated $days ${days == 1 ? 'day' : 'days'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.settings;
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text('Settings', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
              _Section(
                title: 'Downloads',
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.wifi_rounded),
                    title: const Text('Wi-Fi only'),
                    subtitle: const Text('Wait for Wi-Fi instead of using mobile data'),
                    value: s.wifiOnly,
                    onChanged: (v) => c.updateSettings((x) => x.wifiOnly = v),
                  ),
                  ListTile(
                    leading: const Icon(Icons.speed_rounded),
                    title: const Text('Downloads at the same time'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 2, label: Text('2')),
                          ButtonSegment(value: 3, label: Text('3')),
                          ButtonSegment(value: 4, label: Text('4')),
                        ],
                        selected: {s.parallel},
                        onSelectionChanged: (v) => c.updateSettings((x) => x.parallel = v.first),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.folder_copy_rounded),
                    title: const Text('Playlist folders'),
                    subtitle: const Text('Save a playlist\'s songs in a folder named after it'),
                    value: s.playlistFolders,
                    onChanged: (v) => c.updateSettings((x) => x.playlistFolders = v),
                  ),
                ],
              ),
              _Section(
                title: 'Files',
                children: [
                  ListTile(
                    leading: const Icon(Icons.text_fields_rounded),
                    title: const Text('File names'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'original', label: Text('Original')),
                          ButtonSegment(value: 'clean', label: Text('Clean')),
                          ButtonSegment(value: 'short', label: Text('Short')),
                        ],
                        selected: {s.nameStyle},
                        onSelectionChanged: (v) => c.updateSettings((x) => x.nameStyle = v.first),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                    child: Text(
                      switch (s.nameStyle) {
                        'original' => 'Exactly the YouTube title.',
                        'short' => 'Clean, and cut to about 40 characters.',
                        _ => 'Removes "(Official Video)" tags and the "| Channel" ending.',
                      },
                      style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.album_rounded),
                    title: const Text('Cover art in MP3'),
                    subtitle: const Text('Adds the video thumbnail as album art'),
                    value: s.coverArt,
                    onChanged: (v) => c.updateSettings((x) => x.coverArt = v),
                  ),
                ],
              ),
              _Section(
                title: 'Download engine',
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.autorenew_rounded),
                    title: const Text('Update automatically'),
                    subtitle: const Text('Keeps yt-dlp fresh, about once a day'),
                    value: s.autoUpdate,
                    onChanged: (v) => c.updateSettings((x) => x.autoUpdate = v),
                  ),
                  ListTile(
                    leading: const Icon(Icons.system_update_alt_rounded),
                    title: Text('yt-dlp $_version'),
                    subtitle: Text(_lastText),
                    trailing: _updating
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : FilledButton.tonal(onPressed: _updateNow, child: const Text('Update now')),
                  ),
                ],
              ),
              _Section(
                title: 'Appearance',
                children: [
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Theme'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('System')),
                          ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                          ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                        ],
                        selected: {s.themeMode},
                        onSelectionChanged: (v) => c.updateSettings((x) => x.themeMode = v.first),
                      ),
                    ),
                  ),
                ],
              ),
              _Section(
                title: 'Help',
                children: [
                  ListTile(
                    leading: const Icon(Icons.help_outline_rounded),
                    title: const Text('How to use'),
                    onTap: () => showHowTo(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('About Tapnab'),
                    onTap: () => showAbout(context),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              title.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(22),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
