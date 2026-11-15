import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../models/quality.dart';
import '../state/download_controller.dart';
import '../utils/format_utils.dart';
import 'cast_sheet.dart';
import 'download_tile.dart';

/// Download manager: All / Active / Done / Failed, grouped by day.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool _searching = false;
  final _search = TextEditingController();

  DownloadController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<DownloadTask> _filter(List<DownloadTask> list) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list
        .where((t) => t.displayTitle.toLowerCase().contains(q) || t.url.toLowerCase().contains(q))
        .toList();
  }

  /// Search, then the MP3/MP4 filter and the chosen order.
  List<DownloadTask> _view(List<DownloadTask> list) => c.arrange(_filter(list));

  void _closeSearch() => setState(() {
        _searching = false;
        _search.clear();
      });

  void _onMenu(String value) {
    switch (value) {
      case 'done':
        c.clearWhere((t) => t.status == TaskStatus.completed);
        c.notice('Completed list cleared. Files are still on your device.');
      case 'failed':
        c.clearWhere((t) => t.status != TaskStatus.completed);
        c.notice('Failed list cleared');
      case 'all':
        c.clearWhere((_) => true);
        c.notice('List cleared. Files are still on your device.');
    }
  }

  Future<void> _confirmDelete() async {
    final n = c.selectedTasks.where((t) => t.status == TaskStatus.completed).length;
    if (n == 0) {
      c.notice('Select finished downloads to delete');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $n ${n == 1 ? 'file' : 'files'}?'),
        content: const Text('They will be permanently deleted from your device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await c.deleteSelected();
  }

  Widget _normalBar(TextTheme text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: [
          if (_searching)
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search downloads',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            )
          else
            Expanded(
              child: Text('Downloads', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            ),
          if (_searching)
            IconButton(
              tooltip: 'Close search',
              icon: const Icon(Icons.close_rounded),
              onPressed: _closeSearch,
            )
          else ...[
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => setState(() => _searching = true),
            ),
            PopupMenuButton<SortMode>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort_rounded),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              initialValue: c.sort,
              onSelected: c.setSort,
              itemBuilder: (_) => [
                for (final m in SortMode.values) PopupMenuItem(value: m, child: Text(m.label)),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onSelected: _onMenu,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'done', child: Text('Clear completed list')),
                PopupMenuItem(value: 'failed', child: Text('Clear failed list')),
                PopupMenuItem(value: 'all', child: Text('Clear all finished')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _selectionBar(TextTheme text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel selection',
            icon: const Icon(Icons.close_rounded),
            onPressed: c.clearSelection,
          ),
          Expanded(
            child: Text(
              '${c.selectedCount} selected',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: cs.onPrimaryContainer),
            ),
          ),
          IconButton(
            tooltip: 'Play selected',
            icon: const Icon(Icons.play_circle_rounded),
            onPressed: c.playSelected,
          ),
          IconButton(
            tooltip: 'Play on TV',
            icon: const Icon(Icons.tv_rounded),
            onPressed: () => castDownloads(context, c, c.selectedTasks),
          ),
          IconButton(
            tooltip: 'Share selected',
            icon: const Icon(Icons.share_rounded),
            onPressed: c.shareSelected,
          ),
          IconButton(
            tooltip: 'Delete from device',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _confirmDelete,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (v) {
              switch (v) {
                case 'all':
                  c.selectAll(_view([...c.active, ...c.finished]));
                case 'remove':
                  c.removeSelected();
                case 'retry':
                  c.retrySelected();
                case 'cancel':
                  c.cancelSelected();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('Select all')),
              PopupMenuItem(value: 'remove', child: Text('Remove from list')),
              PopupMenuItem(value: 'retry', child: Text('Retry failed')),
              PopupMenuItem(value: 'cancel', child: Text('Cancel active')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kindChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('All types'),
            selected: c.kindFilter == null,
            onSelected: (_) => c.setKindFilter(null),
          ),
          const SizedBox(width: 8),
          for (final k in MediaKind.values) ...[
            ChoiceChip(
              label: Text(k.label),
              selected: c.kindFilter == k,
              onSelected: (_) => c.setKindFilter(c.kindFilter == k ? null : k),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final activeN = c.activeCount;
        final byDay = c.sort == SortMode.newest || c.sort == SortMode.oldest;
        return DefaultTabController(
          length: 4,
          child: SafeArea(
            child: Column(
              children: [
                c.selecting ? _selectionBar(text) : _normalBar(text),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: TabBar(
                    tabs: [
                      const Tab(text: 'All'),
                      Tab(text: activeN > 0 ? 'Active $activeN' : 'Active'),
                      Tab(text: 'Done ${c.completedCount}'),
                      Tab(text: c.failedCount > 0 ? 'Failed ${c.failedCount}' : 'Failed'),
                    ],
                  ),
                ),
                _kindChips(),
                Expanded(
                  child: TabBarView(
                    children: [
                      _TaskList(
                        controller: c,
                        rows: _rowsAll(_filter(c.active), _view(c.finished), byDay),
                        empty: const _Empty(
                          icon: Icons.download_for_offline_outlined,
                          title: 'No downloads yet',
                          subtitle: 'Paste a link on the Home tab or share one from YouTube.',
                        ),
                      ),
                      _TaskList(
                        controller: c,
                        rows: _filter(c.active),
                        empty: const _Empty(
                          icon: Icons.hourglass_empty_rounded,
                          title: 'Nothing downloading',
                          subtitle: 'Items you start will appear here with live progress.',
                        ),
                      ),
                      _TaskList(
                        controller: c,
                        rows: _grouped(_view(c.completed), byDay),
                        empty: const _Empty(
                          icon: Icons.library_music_outlined,
                          title: 'No completed downloads',
                          subtitle: 'Finished songs and videos are listed here by date.',
                        ),
                      ),
                      _TaskList(
                        controller: c,
                        rows: _grouped(_view(c.failed), byDay),
                        empty: const _Empty(
                          icon: Icons.check_circle_outline_rounded,
                          title: 'No failed downloads',
                          subtitle: 'Anything that fails or is cancelled shows up here.',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Active items under "In progress", then finished items.
  static List<Object> _rowsAll(List<DownloadTask> active, List<DownloadTask> finished, bool byDay) => [
        if (active.isNotEmpty) 'In progress',
        ...active,
        ..._grouped(finished, byDay),
      ];

  static List<Object> _grouped(List<DownloadTask> tasks, bool byDay) =>
      byDay ? _byDay(tasks) : List<Object>.of(tasks);

  /// Inserts a day header (String) before the first item of each day.
  static List<Object> _byDay(List<DownloadTask> tasks) {
    final now = DateTime.now();
    final rows = <Object>[];
    String? last;
    for (final t in tasks) {
      final label = Fmt.dayLabel(t.when, now);
      if (label != last) {
        rows.add(label);
        last = label;
      }
      rows.add(t);
    }
    return rows;
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.controller, required this.rows, required this.empty});

  final DownloadController controller;
  final List<Object> rows;
  final Widget empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return empty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is DownloadTask) {
          return DownloadTile(key: ValueKey(row.id), task: row, controller: controller, selectable: true);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: Text(
            row as String,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.5), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: cs.primary),
            ),
            const SizedBox(height: 18),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
