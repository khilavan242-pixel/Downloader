import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'download_sheet.dart';
import 'theme.dart';

/// YouTube inside Tapnab. Browse normally; when the page is a video or a
/// playlist a Download button floats over it.
///
/// The web view is created the first time the tab is shown ([active]), so it
/// costs nothing until it is used.
class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key, required this.controller, required this.active});

  final DownloadController controller;
  final bool active;

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
    final cs = Theme.of(context).colorScheme;
    final w = _web;
    if (w == null) {
      return const SafeArea(child: Center(child: Text('Browse')));
    }
    final canDownload = UrlUtils.isDownloadablePage(_url);
    final loading = _progress < 100;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: goBack,
                ),
                IconButton(
                  tooltip: 'YouTube home',
                  icon: const Icon(Icons.home_rounded),
                  onPressed: () => w.loadRequest(Uri.parse(_home)),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _url.replaceFirst(RegExp(r'^https?://'), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: w.reload,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 3,
            child: loading ? LinearProgressIndicator(value: _progress / 100) : null,
          ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: w),
                if (canDownload)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: DecoratedBox(
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
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
