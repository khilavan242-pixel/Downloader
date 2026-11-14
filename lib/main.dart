import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/history_store.dart';
import 'services/native_bridge.dart';
import 'services/settings_store.dart';
import 'state/download_controller.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  final settings = await SettingsStore.open();
  final history = await HistoryStore.open();
  final controller = DownloadController(
    bridge: NativeBridge(),
    settings: settings,
    history: history,
  );
  await controller.init();
  runApp(TapnabApp(controller: controller));
}

class TapnabApp extends StatelessWidget {
  const TapnabApp({super.key, required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tapnab',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: AppShell(controller: controller),
    );
  }
}
