import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../state/download_controller.dart';
import '../utils/format_utils.dart';
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final activeN = c.activeCount;
        return DefaultTabController(
          length: 4,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
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
                          child: Text(
                            'Downloads',
                            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                          ),
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
                ),
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
                Expanded(
                  child: TabBarView(
                    children: [
                      _TaskList(
                        controller: c,
                        rows: _rowsAll(_filter(c.active), _filter(c.finished)),
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
                        rows: _byDay(_filter(c.completed)),
                        empty: const _Empty(
                          icon: Icons.library_music_outlined,
                          title: 'No completed downloads',
                          subtitle: 'Finished songs and videos are listed here by date.',
                        ),
                      ),
                      _TaskList(
                        controller: c,
                        rows: _byDay(_filter(c.failed)),
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

  /// Active items under "In progress", then finished items grouped by day.
  static List<Object> _rowsAll(List<DownloadTask> active, List<DownloadTask> finished) => [
        if (active.isNotEmpty) 'In progress',
        ...active,
        ..._byDay(finished),
      ];

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
          return DownloadTile(key: ValueKey(row.id), task: row, controller: controller);
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
