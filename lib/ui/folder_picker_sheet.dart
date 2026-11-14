import 'package:flutter/material.dart';

import '../models/save_folder.dart';
import '../state/download_controller.dart';

/// Acode-style "Select folder" dialog: saved folders (tap to choose, X to
/// forget) and a final row that opens the system folder picker.
Future<void> showFolderPicker(BuildContext context, DownloadController c) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FolderDialog(controller: c),
  );
}

class _FolderDialog extends StatelessWidget {
  const _FolderDialog({required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final folders = controller.folders;
        return AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          title: const Text('Select folder', style: TextStyle(fontWeight: FontWeight.w700)),
          contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                _Row(
                  icon: Icons.download_for_offline_outlined,
                  title: 'Default location',
                  subtitle: 'Music/Tapnab and Movies/Tapnab',
                  selected: controller.folder == null,
                  onTap: () {
                    controller.selectFolder(null);
                    Navigator.pop(context);
                  },
                ),
                for (final f in folders)
                  _Row(
                    icon: Icons.folder,
                    title: f.name,
                    subtitle: f.location,
                    selected: controller.folder == f,
                    onTap: () {
                      controller.selectFolder(f);
                      Navigator.pop(context);
                    },
                    onRemove: () => _confirmRemove(context, f),
                  ),
                const Divider(height: 1),
                _Row(
                  icon: Icons.create_new_folder_outlined,
                  title: 'Select folder',
                  subtitle: 'Pick any folder, SD card or USB pendrive',
                  onTap: () async {
                    final nav = Navigator.of(context);
                    await controller.addFolder();
                    nav.pop();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmRemove(BuildContext context, SaveFolder f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove folder?'),
        content: Text(
          '"${f.name}" is only removed from this list. Your files stay where they are.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await controller.removeFolder(f);
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onRemove,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: selected ? cs.primaryContainer.withValues(alpha: 0.5) : null,
      leading: Icon(icon, color: selected ? cs.primary : cs.onSurfaceVariant),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: onRemove == null
          ? (selected ? Icon(Icons.check_circle, color: cs.primary) : null)
          : IconButton(
              tooltip: 'Remove from list',
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
    );
  }
}
