/// Helpers for pulling downloadable links out of arbitrary text (clipboard,
/// shared text, pasted lists).
class UrlUtils {
  UrlUtils._();

  static final RegExp _urlPattern = RegExp(
    r"https?://[^\s<>\x22']+",
    caseSensitive: false,
  );

  static const Set<String> _youtubeHosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };

  /// Returns every unique http(s) URL found in [text], in order of appearance.
  static List<String> extractUrls(String text) {
    final seen = <String>{};
    final result = <String>[];
    for (final m in _urlPattern.allMatches(text)) {
      var url = m.group(0)!;
      // Strip trailing punctuation that is almost never part of the URL.
      url = url.replaceAll(RegExp(r'[)\]}>.,;!?]+$'), '');
      if (Uri.tryParse(url)?.hasAuthority != true) continue;
      if (seen.add(url)) result.add(url);
    }
    return result;
  }

  static bool isYoutube(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    return host != null && _youtubeHosts.contains(host);
  }

  /// True when the link points at a playlist (or a video inside one).
  static bool hasPlaylist(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.queryParameters.containsKey('list') || uri.path.contains('/playlist');
  }

  static String formatEta(int seconds) {
    if (seconds < 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }
}
