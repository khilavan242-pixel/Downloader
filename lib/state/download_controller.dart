import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import '../models/quality.dart';
import '../models/save_folder.dart';
import '../services/history_store.dart';
import '../services/native_bridge.dart';
import '../services/settings_store.dart';
import '../utils/url_utils.dart';

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
  int _idCounter = 0;

  /// One-shot messages for the UI to show (snackbar).
  final StreamController<String> _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  MediaKind get kind => _kind;
  QualityOption get quality => _quality;
  bool get playlist => _playlist;
  SaveFolder? get folder => _folder;
  List<SaveFolder> get folders => _folders;
  List<QualityOption> get qualityOptions => QualityOption.forKind(_kind);

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

  // ---- startup -------------------------------------------------------------

  Future<void> init() async {
    _sub = _bridge.events.listen(_onEvent, onError: (Object e) => _say('Event error: $e'));
    await _refreshFolders();

    for (final t in _history.load()) {
      _tasks[t.id] = t;
    }
    final live = <String>{};
    try {
      for (final t in await _bridge.snapshot()) {
        live.add(t.id);
        final old = _tasks[t.id];
        _tasks[t.id] = old == null ? t : _merge(old, t);
      }
    } catch (_) {/* nothing running yet */}
    _markInterrupted(live);

    notifyListeners();
    await _takeSharedText();
    await _checkFiles();
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

  Future<void> _start(String url) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';
    final task = DownloadTask(
      id: id,
      url: url,
      kind: _kind,
      quality: _quality,
      playlist: _playlist && UrlUtils.hasPlaylist(url),
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

  Future<void> cancel(String id) async {
    try {
      await _bridge.cancel(id);
    } catch (_) {}
  }

  Future<void> retry(String id) async {
    final t = _tasks[id];
    if (t == null) return;
    _tasks.remove(id);
    final prevKind = _kind, prevQuality = _quality, prevPlaylist = _playlist;
    _kind = t.kind;
    _quality = t.quality;
    _playlist = t.playlist;
    await _start(t.url);
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
      _tasks.remove(id);
      _missing.remove(id);
    }
    _persistSoon();
    notifyListeners();
  }

  void _drop(String id) {
    _tasks.remove(id);
    _missing.remove(id);
    _persistSoon();
    notifyListeners();
  }

  Future<String> updateEngine() async {
    final v = await _bridge.updateEngine();
    _say('yt-dlp updated: $v');
    return v;
  }

  /// Lets any widget show a snackbar message.
  void notice(String message) => _say(message);

  // ---- app lifecycle -------------------------------------------------------

  Future<void> onAppResumed() async {
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
      if (text != null && text.trim().isNotEmpty) await addFromText(text);
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
      finishedAt: incoming.status.isFinished ? (old.finishedAt ?? DateTime.now()) : null,
      clearError: incoming.status != TaskStatus.failed,
    );
  }

  void _onEvent(Map<dynamic, dynamic> e) {
    if (e['type'] == 'shared') {
      final text = e['text'] as String?;
      if (text != null) unawaited(addFromText(text));
      return;
    }
    if (e['type'] == 'playlist') {
      // The playlist card is replaced by one card per song.
      _tasks.remove(e['id']);
      _say('${e['count']} songs added to the queue');
      _persistSoon();
      notifyListeners();
      return;
    }
    final incoming = DownloadTask.fromMap(e);
    final existing = _tasks[incoming.id];
    if (existing == null) {
      _tasks[incoming.id] = incoming.status.isFinished
          ? incoming.copyWith(finishedAt: DateTime.now())
          : incoming;
    } else {
      _tasks[incoming.id] = _merge(existing, incoming);
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
    super.dispose();
  }
}
