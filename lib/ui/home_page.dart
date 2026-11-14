import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/quality.dart';
import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'download_tile.dart';
import 'folder_picker_sheet.dart';
import 'logo_mark.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller, required this.onOpenDownloads});

  final DownloadController controller;
  final VoidCallback onOpenDownloads;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  String? _clipUrl;
  String? _dismissedClip;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  /// Offers a link that is already on the clipboard.
  Future<void> _checkClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final urls = UrlUtils.extractUrls(text);
    final url = urls.isEmpty ? null : urls.first;
    if (!mounted) return;
    setState(() {
      _clipUrl = (url != null && url != _dismissedClip && !_input.text.contains(url)) ? url : null;
    });
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (text.trim().isEmpty) return;
    setState(() {
      _input.text = _input.text.isEmpty ? text : '${_input.text}\n$text';
      _dismissedClip = _clipUrl;
      _clipUrl = null;
    });
  }

  Future<void> _download() async {
    FocusScope.of(context).unfocus();
    var text = _input.text;
    if (UrlUtils.extractUrls(text).isEmpty && _clipUrl != null) text = _clipUrl!;
    final n = await c.addFromText(text);
    if (n == 0 || !mounted) return;
    _input.clear();
    setState(() {
      _dismissedClip = _clipUrl;
      _clipUrl = null;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(n == 1 ? 'Added to downloads' : '$n links added to downloads'),
        action: SnackBarAction(label: 'VIEW', onPressed: widget.onOpenDownloads),
      ));
  }

  Future<void> _onMenu(String value) async {
    switch (value) {
      case 'update':
        final messenger = ScaffoldMessenger.of(context);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Updating yt-dlp...')));
        try {
          await c.updateEngine();
        } catch (e) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
        }
      case 'how':
        _showHowTo();
      case 'about':
        showAboutDialog(
          context: context,
          applicationName: 'Tapnab',
          applicationVersion: '1.0.0',
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
  }

  void _showHowTo() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to use Tapnab', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            const _Step(n: 1, text: 'In YouTube tap Share, then choose Tapnab. Or paste links here.'),
            const _Step(n: 2, text: 'Pick MP3 or MP4 and a quality from low to high.'),
            const _Step(n: 3, text: 'Tap Download. Follow progress in the Downloads tab.'),
            const _Step(n: 4, text: 'Tap a finished item to play it. Use the menu to share or delete.'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final recent = c.recent;
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              _Header(onMenu: _onMenu),
              const SizedBox(height: 22),
              if (_clipUrl != null) ...[
                _ClipboardBanner(
                  url: _clipUrl!,
                  onUse: () {
                    setState(() {
                      _input.text = _clipUrl!;
                      _dismissedClip = _clipUrl;
                      _clipUrl = null;
                    });
                  },
                  onDismiss: () => setState(() {
                    _dismissedClip = _clipUrl;
                    _clipUrl = null;
                  }),
                ),
                const SizedBox(height: 12),
              ],
              _LinkCard(controller: _input, onPaste: _paste),
              const SizedBox(height: 20),
              Row(
                children: [
                  for (final k in MediaKind.values) ...[
                    Expanded(
                      child: _FormatCard(
                        kind: k,
                        selected: c.kind == k,
                        onTap: () => c.setKind(k),
                      ),
                    ),
                    if (k != MediaKind.values.last) const SizedBox(width: 12),
                  ],
                ],
              ),
              const SizedBox(height: 22),
              _QualityRow(controller: c),
              const SizedBox(height: 18),
              _SettingsCard(controller: c),
              const SizedBox(height: 20),
              _GradientButton(
                label: 'Download ${c.kind.label} · ${c.quality.label}',
                onTap: _download,
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Text(
                    'Recent',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (recent.isNotEmpty)
                    TextButton(onPressed: widget.onOpenDownloads, child: const Text('See all')),
                ],
              ),
              const SizedBox(height: 6),
              if (recent.isEmpty)
                const _TipCard()
              else
                for (final t in recent) DownloadTile(key: ValueKey(t.id), task: t, controller: c),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onMenu});

  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        const LogoMark(size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tapnab', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              Text(
                'Paste a link. Get music or video.',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Menu',
          icon: const Icon(Icons.menu_rounded),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onSelected: onMenu,
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'update',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.system_update_alt_rounded),
                title: Text('Update yt-dlp engine'),
              ),
            ),
            PopupMenuItem(
              value: 'how',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.help_outline_rounded),
                title: Text('How to use'),
              ),
            ),
            PopupMenuItem(
              value: 'about',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.info_outline_rounded),
                title: Text('About'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ClipboardBanner extends StatelessWidget {
  const _ClipboardBanner({required this.url, required this.onUse, required this.onDismiss});

  final String url;
  final VoidCallback onUse;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.content_paste_go_rounded, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Link found in clipboard', style: TextStyle(fontWeight: FontWeight.w600)),
                Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(onPressed: onUse, child: const Text('Use')),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.controller, required this.onPaste});

  final TextEditingController controller;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Paste one or many links\nVideos and playlists both work',
            ),
          ),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: onPaste,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('Paste'),
              ),
              const Spacer(),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : TextButton(onPressed: controller.clear, child: const Text('Clear')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormatCard extends StatelessWidget {
  const _FormatCard({required this.kind, required this.selected, required this.onTap});

  final MediaKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isAudio = kind == MediaKind.mp3;
    final accent = isAudio ? Brand.violet : Brand.coral;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? accent : cs.outlineVariant, width: selected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: selected ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(isAudio ? Icons.music_note_rounded : Icons.movie_rounded, color: accent),
                ),
                const Spacer(),
                if (selected) Icon(Icons.check_circle_rounded, color: accent),
              ],
            ),
            const SizedBox(height: 12),
            Text(kind.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(
              isAudio ? 'Audio only' : 'Video with sound',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Quality', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('Low', style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            Icon(Icons.arrow_right_alt_rounded, color: cs.onSurfaceVariant),
            Text('High', style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 10),
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
        const SizedBox(height: 6),
        Text(c.quality.hint, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = controller;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            leading: Icon(c.folder == null ? Icons.download_for_offline_outlined : Icons.folder_rounded, color: cs.primary),
            title: const Text('Save to'),
            subtitle: Text(
              c.folder?.name ?? (c.kind == MediaKind.mp3 ? 'Music/Tapnab' : 'Movies/Tapnab'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showFolderPicker(context, c),
          ),
          Divider(height: 1, indent: 16, endIndent: 16, color: cs.outlineVariant),
          SwitchListTile(
            secondary: Icon(Icons.queue_music_rounded, color: cs.primary),
            title: const Text('Whole playlist'),
            subtitle: const Text('Download every song in a playlist link'),
            value: c.playlist,
            onChanged: c.setPlaylist,
          ),
        ],
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(30);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Brand.violet.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.download_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.share_rounded, color: cs.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Tip: in YouTube tap Share, then Tapnab. The download starts with your saved choices.',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
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
            child: Text('$n', style: TextStyle(fontSize: 13, color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
