import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/playlist_entry.dart';
import '../models/quality.dart';
import '../state/download_controller.dart';
import '../utils/url_utils.dart';


/// Size of the small floating player.
const double kMiniWidth = 220;
const double kMiniHeight = 124;

/// Runs inside the small web view under the video: it shows YouTube's own list of
/// related videos (big thumbnails, like the YouTube app) without YouTube's player.
const _feedScript = r'''
(function(){
  if (window.__tfeed) return;
  window.__tfeed = true;
  function post(o){ try { TapnabFeed.postMessage(JSON.stringify(o)); } catch (e) {} }
  var st = document.createElement('style');
  st.textContent = '#player-container-id,.player-container,#player,.player-size,ytm-custom-control,.html5-video-player,video,ytm-pivot-bar-renderer,ytm-mobile-topbar-renderer,.mobile-topbar-header,ytm-promoted-sparkles-web-renderer,ytm-app-promo-renderer{display:none!important;height:0!important;min-height:0!important}';
  document.head.appendChild(st);
  setInterval(function(){
    try { document.querySelectorAll('video').forEach(function(v){ v.muted = true; v.pause(); }); } catch (e) {}
  }, 700);
  function idOf(h){ var m = /[?&]v=([A-Za-z0-9_-]{11})/.exec(h || ''); return m ? m[1] : null; }
  function titleOf(a){
    var t = a.getAttribute('aria-label') || '';
    if (!t) {
      var box = a.closest('ytm-video-with-context-renderer,ytm-compact-video-renderer,ytm-media-item,ytm-rich-item-renderer');
      var h = box ? box.querySelector('h3,.media-item-headline,.compact-media-item-headline') : null;
      t = (h ? h.textContent : a.textContent) || '';
    }
    return t.replace(/\s+/g, ' ').trim().slice(0, 160);
  }
  document.addEventListener('click', function(e){
    try {
      var a = e.target && e.target.closest ? e.target.closest('a[href*="/watch?v="]') : null;
      if (!a) return;
      var id = idOf(a.getAttribute('href'));
      if (!id) return;
      e.preventDefault();
      e.stopPropagation();
      post({t: 'play', id: id, title: titleOf(a)});
    } catch (x) {}
  }, true);
  var last = '';
  setInterval(function(){
    try {
      var cur = idOf(location.search) || '';
      var seen = {}, items = [];
      var as = document.querySelectorAll('a[href*="/watch?v="]');
      for (var i = 0; i < as.length && items.length < 40; i++) {
        var id = idOf(as[i].getAttribute('href'));
        if (!id || id === cur || seen[id]) continue;
        seen[id] = 1;
        items.push({id: id, title: titleOf(as[i])});
      }
      var msg = JSON.stringify({t: 'related', items: items});
      if (items.length && msg !== last) { last = msg; TapnabFeed.postMessage(msg); }
    } catch (x) {}
  }, 2000);
})();
''';

/// Tapnab's own YouTube player. Unlike the web page it never pauses by itself:
/// it floats over other apps (picture-in-picture) and keeps playing in the
/// background and with the screen off, like the YouTube app with Premium.
class PlayerView extends StatefulWidget {
  const PlayerView({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  DownloadController get c => widget.controller;

  VideoPlayerController? _vc;
  String? _id;
  String _title = '';
  String? _error;
  bool _loading = true;
  int _seq = 0;

  List<PlaylistEntry> _queue = [];
  final List<String> _history = [];
  final Set<String> _played = {};

  bool _controls = true;
  Timer? _hideTimer;
  bool _full = false;
  bool _cover = false;
  bool _advancing = false;
  bool _auto = false; // the current load was started by auto-play
  int _skips = 0;
  bool _lastPlaying = false;
  double? _drag;
  double _boxWidth = 0;
  double _tapX = 0;
  String _flash = '';
  Timer? _flashTimer;

  String? _preId;
  Future<Map<String, dynamic>?>? _preFuture;
  StreamSubscription<String>? _sub;
  WebViewController? _feed;
  String _feedId = '';
  double _speed = 1.0;
  String _lastLoadedId = '';
  bool _locked = false;
  bool _lockHint = false;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    c.onPlayerBack = _handleBack;
    c.playerId.addListener(_onIdChange);
    _sub = c.webActions.listen(_onAction);
    final id = c.playerId.value;
    if (id != null) unawaited(_load(id, pushHistory: false, title: c.playerTitle));
  }

  @override
  void dispose() {
    c.onPlayerBack = null;
    c.playerId.removeListener(_onIdChange);
    _sub?.cancel();
    _feed?.removeJavaScriptChannel('TapnabFeed').catchError((_) {});
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _lockTimer?.cancel();
    final old = _vc;
    _vc = null;
    old?.removeListener(_tick);
    old?.dispose();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onIdChange() {
    final id = c.playerId.value;
    if (id == null || id == _id) return;
    _queue = [];
    _history.clear();
    _played.clear();
    unawaited(_load(id, pushHistory: false, title: c.playerTitle));
  }

  Future<Map<String, dynamic>?> _tryResolve(String id) async {
    try {
      return await c.resolveStream(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load(String id, {bool pushHistory = true, String? title, Duration? resume}) async {
    final seq = ++_seq;
    final old = _vc;
    old?.removeListener(_tick);
    if (_id != null && pushHistory) _history.add(_id!);
    _id = id;
    _played.add(id);
    _advancing = false;
    setState(() {
      _loading = true;
      _error = null;
      _vc = null;
      _title = title ?? '';
    });
    if (c.playerListId == null && id != _lastLoadedId) _queue = [];
    _lastLoadedId = id;
    _ensureFeed(id);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    try {
      Map<String, dynamic>? pre;
      if (_preId == id && _preFuture != null) pre = await _preFuture;
      _preId = null;
      _preFuture = null;
      (VideoPlayerController, Map<String, dynamic>) opened;
      try {
        opened = await _openStream(id, legacy: false, known: pre);
      } catch (_) {
        if (!mounted || seq != _seq) return;
        // The quick way did not work for this video: use the slower, more compatible one.
        opened = await _openStream(id, legacy: true);
      }
      final vc = opened.$1;
      final info = opened.$2;
      if (!mounted || seq != _seq) {
        await vc.dispose();
        return;
      }
      vc.addListener(_tick);
      setState(() {
        _vc = vc;
        _title = (info['title'] as String?) ?? '';
        _loading = false;
      });
      await vc.setPlaybackSpeed(_speed);
      if (resume != null) await vc.seekTo(resume);
      await vc.play();
      _skips = 0;
      _auto = false;
      _lastPlaying = true;
      c.setWebPlaying(true);
      c.updatePip(ready: true, playing: true);
      _showControls();
      if (_queue.length < 3 || c.audioMode.value) unawaited(_loadQueue(id, seq));
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (_auto && _skips < 3) {
        // This video cannot be played: go on to the next one, like the YouTube app.
        _skips++;
        unawaited(_next());
        return;
      }
      _auto = false;
      setState(() {
        _loading = false;
        final why = e.toString().replaceAll('\n', ' ');
        _error = 'Could not play this video. ${why.length > 140 ? why.substring(0, 140) : why}';
      });
    }
  }

  void _ensureFeed(String id) {
    if (c.audioMode.value) return; // sound only: do not load the video list (saves data)
    final key = '$id|${c.playerListId}';
    if (_feedId == key && _feed != null) return;
    _feedId = key;
    var feed = _feed;
    if (feed == null) {
      feed = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0F0F0F))
        ..addJavaScriptChannel('TapnabFeed', onMessageReceived: _onFeedMessage)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              final scheme = Uri.tryParse(request.url)?.scheme ?? '';
              return (scheme == 'http' || scheme == 'https' || scheme == 'about')
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onPageFinished: (_) => _feed?.runJavaScript(_feedScript).catchError((_) {}),
          ),
        );
      _feed = feed;
    }
    final list = c.playerListId;
    feed.loadRequest(Uri.parse('https://m.youtube.com/watch?v=$id${list == null ? '' : '&list=$list'}'));
  }

  void _onFeedMessage(JavaScriptMessage m) {
    if (!mounted) return;
    try {
      final j = jsonDecode(m.message);
      if (j is! Map) return;
      if (j['t'] == 'play') {
        final id = j['id'];
        if (id is String) {
          final t = j['title'];
          _queue.removeWhere((e) => UrlUtils.videoId(e.url) == id);
          unawaited(_load(id, title: t is String ? t : null));
        }
      } else if (j['t'] == 'related') {
        final items = j['items'];
        if (items is! List || c.playerListId != null || !_feedId.startsWith('$_id|')) return;
        final list = <PlaylistEntry>[];
        for (final it in items) {
          if (it is! Map) continue;
          final id = it['id'];
          if (id is! String || _played.contains(id)) continue;
          final t = it['title'];
          list.add(PlaylistEntry(url: 'https://www.youtube.com/watch?v=$id', title: t is String ? t : ''));
        }
        if (list.isEmpty) return;
        _queue = list;
        _prefetchFirst();
      }
    } catch (_) {/* ignore malformed messages */}
  }

  void _prefetchFirst() {
    final first = _queue.isEmpty ? null : UrlUtils.videoId(_queue.first.url);
    if (first != null && _preId != first) {
      _preId = first;
      _preFuture = _tryResolve(first);
    }
  }

  Future<(VideoPlayerController, Map<String, dynamic>)> _openStream(
    String id, {
    required bool legacy,
    Map<String, dynamic>? known,
  }) async {
    final info = known ?? await c.resolveStream(id, legacy: legacy);
    final vc = VideoPlayerController.networkUrl(
      Uri.parse(info['url'] as String),
      httpHeaders: legacy
          ? const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
            }
          : const <String, String>{},
    );
    try {
      await vc.initialize();
    } catch (_) {
      c.forgetStream(id);
      await vc.dispose();
      rethrow;
    }
    return (vc, info);
  }

  /// The playlist ("Play all"), or a fallback list when the page gave none.
  Future<void> _loadQueue(String id, int seq) async {
    final listMode = c.playerListId != null;
    if (!listMode && !c.audioMode.value) {
      await Future<void>.delayed(const Duration(seconds: 8));
      if (!mounted || seq != _seq || _queue.isNotEmpty) return;
    }
    try {
      List<PlaylistEntry> list;
      if (listMode) {
        final all = await c.listEntries(id);
        final at = all.indexWhere((e) => UrlUtils.videoId(e.url) == id);
        list = at >= 0 ? all.sublist(at + 1) : all;
      } else {
        list = await c.upNext(id, _title);
        if (list.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 4));
          if (!mounted || seq != _seq || _queue.isNotEmpty) return;
          list = await c.upNext(id, _title);
        }
      }
      if (!mounted || seq != _seq || (_queue.isNotEmpty && !listMode)) return;
      setState(() {
        _queue = [
          for (final e in list)
            if (!_played.contains(UrlUtils.videoId(e.url))) e,
        ];
      });
      _prefetchFirst();
    } catch (_) {/* the list stays as it was */}
  }

  void _tick() {
    final vc = _vc;
    if (vc == null) return;
    final v = vc.value;
    if (v.isPlaying != _lastPlaying) {
      _lastPlaying = v.isPlaying;
      c.setWebPlaying(v.isPlaying);
      c.updatePip(ready: v.isPlaying, playing: v.isPlaying);
    }
    if (!v.isInitialized || v.duration.inMilliseconds <= 0) return;
    final left = v.duration - v.position;
    if (left < const Duration(seconds: 25) && _queue.isNotEmpty) {
      final next = UrlUtils.videoId(_queue.first.url);
      if (next != null && _preId != next) {
        _preId = next;
        _preFuture = _tryResolve(next);
      }
    }
    if (!_advancing && (v.isCompleted || (left < const Duration(milliseconds: 400) && !v.isPlaying))) {
      _advancing = true;
      _auto = true;
      unawaited(_next());
    }
  }

  Future<void> _next() async {
    if (_queue.isEmpty) {
      final id = _id;
      if (id != null) {
        try {
          final list = await c.upNext(id, _title);
          if (!mounted || id != _id) return;
          _queue = [
            for (final e in list)
              if (!_played.contains(UrlUtils.videoId(e.url))) e,
          ];
        } catch (_) {/* handled below */}
      }
    }
    if (_queue.isEmpty) {
      _snack('No next video found');
      return;
    }
    final e = _queue.removeAt(0);
    final nid = UrlUtils.videoId(e.url);
    if (nid != null) unawaited(_load(nid, title: e.title));
  }

  void _prev() {
    final vc = _vc;
    if (vc != null && vc.value.position > const Duration(seconds: 4)) {
      vc.seekTo(Duration.zero);
      return;
    }
    if (_history.isEmpty) {
      vc?.seekTo(Duration.zero);
      return;
    }
    final id = _history.removeLast();
    unawaited(_load(id, pushHistory: false));
  }

  void _toggle() {
    final vc = _vc;
    if (vc == null) return;
    if (vc.value.isPlaying) {
      vc.pause();
    } else {
      final v = vc.value;
      if (v.duration.inMilliseconds > 0 && v.position >= v.duration) vc.seekTo(Duration.zero);
      vc.play();
    }
    _showControls();
  }

  void _onAction(String a) {
    switch (a) {
      case 'toggle':
        _toggle();
      case 'prev':
        _prev();
      case 'next':
        _next();
    }
  }

  void _seekBy(int seconds) {
    final vc = _vc;
    if (vc == null) return;
    final v = vc.value;
    var t = v.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (t > v.duration) t = v.duration;
    vc.seekTo(t);
    _flashTimer?.cancel();
    setState(() => _flash = seconds > 0 ? '+$seconds s' : '$seconds s');
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flash = '');
    });
  }

  void _showControls() {
    if (_locked) return;
    _hideTimer?.cancel();
    if (!_controls && mounted) setState(() => _controls = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_vc?.value.isPlaying ?? false)) setState(() => _controls = false);
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _setFull(bool on) {
    setState(() => _full = on);
    SystemChrome.setPreferredOrientations(
      on ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [],
    );
    SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  /// Chevron / swipe down: shrink to the small bar so the app can be browsed (like the YouTube app).
  void _minimize() {
    if (_full) _setFull(false);
    c.playerMini.value = true;
  }

  /// Back button. Returns true when handled here; false lets the app handle it
  /// (the player is already the small bar).
  Future<bool> _handleBack() async {
    if (_full) {
      _setFull(false);
      return true;
    }
    if (!c.playerMini.value) {
      c.playerMini.value = true;
      return true;
    }
    return false;
  }

  void _close() {
    _vc?.pause();
    c.closePlayer();
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Widget _picture() {
    final vc = _vc;
    if (vc == null || !vc.value.isInitialized) {
      return Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (_id != null)
                    Image.network(
                      'https://i.ytimg.com/vi/$_id/mqdefault.jpg',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  const ColoredBox(color: Color(0x66000000)),
                  const Center(child: CircularProgressIndicator(color: Colors.white70)),
                ],
              ),
      );
    }
    if (c.audioMode.value) return _audioArt();
    final size = vc.value.size;
    if (_cover && size.width > 0 && size.height > 0) {
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(vc)),
        ),
      );
    }
    return Center(child: AspectRatio(aspectRatio: vc.value.aspectRatio, child: VideoPlayer(vc)));
  }

  /// Sound-only mode: the picture is not downloaded, show the video's cover instead.
  Widget _audioArt() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_id != null)
          Image.network(
            'https://i.ytimg.com/vi/$_id/mqdefault.jpg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        const ColoredBox(color: Color(0x99000000)),
        const Center(child: Icon(Icons.headphones_rounded, color: Colors.white70, size: 40)),
      ],
    );
  }

  Widget _audioList() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'Audio mode: sound only. No pictures are downloaded, so it uses much less data and battery.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (_queue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('Up next', style: Theme.of(context).textTheme.titleSmall),
          ),
        for (final e in _queue.take(40))
          ListTile(
            dense: true,
            leading: const Icon(Icons.music_note_rounded),
            title: Text(e.title.trim().isEmpty ? 'Video' : e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              final id = UrlUtils.videoId(e.url);
              _queue.remove(e);
              if (id != null) unawaited(_load(id, title: e.title));
            },
          ),
      ],
    );
  }

  // ---- Settings, like the YouTube app ----------------------------------------

  Future<void> _reloadHere() async {
    final id = _id;
    if (id == null) return;
    final pos = _vc?.value.position;
    _preId = null;
    _preFuture = null;
    await _load(id, pushHistory: false, title: _title, resume: pos);
  }

  String _heightLabel(int h) => h >= 720 ? 'Auto (720p)' : (h == 360 ? '360p (data saver)' : '${h}p');

  Future<void> _openSettings() async {
    final ctx = context;
    await showModalBottomSheet<void>(
      context: ctx,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Quality'),
              trailing: Text(c.audioMode.value ? 'Sound only' : _heightLabel(c.playerHeight.value)),
              onTap: () {
                Navigator.pop(sheet);
                _pickQuality();
              },
            ),
            ListTile(
              leading: const Icon(Icons.slow_motion_video_rounded),
              title: const Text('Playback speed'),
              trailing: Text(_speed == 1.0 ? 'Normal' : '${_speed}x'),
              onTap: () {
                Navigator.pop(sheet);
                _pickSpeed();
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Lock screen'),
              onTap: () {
                Navigator.pop(sheet);
                setState(() {
                  _locked = true;
                  _lockHint = false;
                  _controls = false;
                });
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.headphones_rounded),
              title: const Text('Audio mode (MP3 player)'),
              subtitle: const Text('Sound only. Saves data and battery.'),
              value: c.audioMode.value,
              onChanged: (on) {
                Navigator.pop(sheet);
                c.setAudioMode(on);
                if (on) {
                  _feed?.loadRequest(Uri.parse('about:blank'));
                  _feed?.removeJavaScriptChannel('TapnabFeed').catchError((_) {});
                  _feed = null;
                  _feedId = '';
                } else if (_id != null) {
                  _ensureFeed(_id!);
                }
                _reloadHere();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickQuality() async {
    const options = [720, 480, 360, 240, 144];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in options)
              ListTile(
                title: Text(_heightLabel(h)),
                trailing: (!c.audioMode.value && c.playerHeight.value == h) ? const Icon(Icons.check_rounded) : null,
                onTap: () {
                  Navigator.pop(sheet);
                  c.setPlayerHeight(h);
                  if (c.audioMode.value) c.setAudioMode(false);
                  if (_id != null) _ensureFeed(_id!);
                  _reloadHere();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSpeed() async {
    const options = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in options)
                ListTile(
                  title: Text(v == 1.0 ? 'Normal' : '${v}x'),
                  trailing: _speed == v ? const Icon(Icons.check_rounded) : null,
                  onTap: () {
                    Navigator.pop(sheet);
                    setState(() => _speed = v);
                    _vc?.setPlaybackSpeed(v);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controlsLayer() {
    final vc = _vc;
    return AnimatedOpacity(
      opacity: _controls ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_controls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const IgnorePointer(child: ColoredBox(color: Color(0x66000000))),
            Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _minimize,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 30),
                    tooltip: 'Minimize',
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _id == null ? null : () => c.downloadVideo(_id!, MediaKind.mp4),
                    icon: const Icon(Icons.download_rounded, color: Colors.white),
                    tooltip: 'Download',
                  ),
                  IconButton(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings_rounded, color: Colors.white),
                    tooltip: 'Settings',
                  ),
                  IconButton(
                    onPressed: () => c.enterPip(),
                    icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                    tooltip: 'Floating window',
                  ),
                  IconButton(
                    onPressed: () => setState(() => _cover = !_cover),
                    icon: Icon(_cover ? Icons.fit_screen_rounded : Icons.zoom_out_map_rounded, color: Colors.white),
                    tooltip: 'Fit / fill',
                  ),
                  IconButton(
                    onPressed: () => _setFull(!_full),
                    icon: Icon(_full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white),
                    tooltip: 'Full screen',
                  ),
                  IconButton(
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    tooltip: 'Close',
                  ),
                ],
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      onPressed: _prev,
                      iconSize: 36,
                      icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                    ),
                    if (vc != null)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: vc,
                        builder: (context, v, _) => IconButton(
                          onPressed: _toggle,
                          iconSize: 56,
                          icon: Icon(
                            v.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    IconButton(
                      onPressed: _next,
                      iconSize: 36,
                      icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
              if (vc != null)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: vc,
                  builder: (context, v, _) {
                    final total = v.duration.inMilliseconds.toDouble();
                    final pos = (_drag ?? v.position.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total);
                    return Row(
                      children: [
                        const SizedBox(width: 12),
                        Text(_fmt(Duration(milliseconds: pos.round())), style: const TextStyle(color: Colors.white, fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: pos,
                            max: total <= 0 ? 1.0 : total,
                            onChanged: (x) => setState(() => _drag = x),
                            onChangeEnd: (x) {
                              vc.seekTo(Duration(milliseconds: x.round()));
                              setState(() => _drag = null);
                              _showControls();
                            },
                          ),
                        ),
                        Text(_fmt(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                        const SizedBox(width: 12),
                      ],
                    );
                  },
                ),
            ],
          ),
          ],
        ),
      ),
    );
  }

  Widget _videoBox() {
    return LayoutBuilder(
      builder: (context, box) {
        _boxWidth = box.maxWidth;
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _picture(),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_controls) {
                    setState(() => _controls = false);
                  } else {
                    _showControls();
                  }
                },
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 400) _minimize();
                },
                onDoubleTapDown: (d) => _tapX = d.localPosition.dx,
                onDoubleTap: () => _seekBy(_tapX < _boxWidth / 2 ? -10 : 30),
              ),
              if (_vc != null) _controlsLayer(),
              if (_locked)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _lockHint = true);
                      _lockTimer?.cancel();
                      _lockTimer = Timer(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _lockHint = false);
                      });
                    },
                    child: Center(
                      child: _lockHint
                          ? IconButton.filledTonal(
                              onPressed: () => setState(() {
                                _locked = false;
                                _lockHint = false;
                              }),
                              icon: const Icon(Icons.lock_open_rounded),
                              tooltip: 'Unlock',
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              if (_flash.isNotEmpty)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Text(_flash, style: const TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c.inPip, c.playerMini]),
      builder: (context, _) {
        if (c.inPip.value) {
          return ColoredBox(color: Colors.black, child: _picture());
        }
        if (c.playerMini.value) return _miniBar();
        final scheme = Theme.of(context).colorScheme;
        if (_full) {
          return Material(color: Colors.black, child: _videoBox());
        }
        return Material(
          color: scheme.surface,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                AspectRatio(aspectRatio: 16 / 9, child: _videoBox()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _loading && _title.isEmpty ? 'Loading...' : _title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _id == null ? null : () => c.downloadVideo(_id!, MediaKind.mp4),
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Download video'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _id == null ? null : () => c.downloadVideo(_id!, MediaKind.mp3),
                          icon: const Icon(Icons.music_note_rounded),
                          label: const Text('Download MP3'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: FilledButton.tonal(
                      onPressed: () {
                        final id = _id;
                        if (id != null) unawaited(_load(id, pushHistory: false));
                      },
                      child: const Text('Try again'),
                    ),
                  ),
                Expanded(
                  child: (c.audioMode.value || _feed == null) ? _audioList() : WebViewWidget(controller: _feed!),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The small floating video, like the YouTube app's: tap to open, drag to move, X to close.
  Widget _miniBar() {
    final vc = _vc;
    return GestureDetector(
      onTap: () => c.playerMini.value = false,
      onPanUpdate: (d) => _dragMini(d.delta),
      child: Material(
        color: Colors.black,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _picture(),
            if (vc != null)
              Align(
                alignment: Alignment.bottomLeft,
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: vc,
                  builder: (context, v, _) => IconButton(
                    onPressed: _toggle,
                    icon: Icon(
                      v.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                onPressed: _close,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _dragMini(Offset delta) {
    final s = MediaQuery.of(context).size;
    final o = c.miniOffset.value + delta;
    c.miniOffset.value = Offset(
      o.dx.clamp(12.0 - (s.width - kMiniWidth), 12.0).toDouble(),
      o.dy.clamp(-(s.height - kMiniHeight - 200).abs(), 12.0).toDouble(),
    );
  }
}
