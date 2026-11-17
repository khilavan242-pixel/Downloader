import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/playlist_entry.dart';
import '../state/download_controller.dart';
import '../utils/url_utils.dart';

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

  @override
  void initState() {
    super.initState();
    c.onPlayerBack = _handleBack;
    c.playerId.addListener(_onIdChange);
    _sub = c.webActions.listen(_onAction);
    final id = c.playerId.value;
    if (id != null) unawaited(_load(id, pushHistory: false));
  }

  @override
  void dispose() {
    c.onPlayerBack = null;
    c.playerId.removeListener(_onIdChange);
    _sub?.cancel();
    _hideTimer?.cancel();
    _flashTimer?.cancel();
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
    unawaited(_load(id, pushHistory: false));
  }

  Future<Map<String, dynamic>?> _tryResolve(String id) async {
    try {
      return await c.resolveStream(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load(String id, {bool pushHistory = true}) async {
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
    });
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    try {
      Map<String, dynamic>? r;
      if (_preId == id && _preFuture != null) r = await _preFuture;
      _preId = null;
      _preFuture = null;
      r ??= await c.resolveStream(id);
      final info = r;
      if (!mounted || seq != _seq) return;
      final vc = VideoPlayerController.networkUrl(
        Uri.parse(info['url'] as String),
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
        },
      );
      try {
        await vc.initialize();
      } catch (_) {
        await vc.dispose();
        rethrow;
      }
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
      await vc.play();
      _skips = 0;
      _auto = false;
      _lastPlaying = true;
      c.setWebPlaying(true);
      c.updatePip(ready: true, playing: true);
      _showControls();
      if (_queue.length < 3) unawaited(_loadQueue(id, seq));
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

  Future<void> _loadQueue(String id, int seq) async {
    try {
      var list = await c.upNext(id, _title);
      if (list.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 4));
        if (!mounted || seq != _seq) return;
        list = await c.upNext(id, _title);
      }
      if (!mounted || seq != _seq) return;
      setState(() {
        _queue = [
          for (final e in list)
            if (!_played.contains(UrlUtils.videoId(e.url))) e,
        ];
      });
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
    if (nid != null) unawaited(_load(nid));
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
            : const CircularProgressIndicator(color: Colors.white70),
      );
    }
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
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text(
                          _loading && _title.isEmpty ? 'Loading...' : _title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FilledButton.tonal(
                            onPressed: () {
                              final id = _id;
                              if (id != null) unawaited(_load(id, pushHistory: false));
                            },
                            child: const Text('Try again'),
                          ),
                        ),
                      if (_queue.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('Up next', style: Theme.of(context).textTheme.titleSmall),
                        ),
                      for (final e in _queue.take(30)) _queueTile(e),
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

  Widget _miniBar() {
    final vc = _vc;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      child: InkWell(
        onTap: () => c.playerMini.value = false,
        child: Row(
          children: [
            SizedBox(width: 114, height: 64, child: ColoredBox(color: Colors.black, child: _picture())),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  _loading && _title.isEmpty ? 'Loading...' : _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            if (vc != null)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: vc,
                builder: (context, v, _) => IconButton(
                  onPressed: _toggle,
                  icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
            IconButton(onPressed: _close, icon: const Icon(Icons.close_rounded)),
          ],
        ),
      ),
    );
  }

  Widget _queueTile(PlaylistEntry e) {
    final id = UrlUtils.videoId(e.url);
    return ListTile(
      leading: SizedBox(
        width: 112,
        height: 63,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: id == null
              ? const ColoredBox(color: Colors.black12)
              : Image.network(
                  'https://i.ytimg.com/vi/$id/mqdefault.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12),
                ),
        ),
      ),
      title: Text(e.title.trim().isEmpty ? 'Video' : e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: e.duration.isEmpty ? null : Text(e.duration),
      onTap: () {
        _queue.remove(e);
        if (id != null) unawaited(_load(id));
      },
    );
  }
}
