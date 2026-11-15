/// One song or video inside a playlist, as listed before downloading.
class PlaylistEntry {
  const PlaylistEntry({
    required this.url,
    required this.title,
    this.duration = '',
    this.playlist = '',
  });

  final String url;
  final String title;

  /// e.g. `3:45`, empty when unknown.
  final String duration;

  /// Name of the playlist this entry came from.
  final String playlist;

  String get displayTitle => title.trim().isEmpty ? url : title;

  factory PlaylistEntry.fromMap(Map<dynamic, dynamic> m) => PlaylistEntry(
        url: m['url'] as String? ?? '',
        title: m['title'] as String? ?? '',
        duration: m['duration'] as String? ?? '',
        playlist: m['playlist'] as String? ?? '',
      );
}
