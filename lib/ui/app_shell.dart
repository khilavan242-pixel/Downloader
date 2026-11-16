import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/download_controller.dart';
import 'browse_page.dart';
import 'downloads_page.dart';
import 'floating_player.dart';
import 'home_page.dart';
import 'settings_page.dart';

/// Bottom navigation: Home, Browse, Downloads, Settings.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _home = 0, _browse = 1, _downloads = 2, _settings = 3;

  // The app opens on YouTube, like the YouTube app.
  int _index = _browse;
  StreamSubscription<String>? _msgSub;
  final _browseKey = GlobalKey<BrowsePageState>();

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.incoming.addListener(_onIncoming);
    _msgSub = c.messages.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.incoming.removeListener(_onIncoming);
    _msgSub?.cancel();
    super.dispose();
  }

  /// A link arrived from "Open Tapnab for more options": show the Home page.
  void _onIncoming() {
    if (c.incoming.value != null && _index != _home) setState(() => _index = _home);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      c.flush();
    }
  }

  void _go(int i) => setState(() => _index = i);

  /// Floating player tapped: show that video's page in the Browse tab.
  void _openVideo(String id) {
    c.openVideo.value = id;
    _go(_browse);
  }

  /// Back button: leave selection, go back in the browser, return to Home, then exit.
  Future<void> _onBack() async {
    if (c.selecting) {
      c.clearSelection();
      return;
    }
    if (_index == _browse && await (_browseKey.currentState?.goBack() ?? Future.value(false))) return;
    if (_index != _browse) {
      _go(_browse);
      return;
    }
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.browseVideoId]),
      builder: (context, _) {
        final active = c.activeCount;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_onBack());
          },
          child: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      HomePage(
                        controller: c,
                        onOpenDownloads: () => _go(_downloads),
                        onOpenSettings: () => _go(_settings),
                      ),
                      BrowsePage(key: _browseKey, controller: c, active: _index == _browse, onNavigate: _go),
                      DownloadsPage(controller: c),
                      SettingsPage(controller: c),
                    ],
                  ),
                ),
                if (_floatingVisible())
                  Positioned.fill(child: FloatingCast(controller: c, onOpenVideo: _openVideo)),
              ],
            ),
            // Browse is full screen, like the YouTube app: no Tapnab bar in the way.
            bottomNavigationBar: _index == _browse
                ? null
                : _navBar(active),
          ),
        );
      },
    );
  }

  /// The floating window shows while the TV plays, except when the Browse tab
  /// is already showing that very video (its controls are on the page then).
  bool _floatingVisible() {
    final s = c.cast;
    if (!(s.active || s.status == 'connecting')) return false;
    final shown = c.browseVideoId.value;
    if (_index == _browse && shown != null && shown == c.castVideoId) return false;
    return true;
  }

  Widget _navBar(int active) {
    return NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _go,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.link_rounded),
                  selectedIcon: Icon(Icons.link_rounded),
                  label: 'Link',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.travel_explore_outlined),
                  selectedIcon: Icon(Icons.travel_explore_rounded),
                  label: 'YouTube',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: active > 0,
                    label: Text('$active'),
                    child: const Icon(Icons.download_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: active > 0,
                    label: Text('$active'),
                    child: const Icon(Icons.download_rounded),
                  ),
                  label: 'Downloads',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Settings',
                ),
              ],
            );
  }
}
