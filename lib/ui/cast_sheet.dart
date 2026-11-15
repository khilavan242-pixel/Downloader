import 'package:flutter/material.dart';

import '../models/cast.dart';
import '../models/download_task.dart';
import '../state/download_controller.dart';

/// Lets the user choose a TV / set-top box, then plays [tasks] (saved files) on it.
Future<void> castDownloads(BuildContext context, DownloadController c, List<DownloadTask> tasks) async {
  final device = await pickCastDevice(context, c);
  if (device != null) await c.castTasks(device, tasks);
}

/// Lets the user choose a TV / set-top box, then plays YouTube [urls] on it
/// straight from YouTube, with no download.
Future<void> castYoutube(BuildContext context, DownloadController c, List<String> urls) async {
  final device = await pickCastDevice(context, c);
  if (device != null) await c.castLinks(device, urls);
}

/// Scans the Wi-Fi for DLNA players and returns the one the user taps.
Future<CastDevice?> pickCastDevice(BuildContext context, DownloadController c) {
  return showModalBottomSheet<CastDevice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DeviceSheet(controller: c),
  );
}

class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet({required this.controller});

  final DownloadController controller;

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  bool _scanning = true;
  List<CastDevice> _devices = const [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    List<CastDevice> found = const [];
    try {
      found = await widget.controller.discoverDevices();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _devices = found;
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Play on TV', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (_scanning)
                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                else
                  IconButton(tooltip: 'Search again', icon: const Icon(Icons.refresh_rounded), onPressed: _scan),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Turn on DLNA on your TV or set-top box. Phone and TV must use the same Wi-Fi.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_scanning && _devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Looking for devices...')),
              )
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No TV found.\nCheck the Wi-Fi and that DLNA mode is on, then search again.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else
              for (final d in _devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    child: ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      leading: const Icon(Icons.tv_rounded),
                      title: Text(d.name),
                      trailing: const Icon(Icons.cast_rounded),
                      onTap: () => Navigator.of(context).pop(d),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
