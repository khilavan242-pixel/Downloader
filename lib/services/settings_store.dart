import 'package:shared_preferences/shared_preferences.dart';

import '../models/quality.dart';

/// Persists the small amount of UI state worth remembering between launches.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kKind = 'kind';
  static const _kAudioQuality = 'audio_quality';
  static const _kVideoQuality = 'video_quality';
  static const _kFolderUri = 'selected_folder_uri';
  static const _kPlaylist = 'playlist_mode';

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
}
