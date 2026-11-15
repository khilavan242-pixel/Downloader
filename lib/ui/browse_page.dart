import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'cast_bar.dart';
import 'cast_sheet.dart';
import 'download_sheet.dart';
import 'theme.dart';

/// YouTube inside Tapnab. Browse normally; when the page is a video or a
/// playlist a Download button floats over it.
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

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(covariant BrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && _web == null) _start();
  }

  void _start() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
            if (u != null && mounted) setState(() => _url = u);
          },
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (u) {
            if (mounted) setState(() {
              _url = u;
              _progress = 100;
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(_home));
    setState(() => _web = controller);
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

  @override
  Widget build(BuildContext context) {
    final w = _web;
    if (w == null) {
      return const SafeArea(child: Center(child: Text('Browse')));
    }
    final canDownload = UrlUtils.isDownloadablePage(_url);
    final loading = _progress < 100;

    // Full screen, like the YouTube app: only the status bar is kept free, and
    // a few small floating buttons sit above YouTube's own bottom bar.
    return SafeArea(
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: w)),
          if (loading)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(value: _progress / 100, minHeight: 3),
            ),
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => Positioned(
              left: 0,
              right: 0,
              top: 4,
              child: CastBar(controller: c),
            ),
          ),
          Positioned(left: 12, bottom: 84, child: _menuButton(context, w)),
          Positioned(
            right: 12,
            bottom: 84,
            child: canDownload
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _roundButton(
                        icon: Icons.tv_rounded,
                        tooltip: 'Play on TV',
                        onTap: () => castYoutube(context, c, [_url]),
                      ),
                      const SizedBox(height: 10),
                      _downloadPill(context),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _roundButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white),
        onPressed: onTap,
      ),
    );
  }

  Widget _menuButton(BuildContext context, WebViewController w) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
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
          PopupMenuItem(value: 'yt', child: Text('YouTube home')),
          PopupMenuItem(value: 'reload', child: Text('Reload page')),
        ],
      ),
    );
  }

  Widget _downloadPill(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Brand.violet.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () => showDownloadSheet(context, c, _url),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Download',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
