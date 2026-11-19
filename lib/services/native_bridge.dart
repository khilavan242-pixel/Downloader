import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models/cast.dart';
import '../models/download_task.dart';
import '../models/playlist_entry.dart';
import '../models/quality.dart';
import '../models/save_folder.dart';

/// Thin typed wrapper around the Android platform channels.
///
/// Contract with `DownloadChannel.kt`:
///  * MethodChannel `tapnab/downloader`
///      enqueue({id,url,kind,quality,playlist,folderUri?,subfolder?}) -> void
///      cancel({id})                                         -> void
///      snapshot()                                           -> List<Map> (all known tasks)
///      pickFolder()                                         -> Map? (null when cancelled)
///      listFolders()                                        -> List<Map> (still-valid grants)
///      removeFolder({uri})                                  -> void
///      updateEngine()                                       -> String (new yt-dlp version)
///      consumeSharedText()                                  -> String? (text shared into the app)
///  * EventChannel `tapnab/events` streams task maps and `{type:'shared', text}` events.
class NativeBridge {
  NativeBridge({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel('tapnab/downloader'),
        _events = events ?? const EventChannel('tapnab/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<Map<dynamic, dynamic>>? _stream;

  /// Broadcast stream of raw native events.
  Stream<Map<dynamic, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => e as Map<dynamic, dynamic>)
      .asBroadcastStream();

  Future<void> enqueue({
    required String id,
    required String url,
    required MediaKind kind,
    required QualityOption quality,
    required bool playlist,
    SaveFolder? folder,
    String? subfolder,
  }) {
    return _methods.invokeMethod<void>('enqueue', {
      'id': id,
      'url': url,
      'kind': kind.name,
      'quality': quality.value,
      'playlist': playlist,
      'folderUri': folder?.uri,
      'subfolder': subfolder,
    });
  }

  Future<void> cancel(String id) =>
      _methods.invokeMethod<void>('cancel', {'id': id});

  Future<List<DownloadTask>> snapshot() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('snapshot');
    return (raw ?? const []).map(DownloadTask.fromMap).toList();
  }

  /// Opens the system folder picker. Returns null if the user backs out.
  Future<SaveFolder?> pickFolder() async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>('pickFolder');
    return raw == null ? null : SaveFolder.fromMap(raw);
  }

  Future<List<SaveFolder>> listFolders() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('listFolders');
    return (raw ?? const []).map(SaveFolder.fromMap).toList();
  }

  Future<void> removeFolder(String uri) =>
      _methods.invokeMethod<void>('removeFolder', {'uri': uri});

  /// Updates the bundled yt-dlp. YouTube changes often, so this is the first
  /// thing to try when downloads start failing.
  Future<String> updateEngine() async =>
      (await _methods.invokeMethod<String>('updateEngine')) ?? 'unknown';

  /// yt-dlp version and when the engine was last updated (epoch ms, 0 = never).
  Future<({String version, int lastUpdate})> engineInfo() async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>('engineVersion');
    return (
      version: (raw?['version'] as String?) ?? 'unknown',
      lastUpdate: (raw?['lastUpdate'] as num?)?.toInt() ?? 0,
    );
  }

  /// Lists the songs of a playlist (or the single video) without downloading.
  Future<List<PlaylistEntry>> fetchPlaylist(String url) async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('fetchPlaylist', {'url': url});
    return (raw ?? const []).map(PlaylistEntry.fromMap).toList();
  }

  /// Opens the files in the installed music / video player.
  Future<bool> playFiles(List<String> uris, String mime, String title) async =>
      (await _methods.invokeMethod<bool>('playFiles', {'uris': uris, 'mime': mime, 'title': title})) ??
      false;

  Future<String?> consumeSharedText() =>
      _methods.invokeMethod<String>('consumeSharedText');

  /// Opens the file in the user's default player. False when no app can play it.
  Future<bool> openFile(String uri, String mime) async =>
      (await _methods.invokeMethod<bool>('openFile', {'uri': uri, 'mime': mime})) ?? false;

  Future<bool> shareFile(String uri, String mime, String title) async =>
      (await _methods.invokeMethod<bool>('shareFile', {'uri': uri, 'mime': mime, 'title': title})) ??
      false;

  /// Shares several files in one go.
  Future<bool> shareFiles(List<String> uris, String mime, String title) async =>
      (await _methods.invokeMethod<bool>('shareFiles', {'uris': uris, 'mime': mime, 'title': title})) ??
      false;

  // ---- casting to a TV (DLNA) ------------------------------------------------------

  /// Looks for TVs / set-top boxes on the Wi-Fi (takes a few seconds).
  Future<List<CastDevice>> castDiscover() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('castDiscover');
    return (raw ?? const []).map(CastDevice.fromMap).toList();
  }

  /// Starts playing [items] one after another on [device].
  Future<void> castPlay(CastDevice device, List<CastItem> items) => _methods.invokeMethod<bool>(
        'castPlay',
        {'device': device.toMap(), 'items': items.map((i) => i.toMap()).toList()},
      );

  /// `pause`, `resume`, `next`, `previous`, `stop`, `seek` (value = seconds) or `volume` (0-100).
  Future<void> castControl(String action, {int value = 0}) =>
      _methods.invokeMethod<void>('castControl', {'action': action, 'value': value});

  /// Adds more items to the end of the running TV queue.
  Future<void> castAppend(List<CastItem> items) =>
      _methods.invokeMethod<void>('castAppend', {'items': items.map((i) => i.toMap()).toList()});

  /// Keeps the app awake while a video plays in the background (shows a notification).
  Future<void> keepAlive(bool on) => _methods.invokeMethod<void>('keepAlive', {'on': on});

  /// Lock-screen / notification media controls for the in-app player.
  Future<void> playerMedia(String? id, String title, bool playing, int position, int duration) =>
      _methods.invokeMethod<void>('playerMedia', {
        'id': id,
        'title': title,
        'playing': playing,
        'position': position,
        'duration': duration,
      });

  /// Tells Android whether the video window may float (picture-in-picture) when the app is left.
  Future<void> setPip({required bool ready, required bool playing}) =>
      _methods.invokeMethod<void>('setPip', {'ready': ready, 'playing': playing});

  /// Turns the video into a floating window now.
  /// Direct address of a YouTube video for the in-app player: title, url, duration (seconds).
  Future<Map<String, dynamic>> resolveStream(
    String url, {
    bool legacy = false,
    bool audio = false,
    int height = 720,
  }) async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>(
      'resolveStream',
      {'url': url, 'legacy': legacy, 'audio': audio, 'height': height},
    );
    return {for (final e in (raw ?? const {}).entries) e.key.toString(): e.value};
  }

  /// Sends the app to the background without closing it (keeps the sound playing).
  Future<bool> moveToBack() async => (await _methods.invokeMethod<bool>('moveToBack')) ?? false;

  Future<bool> enterPip() async => (await _methods.invokeMethod<bool>('enterPip')) ?? false;

  /// Picture for a file on the phone (album art, thumbnail or a video frame), or null.
  Future<Uint8List?> mediaThumb(String uri) => _methods.invokeMethod<Uint8List>('mediaThumb', {'uri': uri});

  /// Lets the user pick audio / video files from the phone. Empty when cancelled.
  Future<List<CastItem>> pickMedia() async {
    final raw = await _methods.invokeListMethod<Map<dynamic, dynamic>>('pickMedia');
    return (raw ?? const [])
        .map((m) => CastItem(
              uri: m['uri'] as String? ?? '',
              title: m['title'] as String? ?? 'Media',
              mime: m['mime'] as String? ?? 'video/mp4',
            ))
        .where((i) => i.uri.isNotEmpty)
        .toList();
  }

  Future<CastState> castState() async {
    final raw = await _methods.invokeMapMethod<dynamic, dynamic>('castState');
    return raw == null ? const CastState.idle() : CastState.fromMap(raw);
  }

  /// Deletes the saved file from the device.
  Future<bool> deleteFile(String uri) async =>
      (await _methods.invokeMethod<bool>('deleteFile', {'uri': uri})) ?? false;

  /// For each uri, whether the file can still be opened.
  Future<List<bool>> filesExist(List<String> uris) async {
    final raw = await _methods.invokeListMethod<bool>('filesExist', {'uris': uris});
    return raw ?? List<bool>.filled(uris.length, true);
  }
}
