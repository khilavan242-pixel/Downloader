import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'folder_picker_sheet.dart';
import 'logo_mark.dart';
import 'quality_selector.dart';
import 'task_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  StreamSubscription<String>? _msgSub;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _msgSub = c.messages.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgSub?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.onAppResumed();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) return;
    setState(() => _input.text = _input.text.isEmpty ? text : '${_input.text}\n$text');
  }

  Future<void> _download() async {
    FocusScope.of(context).unfocus();
    var text = _input.text;
    if (UrlUtils.extractUrls(text).isEmpty) {
      // One-tap behaviour: fall back to whatever link is on the clipboard.
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      text = clip;
    }
    final n = await c.addFromText(text);
    if (n > 0) _input.clear();
  }

  Future<void> _updateEngine() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Updating yt-dlp...')));
    try {
      await c.updateEngine();
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final tasks = c.tasks;
        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LogoMark(size: 30),
                SizedBox(width: 10),
                Text('Tapnab', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.3)),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'update') _updateEngine();
                  if (v == 'clear') c.clearFinished();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'update', child: Text('Update yt-dlp engine')),
                  PopupMenuItem(
                    value: 'clear',
                    enabled: c.hasFinished,
                    child: const Text('Clear finished'),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                TextField(
                  controller: _input,
                  minLines: 2,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: 'Paste one or many links',
                    hintText: 'https://youtu.be/...\nhttps://www.youtube.com/playlist?list=...',
                    suffixIcon: IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _paste,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                QualitySelector(
                  kind: c.kind,
                  selected: c.quality,
                  onKind: c.setKind,
                  onQuality: c.setQuality,
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(c.folder == null ? Icons.download_for_offline_outlined : Icons.folder, color: cs.primary),
                    title: Text(c.folder?.name ?? 'Default location'),
                    subtitle: Text(
                      c.folder?.location ?? (c.kind.name == 'mp3' ? 'Music/Tapnab' : 'Movies/Tapnab'),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showFolderPicker(context, c),
                  ),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text('Download whole playlist'),
                  subtitle: const Text('Off: only the single video in the link'),
                  value: c.playlist,
                  onChanged: c.setPlaylist,
                ),
                const SizedBox(height: 4),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: _download,
                  icon: const Icon(Icons.download),
                  label: Text(
                    'Download ${c.kind.label} · ${c.quality.label}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 24),
                if (tasks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Downloads', style: Theme.of(context).textTheme.titleMedium),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'Tip: in YouTube tap Share, then Tapnab, and the download starts with your saved choices.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                for (final t in tasks)
                  TaskTile(
                    key: ValueKey(t.id),
                    task: t,
                    onCancel: () => c.cancel(t.id),
                    onRetry: () => c.retry(t.id),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
