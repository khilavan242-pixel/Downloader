import 'package:flutter/material.dart';

import '../state/download_controller.dart';
import '../utils/url_utils.dart';
import 'tv_player.dart';

/// The picture for whatever the TV is playing: a YouTube thumbnail, or the
/// album art / video frame of a file from the phone.
class CastArt extends StatelessWidget {
  const CastArt({super.key, required this.controller, required this.uri});

  final DownloadController controller;
  final String? uri;

  @override
  Widget build(BuildContext context) {
    final u = uri;
    if (u == null) return _placeholder();
    final id = UrlUtils.videoId(u);
    if (id != null) {
      return Image.network(
        thumbnailUrl(id),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    return FutureBuilder(
      future: controller.thumbFor(u),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return _placeholder();
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }

  Widget _placeholder() => const ColoredBox(
        color: Color(0xFF2A2A2A),
        child: Center(child: Icon(Icons.music_note_rounded, color: Colors.white54, size: 40)),
      );
}

/// Small draggable window that stays on top of every tab while the TV is
/// playing, like YouTube's mini player. Tap it to open the full player.
class FloatingCast extends StatefulWidget {
  const FloatingCast({super.key, required this.controller, required this.onOpenVideo});

  final DownloadController controller;

  /// Called with a YouTube video id when the window is tapped (show its page).
  final void Function(String id) onOpenVideo;

  @override
  State<FloatingCast> createState() => _FloatingCastState();
}

class _FloatingCastState extends State<FloatingCast> {
  static const double _w = 220;
  static const double _h = 158;

  Offset? _pos; // top-left, null until first layout

  DownloadController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final maxX = (box.maxWidth - _w).clamp(0.0, double.infinity);
        final maxY = (box.maxHeight - _h).clamp(0.0, double.infinity);
        final p = _pos ?? Offset(8, maxY - 100);
        final pos = Offset(p.dx.clamp(8.0, maxX > 8 ? maxX : 8.0), p.dy.clamp(0.0, maxY));
        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              width: _w,
              height: _h,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() => _pos = Offset(pos.dx + d.delta.dx, pos.dy + d.delta.dy)),
                onPanEnd: (_) {
                  // Snap to the nearer side edge.
                  final cur = _pos ?? pos;
                  final left = cur.dx + _w / 2 < box.maxWidth / 2;
                  setState(() => _pos = Offset(left ? 8 : maxX - 8, cur.dy.clamp(0.0, maxY)));
                },
                child: _card(context),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context) {
    final s = c.cast;
    final busy = c.castBusy || s.status == 'connecting' || s.status == 'loading';
    final id = s.uri == null ? null : UrlUtils.videoId(s.uri!);
    return Material(
      color: const Color(0xFF212121),
      elevation: 10,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (id != null) {
            widget.onOpenVideo(id);
          } else {
            showNowPlaying(context, c);
          }
        },
        child: Column(
          children: [
            SizedBox(
              height: 124,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CastArt(controller: c, uri: s.uri),
                  const DecoratedBox(decoration: BoxDecoration(color: Color(0x66000000))),
                  Center(
                    child: busy
                        ? const SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                          )
                        : IconButton(
                            iconSize: 40,
                            color: Colors.white,
                            tooltip: s.paused ? 'Play' : 'Pause',
                            icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                            onPressed: () => c.castControl(s.paused ? 'resume' : 'pause'),
                          ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      iconSize: 20,
                      color: Colors.white,
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => c.castControl('stop'),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: IconButton(
                      iconSize: 20,
                      color: Colors.white,
                      tooltip: 'Open player',
                      icon: const Icon(Icons.open_in_full_rounded),
                      onPressed: () => showNowPlaying(context, c),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    const Icon(Icons.cast_connected_rounded, color: Colors.white70, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.title ?? 'Playing on ${s.device}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full "now playing" sheet: picture, title, seek bar and controls. Works for
/// YouTube videos and for files from the phone.
Future<void> showNowPlaying(BuildContext context, DownloadController c) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _NowPlaying(controller: c),
  );
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.cast;
        final live = s.active;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(aspectRatio: 16 / 9, child: CastArt(controller: c, uri: s.uri)),
                ),
                const SizedBox(height: 14),
                Text(
                  s.title ?? (live ? 'Playing' : 'Nothing playing'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  live
                      ? 'Casting to ${s.device}${s.count > 1 ? '  ·  ${s.index + 1} of ${s.count}' : ''}'
                      : 'Not playing',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                if (live) _Seek(controller: c),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 36,
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: live ? () => c.castControl('previous') : null,
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      iconSize: 40,
                      icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                      onPressed: live ? () => c.castControl(s.paused ? 'resume' : 'pause') : null,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      iconSize: 36,
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: live ? () => c.castNext() : null,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      iconSize: 32,
                      tooltip: 'Stop',
                      icon: const Icon(Icons.stop_rounded),
                      onPressed: live ? () => c.castControl('stop') : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Seek extends StatefulWidget {
  const _Seek({required this.controller});

  final DownloadController controller;

  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _drag;

  static String _clock(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.controller.castProgress,
      builder: (context, p, _) {
        final total = p.duration;
        final value = (_drag ?? p.position.toDouble()).clamp(0, total > 0 ? total.toDouble() : 1.0).toDouble();
        return Row(
          children: [
            Text(_clock(value.round()), style: Theme.of(context).textTheme.labelSmall),
            Expanded(
              child: Slider(
                min: 0,
                max: total > 0 ? total.toDouble() : 1,
                value: value,
                onChanged: total > 0 ? (v) => setState(() => _drag = v) : null,
                onChangeEnd: (v) {
                  widget.controller.castSeek(v.round());
                  setState(() => _drag = null);
                },
              ),
            ),
            Text(total > 0 ? _clock(total) : '--:--', style: Theme.of(context).textTheme.labelSmall),
          ],
        );
      },
    );
  }
}
