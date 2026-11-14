import 'dart:async';

import 'package:flutter/services.dart';

import '../models/download_task.dart';
import '../models/quality.dart';
import '../models/save_folder.dart';

/// Thin typed wrapper around the Android platform channels.
///
/// Contract with `DownloadChannel.kt`:
///  * MethodChannel `tapnab/downloader`
///      enqueue({id,url,kind,quality,playlist,folderUri?})  -> void
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
  }) {
    return _methods.invokeMethod<void>('enqueue', {
      'id': id,
      'url': url,
      'kind': kind.name,
      'quality': quality.value,
      'playlist': playlist,
      'folderUri': folder?.uri,
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

  Future<String?> consumeSharedText() =>
      _methods.invokeMethod<String>('consumeSharedText');
}
