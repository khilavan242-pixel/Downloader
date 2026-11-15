import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/quality.dart';

/// Persists user choices. The native side reads several of these keys straight
/// from the same preferences file (see AppSettings.kt), so keep the names.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kKind = 'kind';
  static const _kAudioQuality = 'audio_quality';
  static const _kVideoQuality = 'video_quality';
  static const _kFolderUri = 'selected_folder_uri';
  static const _kPlaylist = 'playlist_mode';
  static const _kNameStyle = 'name_style';
  static const _kCoverArt = 'cover_art';
  static const _kPlaylistFolders = 'playlist_folders';
  static const _kWifiOnly = 'wifi_only';
  static const _kParallel = 'parallel';
  static const _kAutoUpdate = 'auto_update';
  static const _kThemeMode = 'theme_mode';

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  MediaKind get kind => MediaKind.fromName(_prefs.getString(_kKind) ?? 'mp3');
  set kind(MediaKind v) => _prefs.setString(_kKind, v.name);

  QualityOption qualityFor(MediaKind kind) {
    final key = _prefs.getString(kind == MediaKind.mp3 ? _kAudioQuality : _kVideoQuality);
    final q = QualityOption.fromKey(key);
    return q.kind == kind ? q : QualityOption.defaultFor(kind);
  }

  void saveQuality(QualityOption q) => _prefs.setString(
        q.kind == MediaKind.mp3 ? _kAudioQuality : _kVideoQuality,
        q.key,
      );

  /// `null` means "default location" (Music/Tapnab or Movies/Tapnab).
  String? get folderUri => _prefs.getString(_kFolderUri);
  set folderUri(String? v) {
    if (v == null) {
      _prefs.remove(_kFolderUri);
    } else {
      _prefs.setString(_kFolderUri, v);
    }
  }

  bool get playlist => _prefs.getBool(_kPlaylist) ?? false;
  set playlist(bool v) => _prefs.setBool(_kPlaylist, v);

  // ---- Settings page ----------------------------------------------------------

  /// `original`, `clean` or `short`.
  String get nameStyle => _prefs.getString(_kNameStyle) ?? 'clean';
  set nameStyle(String v) => _prefs.setString(_kNameStyle, v);

  bool get coverArt => _prefs.getBool(_kCoverArt) ?? true;
  set coverArt(bool v) => _prefs.setBool(_kCoverArt, v);

  bool get playlistFolders => _prefs.getBool(_kPlaylistFolders) ?? true;
  set playlistFolders(bool v) => _prefs.setBool(_kPlaylistFolders, v);

  bool get wifiOnly => _prefs.getBool(_kWifiOnly) ?? false;
  set wifiOnly(bool v) => _prefs.setBool(_kWifiOnly, v);

  /// Downloads running at the same time, 1 to 4.
  int get parallel => (_prefs.getInt(_kParallel) ?? 2).clamp(1, 4);
  set parallel(int v) => _prefs.setInt(_kParallel, v.clamp(1, 4));

  bool get autoUpdate => _prefs.getBool(_kAutoUpdate) ?? true;
  set autoUpdate(bool v) => _prefs.setBool(_kAutoUpdate, v);

  ThemeMode get themeMode => switch (_prefs.getString(_kThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  set themeMode(ThemeMode v) => _prefs.setString(_kThemeMode, v.name);
}
