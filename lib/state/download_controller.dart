import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/cast.dart';
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
    _target = _loadTarget(settings.castDevice);
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
  CastState _cast = const CastState.idle();
  CastDevice? _target;
  String? _castVideoId;
  String? _extendedFor;
  int _queueSeq = 0;
  final Set<String> _playedIds = {};
  final Map<String, List<PlaylistEntry>> _pageRelated = {};
  final Map<String, Future<Uint8List?>> _thumbs = {};
  bool _userStopped = false;
  bool _queueing = false;
  bool _continuing = false;
  bool _wasActive = false;
  bool _webPlaying = false;
  bool _keeping = false;
  Timer? _keepTimer;
  DateTime _lastMore = DateTime(2000);
  SortMode _sort = SortMode.newest;
  MediaKind? _kindFilter;

  /// One-shot messages for the UI to show (snackbar).
  final StreamController<String> _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  /// Text shared into the app with "Open Tapnab for more options". The Home
  /// page picks it up, fills the link box and clears it.
  final ValueNotifier<String?> incoming = ValueNotifier<String?>(null);

  /// Playback position on the TV (updates a few times per second, so it is
  /// a notifier and does not rebuild the whole app).
  final ValueNotifier<CastProgress> castProgress = ValueNotifier<CastProgress>(const CastProgress());

  /// Set to a video id when the TV moved on to the next video by itself.
  final ValueNotifier<String?> castAdvanced = ValueNotifier<String?>(null);

  /// The video id of the YouTube watch page open in the Browse tab (or null).
  final ValueNotifier<String?> browseVideoId = ValueNotifier<String?>(null);

  /// Set by the floating player to ask Browse to show this video's page.
  final ValueNotifier<String?> openVideo = ValueNotifier<String?>(null);

  /// The video open in Tapnab's own player (null = player closed).
  final ValueNotifier<String?> playerId = ValueNotifier<String?>(null);

  /// Set by the open player: handles the Back button (minimize / leave full screen).
  /// Returns true when it handled the press.
  Future<bool> Function()? onPlayerBack;

  /// The player is shrunk to the small bar above the bottom of the screen (browse while it plays).
  final ValueNotifier<bool> playerMini = ValueNotifier<bool>(false);

  /// How far the small floating player was dragged from its corner (right/bottom).
  final ValueNotifier<Offset> miniOffset = ValueNotifier<Offset>(Offset.zero);

  /// Title known when the player is opened (shown while the video is still loading).
  String playerTitle = '';

  void openPlayer(String id, {String? title, String? listId}) {
    playerMini.value = false;
    playerListId = (listId == null || listId.isEmpty) ? null : listId;
    playerTitle = title ?? '';
    playerId.value = id;
  }

  /// Downloads a YouTube video as MP4 or MP3 with the quality chosen in Settings / Home.
  Future<void> downloadVideo(String id, MediaKind kind) async {
    await _start('https://www.youtube.com/watch?v=$id', kind: kind, quality: _settings.qualityFor(kind));
    _say('${kind.label} download added - see the Downloads tab');
  }

  void closePlayer() {
    playerMini.value = false;
    miniOffset.value = Offset.zero;
    playerListId = null;
    playerId.value = null;
    setWebPlaying(false);
    updatePip(ready: false, playing: false);
  }

  final Map<String, (DateTime, Map<String, dynamic>)> _resolved = {};

  void forgetStream(String id) => _resolved.removeWhere((k, _) => k.startsWith('$id|'));

  Future<Map<String, dynamic>> resolveStream(String id, {bool legacy = false}) async {
    final audio = audioMode.value;
    final height = playerHeight.value;
    final key = '$id|$legacy|$audio|$height';
    final hit = _resolved[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 30)) return hit.$2;
    final r = await _bridge.resolveStream(
      'https://www.youtube.com/watch?v=$id',
      legacy: legacy,
      audio: audio,
      height: height,
    );
    _resolved[key] = (DateTime.now(), r);
    if (_resolved.length > 12) _resolved.remove(_resolved.keys.first);
    return r;
  }

  /// Player choices (kept between runs): picture height and sound-only mode.
  late final ValueNotifier<int> playerHeight = ValueNotifier<int>(_settings.playerHeight);
  late final ValueNotifier<bool> audioMode = ValueNotifier<bool>(_settings.audioMode);

  void setPlayerHeight(int h) {
    _settings.playerHeight = h;
    playerHeight.value = h;
  }

  late final ValueNotifier<int> shuffleMode = ValueNotifier<int>(_settings.shuffleMode);
  late final ValueNotifier<int> repeatMode = ValueNotifier<int>(_settings.repeatMode);

  void setShuffleMode(int m) {
    _settings.shuffleMode = m;
    shuffleMode.value = m;
  }

  void setRepeatMode(int m) {
    _settings.repeatMode = m;
    repeatMode.value = m;
  }

  /// Shows the song on the lock screen / notification with working controls.
  void publishMedia({String? id, required String title, required bool playing, required int positionMs, required int durationMs}) {
    unawaited(_bridge.playerMedia(id, title, playing, positionMs, durationMs).catchError((_) {}));
  }

  void setAudioMode(bool on) {
    _settings.audioMode = on;
    audioMode.value = on;
  }

  /// The playlist the player was opened from ("Play all"), or null.
  String? playerListId;

  /// The playlist's videos (in order), for the player's queue.
  Future<List<PlaylistEntry>> listEntries(String id) async {
    final l = playerListId;
    if (l == null) return const [];
    final url = l.startsWith('RD')
        ? 'https://www.youtube.com/watch?v=$id&list=$l'
        : 'https://www.youtube.com/playlist?list=$l';
    return _bridge.fetchPlaylist(url);
  }

  /// Videos that follow [id] (its Mix), for the player's "Up next" list.
  Future<List<PlaylistEntry>> upNext(String id, String title) async {
    var all = await _related(id, null);
    if (all.length < 2 && title.trim().isNotEmpty) {
      // The Mix was not available: list what a search for the title finds.
      try {
        all = await _bridge.fetchPlaylist('ytsearch15:${title.trim()}');
      } catch (_) {/* nothing to offer */}
    }
    final at = all.indexWhere((e) => UrlUtils.videoId(e.url) == id);
    final after = at >= 0 ? all.sublist(at + 1) : all;
    return [
      for (final e in after)
        if (UrlUtils.videoId(e.url) != null && UrlUtils.videoId(e.url) != id) e,
    ];
  }

  /// True while the app is shown as a small floating window (picture-in-picture).
  final ValueNotifier<bool> inPip = ValueNotifier<bool>(false);

  final StreamController<String> _webActions = StreamController<String>.broadcast();

  /// Buttons pressed on the floating window / background notification: toggle, prev, next.
  Stream<String> get webActions => _webActions.stream;

  /// True while the TV is loading the next video (so the screen shows a spinner, not "Play on TV").
  bool get castBusy => _continuing;

  /// A YouTube video is playing inside the app. Keeps the app alive in the background.
  void setWebPlaying(bool playing) {
    if (playing == _webPlaying) return;
    _webPlaying = playing;
    if (playing) {
      _keepTimer?.cancel();
      if (!_keeping) {
        _keeping = true;
        unawaited(_bridge.keepAlive(true).catchError((_) {}));
      }
    } else {
      // Stay alive for a while after a pause, so Play from the notification still works.
      _keepTimer?.cancel();
      _keepTimer = Timer(const Duration(minutes: 10), () {
        if (_webPlaying || !_keeping) return;
        _keeping = false;
        unawaited(_bridge.keepAlive(false).catchError((_) {}));
      });
    }
  }

  /// Lets the video float when the user leaves the app.
  void updatePip({required bool ready, required bool playing}) {
    unawaited(_bridge.setPip(ready: ready, playing: playing).catchError((_) {}));
  }

  Future<bool> enterPip() => _bridge.enterPip();

  /// Picture for a file on the phone, cached.
  Future<Uint8List?> thumbFor(String uri) => _thumbs.putIfAbsent(uri, () => _bridge.mediaThumb(uri));

  /// The first "up next" video the open YouTube page lists for [id], or null.
  String? firstRelated(String id) {
    for (final e in _pageRelated[id] ?? const <PlaylistEntry>[]) {
      final eid = UrlUtils.videoId(e.url);
      if (eid != null && eid != id) return eid;
    }
    return null;
  }

  /// "Up next" videos found on the open YouTube page (used when the Mix list is not available).
  void offerRelated(String id, List<String> ids) {
    _pageRelated[id] = [
      for (final e in ids) PlaylistEntry(url: 'https://www.youtube.com/watch?v=$e', title: ''),
    ];
  }

  MediaKind get kind => _kind;
  QualityOption get quality => _quality;
  bool get playlist => _playlist;
  SaveFolder? get folder => _folder;
  List<SaveFolder> get folders => _folders;
  List<QualityOption> get qualityOptions => QualityOption.forKind(_kind);
  SettingsStore get settings => _settings;
  CastState get cast => _cast;

  /// The TV Tapnab is connected to. It stays until the user disconnects.
  CastDevice? get castTarget => _target;

  /// YouTube id of the video the TV is playing (or was last told to play).
  String? get castVideoId => _castVideoId;
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

  Future<void> _start(String url, {String? subfolder, bool? wholePlaylist, MediaKind? kind, QualityOption? quality}) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';
    final task = DownloadTask(
      id: id,
      url: url,
      kind: kind ?? _kind,
      quality: quality ?? _quality,
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
        kind: kind ?? _kind,
        quality: quality ?? _quality,
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

  // ---- casting to a TV --------------------------------------------------------------

  Future<List<CastDevice>> discoverDevices() => _bridge.castDiscover();

  /// Plays finished downloads on the TV, oldest first, one after another.
  Future<void> castTasks(CastDevice device, List<DownloadTask> tasks) async {
    _queueSeq++;
    final items = tasks
        .where((t) => t.status == TaskStatus.completed && t.fileUri != null && !_missing.contains(t.id))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (items.isEmpty) {
      _say('Select finished downloads to play on the TV');
      return;
    }
    await _startCast(
      device,
      [for (final t in items) CastItem(uri: t.fileUri!, title: t.displayTitle, mime: t.mime)],
    );
  }

  /// Plays YouTube links on the TV straight from YouTube (nothing is downloaded).
  /// A playlist page is expanded into all of its videos.
  Future<void> castLinks(CastDevice device, List<String> urls, {bool audioOnly = false}) async {
    _queueSeq++;
    final mime = audioOnly ? 'audio/mp4' : 'video/mp4';
    _cast = CastState(status: 'connecting', device: device.name);
    notifyListeners();
    final items = <CastItem>[];
    try {
      for (final url in urls) {
        if (UrlUtils.isPlaylistPage(url)) {
          final entries = await _bridge.fetchPlaylist(url);
          for (final e in entries) {
            items.add(CastItem(uri: e.url, title: e.displayTitle, mime: mime, stream: true));
          }
        } else {
          items.add(CastItem(uri: url, title: 'YouTube video', mime: mime, stream: true));
        }
      }
    } catch (_) {
      _cast = const CastState.idle();
      notifyListeners();
      _say('Could not read the playlist');
      return;
    }
    await _startCast(device, items);
  }

  Future<void> _startCast(CastDevice device, List<CastItem> items, {bool retry = true}) async {
    if (items.isEmpty) {
      _cast = const CastState.idle();
      notifyListeners();
      _say('Nothing to play');
      return;
    }
    _target = device;
    _userStopped = false;
    _settings.castDevice = jsonEncode(device.toMap());
    _cast = CastState(
      status: 'connecting',
      device: device.name,
      count: items.length,
      title: items.first.title,
      uri: items.first.uri,
    );
    final firstId = UrlUtils.videoId(items.first.uri);
    _castVideoId = firstId;
    if (firstId != null) _playedIds.add(firstId);
    notifyListeners();
    try {
      await _bridge.castPlay(device, items);
    } catch (e) {
      // The TV may have a new address (router gave it another IP). Look for it
      // by name once and try again.
      if (retry) {
        try {
          final found = await _bridge.castDiscover();
          final match = found.where((d) => d.name == device.name);
          if (match.isNotEmpty) {
            await _startCast(match.first, items, retry: false);
            return;
          }
        } catch (_) {/* fall through to the message */}
      }
      _cast = const CastState.idle();
      notifyListeners();
      _say(e is PlatformException ? (e.message ?? 'Could not reach the TV') : 'Could not reach the TV');
    }
  }

  CastDevice? _loadTarget(String? json) {
    if (json == null) return null;
    try {
      return CastDevice.fromMap(jsonDecode(json) as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Remembers [device] as the TV to play on, until [disconnectCast].
  void connectCast(CastDevice device) {
    _target = device;
    _settings.castDevice = jsonEncode(device.toMap());
    notifyListeners();
  }

  /// Forgets the TV and stops what it is playing. Only the user does this.
  Future<void> disconnectCast() async {
    _target = null;
    _settings.castDevice = null;
    _castVideoId = null;
    _queueSeq++;
    notifyListeners();
    await castControl('stop');
  }

  /// Plays one YouTube video on the connected TV and queues "up next" videos
  /// behind it, like the YouTube app does.
  Future<void> castPlayNow(String url, {String? listUrl, bool keepHistory = false}) async {
    final target = _target;
    final id = UrlUtils.videoId(url);
    if (target == null || id == null) return;
    if (id == _castVideoId && (_cast.active || _cast.status == 'connecting')) return;
    final seq = ++_queueSeq;
    if (!keepHistory) _playedIds.clear();
    _playedIds.add(id);
    _extendedFor = null;
    await _startCast(
      target,
      [CastItem(uri: 'https://www.youtube.com/watch?v=$id', title: 'YouTube video', mime: 'video/mp4', stream: true)],
    );
    if (seq != _queueSeq) return;
    unawaited(_topUp(id, listUrl, seq));
  }

  /// Fills the queue behind the playing video (in the background, with retries).
  Future<void> _topUp(String id, String? listUrl, int seq) async {
    var added = await _queueMore(id, listUrl, seq);
    // The page may not have listed its "up next" videos yet: try again shortly.
    for (var attempt = 0; attempt < 2 && added == 0 && seq == _queueSeq && _target != null; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (seq != _queueSeq) return;
      added = await _queueMore(id, null, seq);
    }
  }

  /// Related videos for [id]: the playlist / Mix, or what the open page lists as "up next".
  Future<List<PlaylistEntry>> _related(String id, String? listUrl) async {
    final source = listUrl ?? 'https://www.youtube.com/watch?v=$id&list=RD$id';
    // 1. The playlist / Mix.
    try {
      final entries = await _bridge.fetchPlaylist(source);
      if (entries.length > 1) return entries;
    } catch (_) {/* try the next way */}
    // 2. What the open YouTube page lists as "up next".
    final page = _pageRelated[id];
    if (page != null && page.isNotEmpty) return page;
    // 3. A search for the video's title (works when YouTube gives no Mix).
    try {
      var title = _cast.title ?? '';
      if (title.trim().isEmpty || title == 'YouTube video') {
        final one = await _bridge.fetchPlaylist('https://www.youtube.com/watch?v=$id');
        if (one.isNotEmpty) title = one.first.title;
      }
      if (title.trim().isNotEmpty) {
        final found = await _bridge.fetchPlaylist('ytsearch20:${title.trim()}');
        if (found.isNotEmpty) return found;
      }
    } catch (_) {/* nothing more to try */}
    return const [];
  }

  /// Adds the videos that follow [id] to the TV queue. Returns how many were added.
  Future<int> _queueMore(String id, String? listUrl, int seq) async {
    if (_queueing) return 0;
    _queueing = true;
    try {
      final entries = await _related(id, listUrl);
      if (seq != _queueSeq || _target == null) return 0;
      final at = entries.indexWhere((e) => UrlUtils.videoId(e.url) == id);
      final after = at >= 0 ? entries.sublist(at + 1) : entries;
      final items = <CastItem>[];
      for (final e in after) {
        final eid = UrlUtils.videoId(e.url);
        if (eid == null || _playedIds.contains(eid)) continue;
        _playedIds.add(eid);
        items.add(CastItem(
          uri: 'https://www.youtube.com/watch?v=$eid',
          title: e.displayTitle,
          mime: 'video/mp4',
          stream: true,
        ));
        if (items.length >= 50) break;
      }
      if (items.isEmpty) return 0;
      try {
        await _bridge.castAppend(items);
      } catch (_) {
        return 0;
      }
      return items.length;
    } finally {
      _queueing = false;
    }
  }

  /// The queue ran out (the TV stopped by itself): start the next related video.
  Future<void> _continueAfterEnd(String id) => _playNextRelated(id);

  /// Next on the TV. Uses the queue; when the queue is empty it finds a related
  /// video and plays it straight away, like the YouTube app.
  Future<void> castNext() async {
    final s = _cast;
    final id = _castVideoId;
    if (s.active && s.index < s.count - 1) {
      await castControl('next');
      return;
    }
    if (id == null) {
      await castControl('next');
      return;
    }
    await _playNextRelated(id);
  }

  Future<void> _playNextRelated(String id) async {
    if (_continuing) return;
    _continuing = true;
    notifyListeners();
    try {
      final seq = _queueSeq;
      final entries = await _related(id, null);
      if (seq != _queueSeq || _target == null || _userStopped) return;
      for (final e in entries) {
        final eid = UrlUtils.videoId(e.url);
        if (eid == null || _playedIds.contains(eid)) continue;
        castAdvanced.value = eid;
        await castPlayNow('https://www.youtube.com/watch?v=$eid', keepHistory: true);
        return;
      }
      _say('No next video found');
    } finally {
      _continuing = false;
      notifyListeners();
    }
  }

  /// Runs on every state change from the TV session.
  void _onCastChanged(CastState s) {
    if (s.status == 'ended' && _wasActive && !_userStopped && _target != null && _castVideoId != null) {
      _wasActive = false;
      unawaited(_continueAfterEnd(_castVideoId!));
      return;
    }
    if (!s.active) {
      if (s.status == 'stopped' || s.status == 'ended' || s.status == 'error' || s.status == 'idle') _wasActive = false;
      return;
    }
    _wasActive = true;
    final id = s.uri == null ? null : UrlUtils.videoId(s.uri!);
    if (id == null) return;
    if (id != _castVideoId) {
      // The TV moved on by itself (next in the queue).
      _castVideoId = id;
      _playedIds.add(id);
      castAdvanced.value = id;
    }
    // Reached the end of the queue: ask for more related videos (once per video).
    if (s.status == 'playing' && s.count > 0 && s.index >= s.count - 1 && _extendedFor != id && !_queueing) {
      _extendedFor = id;
      unawaited(_queueMore(id, null, _queueSeq));
    }
  }

  /// Plays audio / video files from the phone on the connected TV.
  Future<List<CastItem>> pickLocalMedia() => _bridge.pickMedia();

  Future<void> castMedia(CastDevice device, List<CastItem> items) async {
    _queueSeq++;
    await _startCast(device, items);
  }

  Future<void> castSeek(int seconds) async {
    try {
      await _bridge.castControl('seek', value: seconds);
    } catch (_) {}
  }

  /// `pause`, `resume`, `next`, `previous` or `stop`.
  Future<void> castControl(String action) async {
    if (action == 'stop') _userStopped = true;
    try {
      await _bridge.castControl(action);
    } catch (_) {/* the TV state event will tell the story */}
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
    inPip.value = false;
    await _syncNative();
    try {
      _cast = await _bridge.castState();
    } catch (_) {}
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
    if (e['type'] == 'castPos') {
      final pos = (e['position'] as num?)?.toInt() ?? 0;
      final dur = (e['duration'] as num?)?.toInt() ?? 0;
      castProgress.value = CastProgress(position: pos, duration: dur);
      // Near the end of the last queued video and nothing is queued behind it: look again.
      final id = _castVideoId;
      if (id != null &&
          dur > 20 &&
          pos >= dur - 25 &&
          _cast.active &&
          _cast.index >= _cast.count - 1 &&
          !_queueing &&
          DateTime.now().difference(_lastMore) > const Duration(seconds: 15)) {
        _lastMore = DateTime.now();
        unawaited(_queueMore(id, null, _queueSeq));
      }
      return;
    }
    if (e['type'] == 'pip') {
      inPip.value = e['on'] == true;
      return;
    }
    if (e['type'] == 'web') {
      final action = e['action'];
      if (action is String && !_webActions.isClosed) _webActions.add(action);
      return;
    }
    if (e['type'] == 'cast') {
      _cast = CastState.fromMap(e);
      if (_cast.status == 'error' && _cast.error != null) _say(_cast.error!);
      _onCastChanged(_cast);
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
    castProgress.dispose();
    castAdvanced.dispose();
    browseVideoId.dispose();
    openVideo.dispose();
    playerId.dispose();
    playerMini.dispose();
    miniOffset.dispose();
    playerHeight.dispose();
    audioMode.dispose();
    _keepTimer?.cancel();
    inPip.dispose();
    _webActions.close();
    super.dispose();
  }
}
