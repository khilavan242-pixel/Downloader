import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import '../models/quality.dart';
import '../models/save_folder.dart';
import '../services/native_bridge.dart';
import '../services/settings_store.dart';
import '../utils/url_utils.dart';

/// Single source of UI state: current selection, saved folders and the task
/// list. Downloads themselves run natively (foreground service), this class
/// only mirrors their state and forwards user intent.
class DownloadController extends ChangeNotifier {
  DownloadController({required NativeBridge bridge, required SettingsStore settings})
      : _bridge = bridge,
        _settings = settings {
    _kind = settings.kind;
    _quality = settings.qualityFor(_kind);
    _playlist = settings.playlist;
  }

  final NativeBridge _bridge;
  final SettingsStore _settings;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  late MediaKind _kind;
  late QualityOption _quality;
  late bool _playlist;
  SaveFolder? _folder;
  List<SaveFolder> _folders = const [];
  final Map<String, DownloadTask> _tasks = {};
  int _idCounter = 0;

  /// One-shot messages for the UI to show (snackbar).
  final StreamController<String> _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  MediaKind get kind => _kind;
  QualityOption get quality => _quality;
  bool get playlist => _playlist;
  SaveFolder? get folder => _folder;
  List<SaveFolder> get folders => _folders;

  /// Newest first.
  List<DownloadTask> get tasks => _tasks.values.toList().reversed.toList();
  int get activeCount => _tasks.values.where((t) => t.status.isActive).length;
  bool get hasFinished => _tasks.values.any((t) => t.status.isFinished);

  List<QualityOption> get qualityOptions => QualityOption.forKind(_kind);

  Future<void> init() async {
    _sub = _bridge.events.listen(_onEvent, onError: (Object e) => _say('Event error: $e'));
    await _refreshFolders();
    try {
      for (final t in await _bridge.snapshot()) {
        _tasks[t.id] = t;
      }
    } catch (_) {/* service not started yet - fine */}
    notifyListeners();
    await _takeSharedText();
  }

  // ---- selection ---------------------------------------------------------

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

  // ---- folders -----------------------------------------------------------

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

  // ---- downloads ---------------------------------------------------------

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
      _tasks[id] = task.copyWith(status: TaskStatus.failed, error: '$e');
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

  void clearFinished() {
    _tasks.removeWhere((_, t) => t.status.isFinished);
    notifyListeners();
  }

  Future<String> updateEngine() async {
    final v = await _bridge.updateEngine();
    _say('yt-dlp updated: $v');
    return v;
  }

  // ---- shared text ("Share -> Tapnab") -----------------------------------

  Future<void> onAppResumed() async {
    await _takeSharedText();
  }

  Future<void> _takeSharedText() async {
    try {
      final text = await _bridge.consumeSharedText();
      if (text != null && text.trim().isNotEmpty) await addFromText(text);
    } catch (_) {}
  }

  // ---- native events -----------------------------------------------------

  void _onEvent(Map<dynamic, dynamic> e) {
    if (e['type'] == 'shared') {
      final text = e['text'] as String?;
      if (text != null) unawaited(addFromText(text));
      return;
    }
    final incoming = DownloadTask.fromMap(e);
    final existing = _tasks[incoming.id];
    if (existing == null) {
      _tasks[incoming.id] = incoming;
    } else {
      // Native sends partial updates; keep what we already know.
      _tasks[incoming.id] = existing.copyWith(
        title: incoming.title,
        status: incoming.status,
        progress: incoming.progress,
        etaSeconds: incoming.etaSeconds,
        error: incoming.error,
        savedTo: incoming.savedTo,
        clearError: incoming.status != TaskStatus.failed,
      );
    }
    notifyListeners();
  }

  void _say(String m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _messages.close();
    super.dispose();
  }
}
