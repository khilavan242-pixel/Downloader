import 'dart:async';

import 'package:flutter/material.dart';

import '../state/download_controller.dart';
import 'downloads_page.dart';
import 'home_page.dart';

/// Bottom navigation: Home and Downloads.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final DownloadController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  StreamSubscription<String>? _msgSub;

  DownloadController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _msgSub?.cancel();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final active = c.activeCount;
        return Scaffold(
          body: IndexedStack(
            index: _index,
            children: [
              HomePage(controller: c, onOpenDownloads: () => _go(1)),
              DownloadsPage(controller: c),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _go,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
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
            ],
          ),
        );
      },
    );
  }
}
