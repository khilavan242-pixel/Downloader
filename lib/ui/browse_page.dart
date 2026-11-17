import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'cast_sheet.dart';
import 'download_sheet.dart';
import 'tv_player.dart';

/// Runs inside the YouTube page. While a TV is connected it silences the
/// phone's own player and reports where the video picture is, so Tapnab can
/// draw the TV controls exactly on top of it.
const _watcher = r'''
(function(){
  if (window.__tapnabInit) return;
  window.__tapnabInit = true;
  if (typeof window.__tapnabOn === 'undefined') window.__tapnabOn = false;
  if (typeof window.__tapnabKeep === 'undefined') window.__tapnabKeep = false;
  window.__userPausedUntil = 0;
  window.__lastTouch = 0;
  ['touchstart','pointerdown','keydown','click'].forEach(function(n){
    document.addEventListener(n, function(){ window.__lastTouch = Date.now(); }, true);
  });
  // The page pauses its player by itself when the app leaves the screen: start it again,
  // unless the user paused it.
  document.addEventListener('pause', function(e){
    try {
      var v = e.target;
      if (!v || v.tagName !== 'VIDEO') return;
      if (!window.__tapnabKeep || window.__tapnabOn || v.ended) return;
      var now = Date.now();
      if (now - window.__lastTouch < 1500 || now < window.__userPausedUntil) return;
      setTimeout(function(){
        if (!window.__tapnabKeep || window.__tapnabOn || v.ended || !v.paused) return;
        if (Date.now() < window.__userPausedUntil) return;
        var r = v.play(); if (r && r.catch) r.catch(function(){});
      }, 150);
    } catch (x) {}
  }, true);
  function post(o) { try { Tapnab.postMessage(JSON.stringify(o)); } catch (e) {} }

  // Keep playing when the app is in the background or the screen is off (like YouTube Premium):
  // the page must never believe it is hidden.
  try {
    var vis = {hidden: false, webkitHidden: false, visibilityState: 'visible', webkitVisibilityState: 'visible'};
    Object.keys(vis).forEach(function(k){
      Object.defineProperty(document, k, {get: function(){ return vis[k]; }, configurable: true});
    });
  } catch (e) {}
  ['visibilitychange', 'webkitvisibilitychange'].forEach(function(n){
    window.addEventListener(n, function(e){ e.stopImmediatePropagation(); }, true);
    document.addEventListener(n, function(e){ e.stopImmediatePropagation(); }, true);
  });

  function mainVideo() {
    var vs = document.getElementsByTagName('video');
    var best = null, area = 0;
    for (var i = 0; i < vs.length; i++) {
      var r = vs[i].getBoundingClientRect();
      var a = r.width * r.height;
      if (a > area) { area = a; best = vs[i]; }
    }
    return best;
  }
  function toast(msg) {
    var d = document.getElementById('__tn');
    if (!d) {
      d = document.createElement('div');
      d.id = '__tn';
      d.style.cssText = 'position:fixed;top:40%;left:50%;transform:translateX(-50%);background:rgba(0,0,0,.72);' +
        'color:#fff;padding:10px 18px;border-radius:20px;font:600 16px sans-serif;z-index:2147483647;' +
        'pointer-events:none;transition:opacity .3s;opacity:0';
      document.body.appendChild(d);
    }
    d.textContent = msg;
    d.style.opacity = 1;
    clearTimeout(d.__t);
    d.__t = setTimeout(function(){ d.style.opacity = 0; }, 700);
  }

  // Floating-window mode: only the picture, filling the window.
  window.__tapnabPip = function(on) {
    var s = document.getElementById('__tpip');
    if (on) {
      if (!s) {
        s = document.createElement('style');
        s.id = '__tpip';
        s.textContent = 'html,body{background:#000!important;overflow:hidden!important}' +
          'video{position:fixed!important;left:0!important;top:0!important;width:100vw!important;' +
          'height:100vh!important;object-fit:contain!important;z-index:2147483647!important;background:#000!important}';
        document.head.appendChild(s);
      }
    } else if (s) { s.remove(); }
  };

  // Scroll direction (hides / shows the bottom bar).
  var lastY = {}, lastDir = 0, lastHref = location.href;
  window.addEventListener('scroll', function(e){
    try {
      if (location.href !== lastHref) { lastHref = location.href; lastDir = 0; }
      var t = e.target;
      var isDoc = (t === document || t === document.documentElement || t === document.body);
      var y = isDoc ? (window.scrollY || 0) : (t.scrollTop || 0);
      var k = isDoc ? 'doc' : (t.tagName || 'x');
      var prev = lastY[k];
      lastY[k] = y;
      if (prev === undefined) return;
      var d = y - prev;
      if (Math.abs(d) < 6) return;
      var dir = d > 0 ? 1 : -1;
      if (dir !== lastDir) { lastDir = dir; post({t: 'scroll', d: dir}); }
    } catch (x) {}
  }, {passive: true, capture: true});

  // Double tap on the video: right side +30 s, left side -10 s.
  var tapT = 0, tapX = 0, tapY = 0, startX = 0, startY = 0, doubling = false;
  function hit(x, y) {
    var v = mainVideo();
    if (!v) return null;
    var r = v.getBoundingClientRect();
    return (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) ? {v: v, r: r} : null;
  }
  window.addEventListener('touchstart', function(e){
    try {
      if (e.touches.length !== 1) { tapT = 0; doubling = false; return; }
      var t = e.touches[0];
      startX = t.clientX; startY = t.clientY;
      if (tapT && Date.now() - tapT < 350 && Math.abs(t.clientX - tapX) < 100 &&
          Math.abs(t.clientY - tapY) < 100 && hit(t.clientX, t.clientY)) {
        doubling = true;
        e.stopImmediatePropagation();
        e.preventDefault();
      } else { doubling = false; }
    } catch (x) {}
  }, {capture: true, passive: false});
  window.addEventListener('touchend', function(e){
    try {
      var t = e.changedTouches[0];
      if (!t) return;
      if (doubling) {
        doubling = false; tapT = 0;
        e.stopImmediatePropagation();
        e.preventDefault();
        var h = hit(t.clientX, t.clientY);
        if (!h) return;
        var right = t.clientX > h.r.left + h.r.width / 2;
        var dur = h.v.duration || 1e9;
        h.v.currentTime = Math.max(0, Math.min(dur, h.v.currentTime + (right ? 30 : -10)));
        toast(right ? '+30 s' : '-10 s');
        return;
      }
      if (Math.abs(t.clientX - startX) < 15 && Math.abs(t.clientY - startY) < 15 && hit(t.clientX, t.clientY)) {
        tapT = Date.now(); tapX = t.clientX; tapY = t.clientY;
      } else { tapT = 0; }
    } catch (x) {}
  }, {capture: true, passive: false});

  // Full screen: fill the screen (zoom). Pinch in to fit, pinch out to fill.
  var fill = true, fillStyle = null, pinch = 0;
  function fsEl() { return document.fullscreenElement || document.webkitFullscreenElement; }
  function applyFill() {
    var on = !!fsEl() && fill;
    if (on && !fillStyle) {
      fillStyle = document.createElement('style');
      fillStyle.textContent = 'video{object-fit:cover!important}';
      document.head.appendChild(fillStyle);
    } else if (!on && fillStyle) { fillStyle.remove(); fillStyle = null; }
  }
  document.addEventListener('fullscreenchange', applyFill);
  document.addEventListener('webkitfullscreenchange', applyFill);
  function dist(ts) { var dx = ts[0].clientX - ts[1].clientX, dy = ts[0].clientY - ts[1].clientY; return Math.sqrt(dx * dx + dy * dy); }
  document.addEventListener('touchstart', function(e){ if (e.touches.length === 2) pinch = dist(e.touches); }, {passive: true, capture: true});
  document.addEventListener('touchmove', function(e){
    if (e.touches.length !== 2 || !pinch || !fsEl()) return;
    var r = dist(e.touches) / pinch;
    if (r > 1.15) { fill = true; applyFill(); toast('Fill screen'); pinch = 0; }
    else if (r < 0.87) { fill = false; applyFill(); toast('Fit screen'); pinch = 0; }
  }, {passive: true, capture: true});
  document.addEventListener('touchend', function(e){ if (e.touches.length < 2) pinch = 0; }, {passive: true, capture: true});

  // What is playing (for background play and the floating window).
  var lastMedia = '';
  setInterval(function(){
    try {
      var v = mainVideo();
      var m = /[?&]v=([A-Za-z0-9_-]{11})/.exec(location.search);
      var msg = (v && location.pathname === '/watch' && m)
        ? JSON.stringify({t: 'media', id: m[1], p: v.paused ? 0 : 1})
        : JSON.stringify({t: 'media', id: null, p: 0});
      if (msg !== lastMedia) { lastMedia = msg; Tapnab.postMessage(msg); }
    } catch (x) {}
  }, 1000);

  // While a TV is connected: keep the phone's own player silent and report where the picture is.
  var wasOn = false, last = '';
  setInterval(function(){
    try {
      if (!window.__tapnabOn) {
        if (wasOn) {
          wasOn = false;
          var vs0 = document.getElementsByTagName('video');
          for (var k = 0; k < vs0.length; k++) vs0[k].muted = false;
        }
        return;
      }
      wasOn = true;
      var vs = document.getElementsByTagName('video');
      var best = null;
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        v.muted = true;
        if (!v.paused) v.pause();
        var r = v.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && (!best || r.width * r.height > best.w * best.h)) {
          best = {x: r.left, y: r.top, w: r.width, h: r.height};
        }
      }
      var msg = JSON.stringify({t: 'rect', r: best, iw: window.innerWidth});
      if (msg !== last) { last = msg; Tapnab.postMessage(msg); }
    } catch (x) {}
  }, 450);

  // Hide YouTube's own bottom bar (Tapnab draws its own) and list "up next" videos.
  var lastRel = '';
  setInterval(function(){
    try {
      if (!window.__tapnabStyled && document.querySelector('ytm-pivot-bar-renderer')) {
        var st = document.createElement('style');
        st.textContent = 'ytm-pivot-bar-renderer{display:none!important}';
        document.head.appendChild(st);
        window.__tapnabStyled = true;
        post({t: 'pivot'});
      }
      if (!window.__tapnabOn || location.pathname !== '/watch') return;
      var m = /[?&]v=([A-Za-z0-9_-]{11})/.exec(location.search);
      if (!m) return;
      var seen = {}, ids = [];
      var as = document.querySelectorAll('a[href*="/watch?v="]');
      for (var i = 0; i < as.length && ids.length < 30; i++) {
        var mm = /[?&]v=([A-Za-z0-9_-]{11})/.exec(as[i].getAttribute('href') || '');
        if (!mm || mm[1] === m[1] || seen[mm[1]]) continue;
        seen[mm[1]] = 1;
        ids.push(mm[1]);
      }
      var msg = JSON.stringify({t: 'related', id: m[1], ids: ids});
      if (ids.length && msg !== lastRel) { lastRel = msg; Tapnab.postMessage(msg); }
    } catch (x) {}
  }, 2500);
})();
''';

/// YouTube inside Tapnab. Browse normally. With a TV connected, tapping any
/// video plays it on the TV and the phone shows the TV controls where the
/// video would be, like the YouTube app.
///
/// The web view is created the first time the tab is shown ([active]), so it
/// costs nothing until it is used.
class BrowsePage extends StatefulWidget {
  const BrowsePage({
    super.key,
    required this.controller,
    required this.active,
    required this.onNavigate,
  });

  final DownloadController controller;
  final bool active;

  /// Switches the app to another tab: 0 Home, 2 Downloads, 3 Settings.
  final void Function(int tab) onNavigate;

  @override
  State<BrowsePage> createState() => BrowsePageState();
}

class BrowsePageState extends State<BrowsePage> with WidgetsBindingObserver {
  static const _home = 'https://m.youtube.com/';

  WebViewController? _web;
  String _url = _home;
  int _progress = 0;
  Rect? _videoRect; // in page (CSS) pixels
  double _pageWidth = 0;
  bool _flag = false;
  bool _pivotHidden = false; // YouTube's own bottom bar is hidden, ours is shown
  bool _barVisible = true;
  bool _mediaPlaying = false;
  StreamSubscription<String>? _actionSub;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_syncFlag);
    c.castAdvanced.addListener(_onTvAdvanced);
    c.openVideo.addListener(_onOpenVideo);
    c.inPip.addListener(_onPip);
    WidgetsBinding.instance.addObserver(this);
    _actionSub = c.webActions.listen(_onWebAction);
    if (widget.active) _start();
  }

  @override
  void dispose() {
    c.removeListener(_syncFlag);
    c.castAdvanced.removeListener(_onTvAdvanced);
    c.openVideo.removeListener(_onOpenVideo);
    c.inPip.removeListener(_onPip);
    WidgetsBinding.instance.removeObserver(this);
    _actionSub?.cancel();
    c.setWebPlaying(false);
    c.updatePip(ready: false, playing: false);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && _web == null) _start();
    if (oldWidget.active != widget.active) _updatePip();
  }

  void _start() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Tapnab', onMessageReceived: _onPageMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Never let a page hand control to another app (intent://, vnd.youtube://, ...).
          onNavigationRequest: (request) {
            final scheme = Uri.tryParse(request.url)?.scheme ?? '';
            return (scheme == 'http' || scheme == 'https' || scheme == 'about')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onUrlChange: (change) {
            final u = change.url;
            if (u != null && mounted) _onUrl(u);
          },
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (u) {
            if (!mounted) return;
            c.browseVideoId.value = UrlUtils.videoId(u);
            setState(() {
              _url = u;
              _progress = 100;
            });
            _install();
          },
        ),
      )
      ..loadRequest(Uri.parse(_startUrl()));
    setState(() => _web = controller);
  }

  String _startUrl() {
    final id = c.openVideo.value;
    if (id == null) return _home;
    c.openVideo.value = null;
    return 'https://m.youtube.com/watch?v=$id';
  }

  /// The floating player asked to show a video's page.
  void _onOpenVideo() {
    final id = c.openVideo.value;
    final w = _web;
    if (id == null || w == null) return;
    c.openVideo.value = null;
    if (UrlUtils.videoId(_url) != id) {
      w.loadRequest(Uri.parse('https://m.youtube.com/watch?v=$id'));
    }
  }

  Future<void> _install() async {
    final w = _web;
    if (w == null) return;
    try {
      await w.runJavaScript(_watcher);
      await w.runJavaScript('window.__tapnabOn=${c.castTarget != null};');
      _pushKeep();
      _flag = c.castTarget != null;
    } catch (_) {/* the page is changing; it is installed again after the next load */}
  }

  /// Tells the page whether to keep its own player silent (a TV is connected).
  void _syncFlag() {
    final on = c.castTarget != null;
    if (on == _flag || _web == null) return;
    _flag = on;
    _web!.runJavaScript('window.__tapnabOn=$on;').catchError((_) {});
    _updatePip();
  }

  /// The floating window may start only while a video plays here and no TV is connected.
  void _updatePip() {
    final ready = _mediaPlaying && widget.active && c.castTarget == null;
    c.updatePip(ready: ready, playing: _mediaPlaying);
  }

  bool _away = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _away = state != AppLifecycleState.resumed;
    _pushKeep();
  }

  void _pushKeep() {
    final keep = _away || c.inPip.value;
    _web?.runJavaScript('window.__tapnabKeep=$keep;').catchError((_) {});
  }

  void _onPip() {
    _pushKeep();
    _web?.runJavaScript('window.__tapnabPip&&window.__tapnabPip(${c.inPip.value});').catchError((_) {});
    if (mounted) setState(() {});
  }

  /// Buttons of the floating window / background notification.
  void _onWebAction(String action) {
    final w = _web;
    if (w == null) return;
    switch (action) {
      case 'toggle':
        w.runJavaScript(
          "window.__userPausedUntil=Date.now()+3000;var v=document.querySelector('video');if(v){if(v.paused){v.play();}else{v.pause();}}",
        ).catchError((_) {});
      case 'prev':
        w.runJavaScript("var v=document.querySelector('video');if(v){v.currentTime=0;}").catchError((_) {});
      case 'next':
        final id = UrlUtils.videoId(_url);
        final next = id == null ? null : c.firstRelated(id);
        if (next != null) {
          w.loadRequest(Uri.parse('https://m.youtube.com/watch?v=$next'));
        } else {
          w.runJavaScript(
            "var b=document.querySelector('.ytp-next-button,button[aria-label=\"Next video\"],button[aria-label=\"Next\"]');if(b){b.click();}",
          ).catchError((_) {});
        }
    }
  }

  void _onPageMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      switch (j['t']) {
        case 'pivot':
          if (mounted) setState(() => _pivotHidden = true);
        case 'scroll':
          final down = (j['d'] as num?) == 1;
          if (mounted && _barVisible == down) setState(() => _barVisible = !down);
        case 'media':
          final playing = j['p'] == 1 && j['id'] != null;
          if (playing != _mediaPlaying) {
            _mediaPlaying = playing;
            c.setWebPlaying(playing);
            _updatePip();
          }
        case 'related':
          final ids = (j['ids'] as List<dynamic>).whereType<String>().toList();
          c.offerRelated(j['id'] as String, ids);
        case 'rect':
          final r = j['r'] as Map<String, dynamic>?;
          final iw = (j['iw'] as num?)?.toDouble() ?? 0;
          final rect = r == null
              ? null
              : Rect.fromLTWH(
                  (r['x'] as num).toDouble(),
                  (r['y'] as num).toDouble(),
                  (r['w'] as num).toDouble(),
                  (r['h'] as num).toDouble(),
                );
          if (!mounted) return;
          setState(() {
            _videoRect = rect;
            _pageWidth = iw;
          });
      }
    } catch (_) {}
  }

  /// The page moved to [u]. With a TV connected, a video page starts on the TV.
  void _onUrl(String u) {
    final before = UrlUtils.videoId(_url);
    c.browseVideoId.value = UrlUtils.videoId(u);
    setState(() {
      _url = u;
      _barVisible = true;
    });
    final now = UrlUtils.videoId(u);
    if (c.castTarget != null && now != null && now != before) {
      c.castPlayNow(u, listUrl: _listUrl(u));
    }
  }

  String? _listUrl(String u) {
    final list = Uri.tryParse(u)?.queryParameters['list'];
    if (list == null || list.isEmpty) return null;
    return list.startsWith('RD') ? u : 'https://www.youtube.com/playlist?list=$list';
  }

  /// The TV went on to the next video by itself: show that video's page.
  void _onTvAdvanced() {
    final id = c.castAdvanced.value;
    final w = _web;
    if (id == null || w == null) return;
    final here = UrlUtils.videoId(_url);
    if (here != null && here != id) {
      w.loadRequest(Uri.parse('https://m.youtube.com/watch?v=$id'));
    }
  }

  /// Goes back inside the page. Returns false when there is nothing to go back to.
  Future<bool> goBack() async {
    final w = _web;
    if (w == null) return false;
    if (await w.canGoBack()) {
      await w.goBack();
      return true;
    }
    return false;
  }

  Future<void> _connectOrMenu() async {
    final picked = await pickCastDevice(context, c);
    if (picked == null) return;
    c.connectCast(picked);
    if (UrlUtils.videoId(_url) != null) {
      await c.castPlayNow(_url, listUrl: _listUrl(_url));
    }
  }

  Future<void> _changeDevice() async {
    final picked = await pickCastDevice(context, c);
    if (picked == null) return;
    await c.disconnectCast();
    c.connectCast(picked);
    if (UrlUtils.videoId(_url) != null) {
      await c.castPlayNow(_url, listUrl: _listUrl(_url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _web;
    if (w == null) {
      return const SafeArea(child: Center(child: Text('Browse')));
    }
    final loading = _progress < 100;

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, box) => ListenableBuilder(
          listenable: Listenable.merge([c, c.inPip]),
          builder: (context, _) {
            final pip = c.inPip.value;
            final connected = c.castTarget != null;
            final pageId = UrlUtils.videoId(_url);
            final onWatch = pageId != null;
            final showPanel = connected && onWatch;
            final showBar = _pivotHidden && !onWatch;
            final clusterBottom = !_pivotHidden ? 128.0 : (showBar && _barVisible ? 64.0 : 16.0);
            final canDownload = UrlUtils.isDownloadablePage(_url);

            Rect panel = Rect.fromLTWH(0, 0, box.maxWidth, box.maxWidth * 9 / 16);
            final r = _videoRect;
            if (r != null && _pageWidth > 0) {
              final scale = box.maxWidth / _pageWidth;
              final mapped = Rect.fromLTWH(r.left * scale, r.top * scale, r.width * scale, r.height * scale);
              // Ignore pictures that are clearly not the main player (small previews, bottom of page).
              if (mapped.width > box.maxWidth * 0.5 && mapped.top < box.maxHeight * 0.5) panel = mapped;
            }

            return Stack(
              children: [
                Positioned.fill(child: WebViewWidget(controller: w)),
                // In the floating window only the picture is shown.
                if (!pip && loading)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
                  ),
                if (showPanel && !pip)
                  Positioned.fromRect(
                    rect: panel,
                    child: TvPlayerPanel(
                      controller: c,
                      videoId: pageId,
                      onPlayHere: () => c.castPlayNow(_url, listUrl: _listUrl(_url)),
                      onChangeDevice: _changeDevice,
                    ),
                  ),
                if (showBar && !pip)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedSlide(
                      offset: _barVisible ? Offset.zero : const Offset(0, 1),
                      duration: const Duration(milliseconds: 200),
                      child: _bottomBar(context, w),
                    ),
                  ),
                if (!pip)
                  AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  right: 8,
                  bottom: clusterBottom,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (onWatch && !connected) ...[
                        _roundButton(
                          icon: Icons.picture_in_picture_alt_rounded,
                          tooltip: 'Floating window',
                          onTap: () => c.enterPip(),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (canDownload) ...[
                        _roundButton(
                          icon: Icons.download_rounded,
                          tooltip: 'Download',
                          onTap: () => showDownloadSheet(context, c, _url),
                        ),
                        const SizedBox(height: 8),
                      ],
                      _castButton(connected),
                      const SizedBox(height: 8),
                      _menuButton(context, w),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context, WebViewController w) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final path = Uri.tryParse(_url)?.path ?? '/';
    final onHome = path == '/' || path.isEmpty;
    final onShorts = path.startsWith('/shorts');
    final onYou = path.startsWith('/feed/you') || path.startsWith('/feed/library');
    final fg = dark ? Colors.white : Colors.black;
    Widget item(IconData icon, String label, bool on, String target) {
      return Expanded(
        child: InkWell(
          onTap: () {
            setState(() => _barVisible = true);
            w.loadRequest(Uri.parse('https://m.youtube.com$target'));
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg.withValues(alpha: on ? 1 : 0.7), size: 24),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: fg.withValues(alpha: on ? 1 : 0.7),
                  fontSize: 11,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: dark ? const Color(0xFF0F0F0F) : Colors.white,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            item(onHome ? Icons.home_rounded : Icons.home_outlined, 'Home', onHome, '/'),
            item(Icons.slow_motion_video_rounded, 'Shorts', onShorts, '/shorts'),
            item(onYou ? Icons.account_circle : Icons.account_circle_outlined, 'You', onYou, '/feed/you'),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: SizedBox(
        width: 38,
        height: 38,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: tooltip,
          icon: Icon(icon, color: Colors.white),
          onPressed: onTap,
        ),
      ),
    );
  }

  Widget _castButton(bool connected) {
    if (!connected) {
      return _roundButton(icon: Icons.cast_rounded, tooltip: 'Connect to TV', onTap: _connectOrMenu);
    }
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: SizedBox(
        width: 38,
        height: 38,
        child: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: 'TV',
          icon: const Icon(Icons.cast_connected_rounded, color: Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onSelected: (v) {
            switch (v) {
              case 'here':
                c.castPlayNow(_url, listUrl: _listUrl(_url));
              case 'local':
                castLocalFiles(context, c);
              case 'change':
                _changeDevice();
              case 'disconnect':
                c.disconnectCast();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(enabled: false, child: Text('Connected to ${c.castTarget?.name ?? 'TV'}')),
            if (UrlUtils.videoId(_url) != null) const PopupMenuItem(value: 'here', child: Text('Play this on TV')),
            const PopupMenuItem(value: 'local', child: Text('Play files from phone')),
            const PopupMenuItem(value: 'change', child: Text('Change TV')),
            const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
          ],
        ),
      ),
    );
  }

  Widget _menuButton(BuildContext context, WebViewController w) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: SizedBox(
        width: 38,
        height: 38,
        child: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: 'Tapnab menu',
          icon: const Icon(Icons.apps_rounded, color: Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onSelected: (v) {
            switch (v) {
              case 'home':
                widget.onNavigate(0);
              case 'downloads':
                widget.onNavigate(2);
              case 'settings':
                widget.onNavigate(3);
              case 'local':
                castLocalFiles(context, c);
              case 'yt':
                w.loadRequest(Uri.parse(_home));
              case 'reload':
                w.reload();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'home', child: Text('Tapnab home')),
            PopupMenuItem(value: 'downloads', child: Text('Downloads')),
            PopupMenuItem(value: 'settings', child: Text('Settings')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'local', child: Text('Play local files on TV')),
            PopupMenuItem(value: 'yt', child: Text('YouTube home')),
            PopupMenuItem(value: 'reload', child: Text('Reload page')),
          ],
        ),
      ),
    );
  }
}
