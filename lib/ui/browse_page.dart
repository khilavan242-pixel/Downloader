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
  var last = '';
  var wasOn = false;
  setInterval(function(){
    try {
      var vs = document.getElementsByTagName('video');
      if (wasOn && !window.__tapnabOn) { for (var k = 0; k < vs.length; k++) vs[k].muted = false; }
      wasOn = window.__tapnabOn;
      var best = null;
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        if (window.__tapnabOn) { v.muted = true; if (!v.paused) v.pause(); }
        var r = v.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && (!best || r.width * r.height > best.w * best.h)) {
          best = {x: r.left, y: r.top, w: r.width, h: r.height};
        }
      }
      var msg = JSON.stringify({t: 'rect', r: best, iw: window.innerWidth});
      if (msg !== last) { last = msg; Tapnab.postMessage(msg); }
    } catch (e) {}
  }, 350);
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

class BrowsePageState extends State<BrowsePage> {
  static const _home = 'https://m.youtube.com/';

  WebViewController? _web;
  String _url = _home;
  int _progress = 0;
  Rect? _videoRect; // in page (CSS) pixels
  double _pageWidth = 0;
  bool _flag = false;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_syncFlag);
    c.castAdvanced.addListener(_onTvAdvanced);
    if (widget.active) _start();
  }

  @override
  void dispose() {
    c.removeListener(_syncFlag);
    c.castAdvanced.removeListener(_onTvAdvanced);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && _web == null) _start();
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
            setState(() {
              _url = u;
              _progress = 100;
            });
            _install();
          },
        ),
      )
      ..loadRequest(Uri.parse(_home));
    setState(() => _web = controller);
  }

  Future<void> _install() async {
    final w = _web;
    if (w == null) return;
    try {
      await w.runJavaScript(_watcher);
      await w.runJavaScript('window.__tapnabOn=${c.castTarget != null};');
      _flag = c.castTarget != null;
    } catch (_) {/* the page is changing; it is installed again after the next load */}
  }

  /// Tells the page whether to keep its own player silent (a TV is connected).
  void _syncFlag() {
    final on = c.castTarget != null;
    if (on == _flag || _web == null) return;
    _flag = on;
    _web!.runJavaScript('window.__tapnabOn=$on;').catchError((_) {});
  }

  void _onPageMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
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
    } catch (_) {}
  }

  /// The page moved to [u]. With a TV connected, a video page starts on the TV.
  void _onUrl(String u) {
    final before = UrlUtils.videoId(_url);
    setState(() => _url = u);
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
          listenable: c,
          builder: (context, _) {
            final connected = c.castTarget != null;
            final pageId = UrlUtils.videoId(_url);
            final onWatch = pageId != null;
            final showPanel = connected && onWatch;
            final showMini = connected && !onWatch && (c.cast.active || c.cast.status == 'connecting');
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
                if (loading)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
                  ),
                if (showPanel)
                  Positioned.fromRect(
                    rect: panel,
                    child: TvPlayerPanel(
                      controller: c,
                      videoId: pageId,
                      onPlayHere: () => c.castPlayNow(_url, listUrl: _listUrl(_url)),
                      onChangeDevice: _changeDevice,
                    ),
                  ),
                if (showMini)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 124,
                    child: TvMiniPlayer(
                      controller: c,
                      onOpen: () {
                        final id = c.castVideoId;
                        if (id != null) w.loadRequest(Uri.parse('https://m.youtube.com/watch?v=$id'));
                      },
                    ),
                  ),
                Positioned(
                  right: 8,
                  bottom: showMini ? 196 : 128,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
