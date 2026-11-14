import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';

/// Keeps the download list between launches so the Downloads page works like
/// a browser's download manager.
class HistoryStore {
  HistoryStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'history_v1';
  static const maxItems = 500;

  static Future<HistoryStore> open() async =>
      HistoryStore(await SharedPreferences.getInstance());

  List<DownloadTask> load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => DownloadTask.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(Iterable<DownloadTask> tasks) async {
    final sorted = tasks.toList()..sort((a, b) => b.when.compareTo(a.when));
    final capped = sorted.take(maxItems).map((t) => t.toJson()).toList();
    await _prefs.setString(_key, jsonEncode(capped));
  }
}
