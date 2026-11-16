import 'package:flutter/material.dart';

import '../state/download_controller.dart';

String _clock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String thumbnailUrl(String id) => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

Widget _thumb(String? id) {
  if (id == null) return const ColoredBox(color: Colors.black);
  return Image.network(
    thumbnailUrl(id),
    fit: BoxFit.cover,
    errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
  );
}

/// Replaces the video picture on the YouTube watch page while a TV is connected,
/// like the YouTube app does: a thumbnail with the TV controls on top.
class TvPlayerPanel extends StatelessWidget {
  const TvPlayerPanel({
    super.key,
    required this.controller,
    required this.videoId,
    required this.onPlayHere,
    required this.onChangeDevice,
  });

  final DownloadController controller;
  final String videoId;

  /// Starts this page's video on the TV (shown when the TV is idle).
  final VoidCallback onPlayHere;
  final VoidCallback onChangeDevice;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.cast;
    final target = c.castTarget;
    final onTv = c.castVideoId == videoId;
    final busy = onTv && (s.status == 'connecting' || s.status == 'loading');
    final playing = onTv && (s.status == 'playing' || s.status == 'paused');
    final stopped = !onTv || !(s.active);

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(opacity: playing || busy ? 0.55 : 0.4, child: _thumb(videoId)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xAA000000), Color(0x00000000), Color(0xCC000000)],
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 8,
            right: 56,
            child: Row(
              children: [
                const Icon(Icons.cast_connected_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    target == null ? 'Not connected' : 'Casting to ${target.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 2,
            top: 0,
            child: PopupMenuButton<String>(
              tooltip: 'TV options',
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
              onSelected: (v) {
                if (v == 'change') onChangeDevice();
                if (v == 'disconnect') c.disconnectCast();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'change', child: Text('Change TV')),
                PopupMenuItem(value: 'disconnect', child: Text('Disconnect from ${target?.name ?? 'TV'}')),
              ],
            ),
          ),
          Center(
            child: busy
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                  )
                : stopped
                    ? FilledButton.icon(
                        onPressed: onPlayHere,
                        icon: const Icon(Icons.tv_rounded),
                        label: Text(s.status == 'error' && onTv ? 'Try again on TV' : 'Play on TV'),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ctl(Icons.skip_previous_rounded, 34, () => c.castControl('previous')),
                          const SizedBox(width: 10),
                          _ctl(
                            s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                            46,
                            () => c.castControl(s.paused ? 'resume' : 'pause'),
                          ),
                          const SizedBox(width: 10),
                          _ctl(Icons.skip_next_rounded, 34, () => c.castControl('next')),
                        ],
                      ),
          ),
          if (playing)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _SeekBar(controller: c),
            ),
        ],
      ),
    );
  }

  Widget _ctl(IconData icon, double size, VoidCallback onTap) => IconButton(
        onPressed: onTap,
        iconSize: size,
        color: Colors.white,
        icon: Icon(icon),
      );
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.controller});

  final DownloadController controller;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.controller.castProgress,
      builder: (context, p, _) {
        final total = p.duration;
        final value = (_drag ?? p.position.toDouble()).clamp(0, total > 0 ? total.toDouble() : 1.0).toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: [
              Text(_clock(value.round()), style: const TextStyle(color: Colors.white, fontSize: 12)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.red,
                    inactiveTrackColor: Colors.white30,
                    thumbColor: Colors.red,
                  ),
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
              ),
              Text(total > 0 ? _clock(total) : '--:--', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

/// The floating "mini player" shown when you leave the watch page while the TV
/// is still playing, like the YouTube app's pop-up.
class TvMiniPlayer extends StatelessWidget {
  const TvMiniPlayer({super.key, required this.controller, required this.onOpen});

  final DownloadController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.cast;
    final id = c.castVideoId;
    final busy = s.status == 'connecting' || s.status == 'loading';
    return Material(
      color: const Color(0xF2212121),
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: _thumb(id)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title ?? 'Playing on TV',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    Text(
                      s.device,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  ),
                )
              else
                IconButton(
                  tooltip: s.paused ? 'Play' : 'Pause',
                  color: Colors.white,
                  icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  onPressed: () => c.castControl(s.paused ? 'resume' : 'pause'),
                ),
              IconButton(
                tooltip: 'Close',
                color: Colors.white,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => c.castControl('stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
