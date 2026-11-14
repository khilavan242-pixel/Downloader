import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/native_bridge.dart';
import 'services/settings_store.dart';
import 'state/download_controller.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  final settings = await SettingsStore.open();
  final controller = DownloadController(bridge: NativeBridge(), settings: settings);
  await controller.init();
  runApp(TapnabApp(controller: controller));
}

class TapnabApp extends StatelessWidget {
  const TapnabApp({super.key, required this.controller});

  final DownloadController controller;

  static ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFE53935), brightness: b);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tapnab',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: HomeScreen(controller: controller),
    );
  }
}
