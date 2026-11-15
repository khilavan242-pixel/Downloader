import 'dart:async';

import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../models/playlist_entry.dart';
import '../models/quality.dart';
import '../models/save_folder.dart';
import '../services/history_store.dart';
import '../services/native_bridge.dart';
import '../services/settings_store.dart';
import '../utils/url_utils.dart';

/// How the Downloads list is ordered.
enum SortMode {
  newest('Newest first'),
  oldest('Oldest first'),
  name('Name A to Z'),
  size('Largest first');

  const SortMode(this.label);
  final String label;
}

/// Single source of UI state: current selection, saved folders and the
/// download list. Downloads run natively (foreground service); this class
/// mirrors their state, remembers finished items and forwards user intent.
class DownloadController extends ChangeNotifier {
  DownloadController({
    required NativeBridge bridge,
    required SettingsStore settings,
    required HistoryStore history,
  })  : _bridge = bridge,
        _settings = settings,
        _history = history {
    _kind = settings.kind;
    _quality = settings.qualityFor(_kind);
    _playlist = settings.playlist;
  }

  final NativeBridge _bridge;
  final SettingsStore _settings;
  final HistoryStore _history;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;
  Timer? _saveTimer;

  late MediaKind _kind;
  late QualityOption _quality;
  late bool _playlist;
  SaveFolder? _folder;
  List<SaveFolder> _folders = const [];
  final Map<String, DownloadTask> _tasks = {};
  final Set<String> _missing = {};
  final Set<String> _selected = {};
  int _idCounter = 0;
  SortMode _sort = SortMode.newest;
  MediaKind? _kindFilter;

  /// One-shot messages for the UI to show (snackbar).
  final StreamController<String> _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  /// Text shared into the app with "Open Tapnab for more options". The Home
  /// page picks it up, fills the link box and clears it.
  final ValueNotifier<String?> incoming = ValueNotifier<String?>(null);

  MediaKind get kind => _kind;
  QualityOption get quality => _quality;
  bool get playlist => _playlist;
  SaveFolder? get folder => _folder;
  List<SaveFolder> get folders => _folders;
  List<QualityOption> get qualityOptions => QualityOption.forKind(_kind);
  SettingsStore get settings => _settings;
  ThemeMode get themeMode => _settings.themeMode;

  // ---- sort and filter -----------------------------------------------------------

  SortMode get sort => _sort;
  MediaKind? get kindFilter => _kindFilter;

  void setSort(SortMode m) {
    _sort = m;
    notifyListeners();
  }

  void setKindFilter(MediaKind? k) {
    _kindFilter = k;
    notifyListeners();
  }

  /// Applies the MP3/MP4 filter and the chosen order to a list.
  List<DownloadTask> arrange(List<DownloadTask> items) {
    final list = items.where((t) => _kindFilter == null || t.kind == _kindFilter).toList();
    switch (_sort) {
      case SortMode.newest:
        list.sort((a, b) => b.when.compareTo(a.when));
      case SortMode.oldest:
        list.sort((a, b) => a.when.compareTo(b.when));
      case SortMode.name:
        list.sort((a, b) => a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
      case SortMode.size:
        list.sort((a, b) => (b.fileSize ?? 0).compareTo(a.fileSize ?? 0));
    }
    return list;
  }

  // ---- settings (Settings page) ----------------------------------------------------

  void updateSettings(void Function(SettingsStore s) change) {
    change(_settings);
    notifyListeners();
  }

  // ---- lists for the Downloads page ---------------------------------------

  /// Running and waiting items, in queue order.
  List<DownloadTask> get active => _tasks.values.where((t) => t.status.isActive).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  List<DownloadTask> get completed => _finished((t) => t.status == TaskStatus.completed);

  List<DownloadTask> get failed => _finished(
        (t) => t.status == TaskStatus.failed || t.status == TaskStatus.cancelled,
      );

  /// Everything that is not running, newest first.
  List<DownloadTask> get finished => _finished((t) => t.status.isFinished);

  /// Active items first, then finished ones, newest first.
  List<DownloadTask> get everything => [...active, ...finished];

  /// The few most recent items for the home page.
  List<DownloadTask> get recent => everything.take(3).toList();

  int get activeCount => _tasks.values.where((t) => t.status.isActive).length;
  int get failedCount => failed.length;
  int get completedCount => completed.length;

  List<DownloadTask> _finished(bool Function(DownloadTask) test) =>
      _tasks.values.where(test).toList()..sort((a, b) => b.when.compareTo(a.when));

  /// True when the saved file was deleted or moved outside the app.
  bool isMissing(DownloadTask t) => _missing.contains(t.id);

  // ---- multi-select ----------------------------------------------------------

  /// True while at least one item is selected (selection mode).
  bool get selecting => _selected.isNotEmpty;
  int get selectedCount => _selected.length;
  bool isSelected(String id) => _selected.contains(id);

  List<DownloadTask> get selectedTasks =>
      _tasks.values.where((t) => _selected.contains(t.id)).toList();

  void toggleSelect(String id) {
    if (!_selected.remove(id)) _selected.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<DownloadTask> tasks) {
    _selected
      ..clear()
      ..addAll(tasks.map((t) => t.id));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  /// Opens every selected, finished file in the installed music / video player.
  Future<void> playSelected() async {
    final items = selectedTasks
        .where((t) => t.status == TaskStatus.completed && t.fileUri != null && !_missing.contains(t.id))
        .toList()
      ..sort((a, b) => a.when.compareTo(b.when));
    if (items.isEmpty) {
      _say('Select finished downloads to play');
      return;
    }
    final sameKind = items.every((t) => t.kind == items.first.kind);
    try {
      final ok = await _bridge.playFiles(
        items.map((t) => t.fileUri!).toList(),
        sameKind ? items.first.mime : '*/*',
        'Play ${items.length} files with',
      );
      if (!ok) _say('No player app found');
    } catch (_) {
      _say('Could not open the player');
    }
  }

  /// Shares every selected, finished file at once.
  Future<void> shareSelected() async {
    final items = selectedTasks
        .where((t) => t.status == TaskStatus.completed && t.fileUri != null && !_missing.contains(t.id))
        .toList();
    if (items.isEmpty) {
      _say('Select finished downloads to share');
      return;
    }
    final sameKind = items.every((t) => t.kind == items.first.kind);
    try {
      final ok = await _bridge.shareFiles(
        items.map((t) => t.fileUri!).toList(),
        sameKind ? items.first.mime : '*/*',
        'Share ${items.length} files',
      );
      if (!ok) _say('Could not share the files');
    } catch (_) {
      _say('Could not share the files');
    }
  }

  /// Deletes the selected files from the device and removes them from the list.
  Future<void> deleteSelected() async {
    final items = selectedTasks.where((t) => t.status == TaskStatus.completed).toList();
    var deleted = 0;
    var failed = 0;
    for (final t in items) {
      var ok = true;
      final uri = t.fileUri;
      if (uri != null && !_missing.contains(t.id)) {
        try {
          ok = await _bridge.deleteFile(uri);
        } catch (_) {
          ok = false;
        }
      }
      if (ok) {
        _forget(t.id);
        deleted++;
      } else {
        failed++;
      }
    }
    _selected.clear();
    _persistSoon();
    notifyListeners();
    _say(failed == 0 ? 'Deleted $deleted from device' : 'Deleted $deleted, $failed could not be deleted');
  }

  /// Removes selected finished items from the list; files stay on the device.
  void removeSelected() {
    for (final t in selectedTasks.where((t) => t.status.isFinished)) {
      _forget(t.id);
    }
    _selected.clear();
    _persistSoon();
    notifyListeners();
  }

  Future<void> retrySelected() async {
    final ids = selectedTasks
        .where((t) => t.status == TaskStatus.failed || t.status == TaskStatus.cancelled)
        .map((t) => t.id)
        .toList();
    _selected.clear();
    for (final id in ids) {
      await retry(id);
    }
    notifyListeners();
  }

  Future<void> cancelSelected() async {
    final ids = selectedTasks.where((t) => t.status.isActive).map((t) => t.id).toList();
    _selected.clear();
    for (final id in ids) {
      await cancel(id);
    }
    notifyListeners();
  }

  /// Forgets an item everywhere (no notification; callers notify).
  void _forget(String id) {
    _tasks.remove(id);
    _missing.remove(id);
    _selected.remove(id);
  }

  // ---- startup -------------------------------------------------------------

  Future<void> init() async {
    _sub = _bridge.events.listen(_onEvent, onError: (Object e) => _say('Event error: $e'));
    await _refreshFolders();

    for (final t in _history.load()) {
      _tasks[t.id] = t;
    }
    final live = await _syncNative();
    _markInterrupted(live);

    notifyListeners();
    await _takeSharedText();
    await _checkFiles();
  }

  /// Pulls everything the native side knows (including downloads started from
  /// the share pop-up while the app was closed). Returns the ids it reported.
  Future<Set<String>> _syncNative() async {
    final live = <String>{};
    try {
      for (final t in await _bridge.snapshot()) {
        live.add(t.id);
        final old = _tasks[t.id];
        _tasks[t.id] = old == null ? t : _merge(old, t);
      }
    } catch (_) {/* nothing running yet */}
    return live;
  }

  /// Items that were running when the app process died cannot continue.
  void _markInterrupted(Set<String> live) {
    for (final t in _tasks.values.toList()) {
      if (t.status.isActive && !live.contains(t.id)) {
        _tasks[t.id] = t.copyWith(
          status: TaskStatus.failed,
          error: 'Interrupted. Tap retry to download again.',
          finishedAt: DateTime.now(),
        );
      }
    }
  }

  Future<void> _checkFiles() async {
    final done = _tasks.values
        .where((t) => t.status == TaskStatus.completed && t.fileUri != null)
        .toList();
    if (done.isEmpty) return;
    try {
      final exists = await _bridge.filesExist(done.map((t) => t.fileUri!).toList());
      _missing.clear();
      for (var i = 0; i < done.length && i < exists.length; i++) {
        if (!exists[i]) _missing.add(done[i].id);
      }
      notifyListeners();
    } catch (_) {/* keep what we know */}
  }

  // ---- selection -----------------------------------------------------------

  void setKind(MediaKind k) {
    if (k == _kind) return;
    _kind = k;
    _quality = _settings.qualityFor(k);
    _settings.kind = k;
    notifyListeners();
  }

  void setQuality(QualityOption q) {
    _quality = q;
    _settings.saveQuality(q);
    notifyListeners();
  }

  void setPlaylist(bool v) {
    _playlist = v;
    _settings.playlist = v;
    notifyListeners();
  }

  // ---- folders -------------------------------------------------------------

  Future<void> _refreshFolders() async {
    try {
      _folders = await _bridge.listFolders();
    } catch (_) {
      _folders = const [];
    }
    final saved = _settings.folderUri;
    _folder = saved == null ? null : _folders.where((f) => f.uri == saved).firstOrNull;
    if (saved != null && _folder == null) _settings.folderUri = null;
  }

  /// Opens the system picker, remembers the folder and selects it.
  Future<void> addFolder() async {
    try {
      final picked = await _bridge.pickFolder();
      if (picked == null) return;
      await _refreshFolders();
      selectFolder(_folders.where((f) => f == picked).firstOrNull ?? picked);
    } catch (e) {
      _say('Could not open the folder picker: $e');
    }
  }

  /// Pass `null` to go back to the default Music/Movies location.
  void selectFolder(SaveFolder? f) {
    _folder = f;
    _settings.folderUri = f?.uri;
    notifyListeners();
  }

  Future<void> removeFolder(SaveFolder f) async {
    try {
      await _bridge.removeFolder(f.uri);
    } catch (_) {}
    await _refreshFolders();
    notifyListeners();
  }

  // ---- downloads -----------------------------------------------------------

  /// Starts a download for every link found in [text]. Returns how many were queued.
  Future<int> addFromText(String text) async {
    final urls = UrlUtils.extractUrls(text);
    if (urls.isEmpty) {
      _say('No link found');
      return 0;
    }
    for (final url in urls) {
      await _start(url);
    }
    if (urls.length > 1) _say('${urls.length} links added');
    return urls.length;
  }

  Future<void> _start(String url, {String? subfolder, bool? wholePlaylist}) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';
    final task = DownloadTask(
      id: id,
      url: url,
      kind: _kind,
      quality: _quality,
      subfolder: subfolder,
      playlist: (wholePlaylist ?? _playlist) && UrlUtils.hasPlaylist(url),
    );
    _tasks[id] = task;
    _persistSoon();
    notifyListeners();
    try {
      await _bridge.enqueue(
        id: id,
        url: url,
        kind: _kind,
        quality: _quality,
        playlist: task.playlist,
        folder: _folder,
        subfolder: subfolder,
      );
    } catch (e) {
      _tasks[id] = task.copyWith(
        status: TaskStatus.failed,
        error: '$e',
        finishedAt: DateTime.now(),
      );
      _persistSoon();
      notifyListeners();
    }
  }

  /// A download of the same video and format that is finished (and still on the
  /// device) or still running, or null. Used to warn before downloading twice.
  DownloadTask? existingFor(String url, {MediaKind? kind}) {
    final id = UrlUtils.videoId(url);
    if (id == null) return null;
    final k = kind ?? _kind;
    for (final t in _tasks.values) {
      if (t.kind != k || UrlUtils.videoId(t.url) != id) continue;
      if (t.status.isActive) return t;
      if (t.status == TaskStatus.completed && !_missing.contains(t.id)) return t;
    }
    return null;
  }

  /// True when a song is already downloaded in the current format.
  bool isDownloaded(String url) => existingFor(url) != null;

  /// Starts one link, ignoring duplicates (the UI asks first).
  Future<void> addUrl(String url) => _start(url);

  /// Lists a playlist for the "pick songs" screen.
  Future<List<PlaylistEntry>> fetchPlaylist(String url) => _bridge.fetchPlaylist(url);

  /// Downloads the chosen playlist entries, each as its own item, into a folder
  /// named after the playlist (when that setting is on).
  Future<void> addEntries(List<PlaylistEntry> entries, {String? playlistName}) async {
    if (entries.isEmpty) return;
    final sub = (_settings.playlistFolders && entries.length > 1 && (playlistName ?? '').trim().isNotEmpty)
        ? playlistName!.trim()
        : null;
    for (final e in entries) {
      await _start(e.url, subfolder: sub, wholePlaylist: false);
    }
    _say(entries.length == 1 ? 'Download started' : '${entries.length} songs added to the queue');
  }

  Future<void> cancel(String id) async {
    try {
      await _bridge.cancel(id);
    } catch (_) {}
  }

  Future<void> retry(String id) async {
    final t = _tasks[id];
    if (t == null) return;
    _forget(id);
    final prevKind = _kind, prevQuality = _quality, prevPlaylist = _playlist;
    _kind = t.kind;
    _quality = t.quality;
    _playlist = t.playlist;
    await _start(t.url, subfolder: t.subfolder);
    _kind = prevKind;
    _quality = prevQuality;
    _playlist = prevPlaylist;
    notifyListeners();
  }

  // ---- file actions --------------------------------------------------------

  Future<void> play(DownloadTask t) async {
    final uri = t.fileUri;
    if (uri == null || _missing.contains(t.id)) {
      _say('This file is no longer on the device');
      return;
    }
    try {
      if (!await _bridge.openFile(uri, t.mime)) _say('No app found to play this file');
    } catch (_) {
      _say('Could not open the file');
    }
  }

  Future<void> share(DownloadTask t) async {
    final uri = t.fileUri;
    if (uri == null || _missing.contains(t.id)) {
      _say('This file is no longer on the device');
      return;
    }
    try {
      if (!await _bridge.shareFile(uri, t.mime, t.displayTitle)) _say('Could not share the file');
    } catch (_) {
      _say('Could not share the file');
    }
  }

  /// Deletes the file from the device and removes the item from the list.
  Future<void> deleteFile(DownloadTask t) async {
    final uri = t.fileUri;
    var ok = true;
    if (uri != null && !_missing.contains(t.id)) {
      try {
        ok = await _bridge.deleteFile(uri);
      } catch (_) {
        ok = false;
      }
    }
    if (ok) {
      _drop(t.id);
      _say('Deleted from device');
    } else {
      _say('Could not delete the file');
    }
  }

  /// Removes an item from the list but keeps the file.
  void remove(DownloadTask t) => _drop(t.id);

  /// Clears items from the list (files stay on the device).
  void clearWhere(bool Function(DownloadTask) test) {
    final ids = _tasks.values.where((t) => t.status.isFinished && test(t)).map((t) => t.id).toList();
    for (final id in ids) {
      _forget(id);
    }
    _persistSoon();
    notifyListeners();
  }

  void _drop(String id) {
    _forget(id);
    _persistSoon();
    notifyListeners();
  }

  Future<String> updateEngine() async {
    final v = await _bridge.updateEngine();
    _say('yt-dlp updated: $v');
    return v;
  }

  Future<({String version, int lastUpdate})> engineInfo() => _bridge.engineInfo();

  /// Lets any widget show a snackbar message.
  void notice(String message) => _say(message);

  // ---- app lifecycle -------------------------------------------------------

  Future<void> onAppResumed() async {
    await _syncNative();
    _persistSoon();
    notifyListeners();
    await _takeSharedText();
    await _checkFiles();
  }

  /// Saves the list immediately (called when the app goes to the background).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _history.save(_tasks.values);
  }

  Future<void> _takeSharedText() async {
    try {
      final text = await _bridge.consumeSharedText();
      if (text != null && text.trim().isNotEmpty) incoming.value = text;
    } catch (_) {}
  }

  // ---- native events -------------------------------------------------------

  DownloadTask _merge(DownloadTask old, DownloadTask incoming) {
    return old.copyWith(
      title: incoming.title,
      status: incoming.status,
      progress: incoming.progress,
      etaSeconds: incoming.etaSeconds,
      error: incoming.error,
      savedTo: incoming.savedTo,
      fileUri: incoming.fileUri,
      fileSize: incoming.fileSize,
      subfolder: incoming.subfolder,
      note: incoming.note,
      clearNote: incoming.note == null,
      finishedAt: incoming.status.isFinished
          ? (incoming.finishedAt ?? old.finishedAt ?? DateTime.now())
          : null,
      clearError: incoming.status != TaskStatus.failed,
    );
  }

  void _onEvent(Map<dynamic, dynamic> e) {
    if (e['type'] == 'shared') {
      final text = e['text'] as String?;
      if (text != null && text.trim().isNotEmpty) incoming.value = text;
      return;
    }
    if (e['type'] == 'playlist') {
      // The playlist card is replaced by one card per song.
      _forget(e['id'] as String);
      _say('${e['count']} songs added to the queue');
      _persistSoon();
      notifyListeners();
      return;
    }
    final task = DownloadTask.fromMap(e);
    final existing = _tasks[task.id];
    if (existing == null) {
      _tasks[task.id] = task.status.isFinished && task.finishedAt == null
          ? task.copyWith(finishedAt: DateTime.now())
          : task;
    } else {
      _tasks[task.id] = _merge(existing, task);
    }
    _persistSoon();
    notifyListeners();
  }

  void _persistSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_history.save(_tasks.values));
    });
  }

  void _say(String m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _saveTimer?.cancel();
    _messages.close();
    incoming.dispose();
    super.dispose();
  }
}
