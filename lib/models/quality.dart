/// Output container the user wants.
enum MediaKind {
  mp3('MP3', 'Audio'),
  mp4('MP4', 'Video');

  const MediaKind(this.label, this.subtitle);
  final String label;
  final String subtitle;

  static MediaKind fromName(String name) =>
      MediaKind.values.firstWhere((k) => k.name == name, orElse: () => MediaKind.mp3);
}

/// One selectable quality level. [value] is what the native layer receives:
/// kbps for MP3 (e.g. `128`), max height in pixels for MP4 (e.g. `720`),
/// or `0` meaning "best available".
class QualityOption {
  const QualityOption({
    required this.kind,
    required this.value,
    required this.label,
    required this.hint,
  });

  final MediaKind kind;
  final int value;
  final String label;
  final String hint;

  bool get isBest => value == 0;

  /// Stable key used for persistence.
  String get key => '${kind.name}:$value';

  /// MP3 options, ordered from lowest to highest bitrate.
  static const List<QualityOption> audio = [
    QualityOption(kind: MediaKind.mp3, value: 64, label: '64 kbps', hint: 'Smallest file, voice / podcasts'),
    QualityOption(kind: MediaKind.mp3, value: 96, label: '96 kbps', hint: 'Small file, acceptable music'),
    QualityOption(kind: MediaKind.mp3, value: 128, label: '128 kbps', hint: 'Standard quality'),
    QualityOption(kind: MediaKind.mp3, value: 192, label: '192 kbps', hint: 'Good quality'),
    QualityOption(kind: MediaKind.mp3, value: 256, label: '256 kbps', hint: 'High quality'),
    QualityOption(kind: MediaKind.mp3, value: 320, label: '320 kbps', hint: 'Maximum MP3 quality'),
  ];

  /// MP4 options, ordered from lowest to highest resolution.
  static const List<QualityOption> video = [
    QualityOption(kind: MediaKind.mp4, value: 144, label: '144p', hint: 'Tiny file, lowest quality'),
    QualityOption(kind: MediaKind.mp4, value: 240, label: '240p', hint: 'Very small file'),
    QualityOption(kind: MediaKind.mp4, value: 360, label: '360p', hint: 'Small file, mobile data friendly'),
    QualityOption(kind: MediaKind.mp4, value: 480, label: '480p', hint: 'Standard definition'),
    QualityOption(kind: MediaKind.mp4, value: 720, label: '720p HD', hint: 'High definition'),
    QualityOption(kind: MediaKind.mp4, value: 1080, label: '1080p Full HD', hint: 'Full HD, large file'),
    QualityOption(kind: MediaKind.mp4, value: 1440, label: '1440p 2K', hint: 'Very large file'),
    QualityOption(kind: MediaKind.mp4, value: 2160, label: '2160p 4K', hint: 'Largest file, best detail'),
    QualityOption(kind: MediaKind.mp4, value: 0, label: 'Best available', hint: 'Highest quality the video offers'),
  ];

  static List<QualityOption> forKind(MediaKind kind) =>
      kind == MediaKind.mp3 ? audio : video;

  /// Sensible defaults: 192 kbps audio, 720p video.
  static QualityOption defaultFor(MediaKind kind) =>
      kind == MediaKind.mp3 ? audio[3] : video[4];

  static QualityOption fromKey(String? key) {
    if (key != null) {
      for (final o in [...audio, ...video]) {
        if (o.key == key) return o;
      }
    }
    return defaultFor(MediaKind.mp3);
  }
}
