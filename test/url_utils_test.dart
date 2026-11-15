import 'package:flutter_test/flutter_test.dart';
import 'package:tapnab/models/quality.dart';
import 'package:tapnab/utils/url_utils.dart';

void main() {
  group('UrlUtils.extractUrls', () {
    test('finds several links and de-duplicates', () {
      const text = 'watch https://youtu.be/abc123, and (https://www.youtube.com/watch?v=xyz).\n'
          'again https://youtu.be/abc123';
      expect(UrlUtils.extractUrls(text), [
        'https://youtu.be/abc123',
        'https://www.youtube.com/watch?v=xyz',
      ]);
    });

    test('returns empty for plain text', () {
      expect(UrlUtils.extractUrls('no links here'), isEmpty);
    });
  });

  test('hasPlaylist detects list parameter and playlist path', () {
    expect(UrlUtils.hasPlaylist('https://www.youtube.com/watch?v=a&list=PL1'), isTrue);
    expect(UrlUtils.hasPlaylist('https://www.youtube.com/playlist?list=PL1'), isTrue);
    expect(UrlUtils.hasPlaylist('https://youtu.be/a'), isFalse);
  });

  test('formatEta', () {
    expect(UrlUtils.formatEta(-1), '');
    expect(UrlUtils.formatEta(42), '42s');
    expect(UrlUtils.formatEta(125), '2m 05s');
    expect(UrlUtils.formatEta(3725), '1h 02m');
  });

  group('QualityOption', () {
    test('audio and video lists are ordered low to high', () {
      final a = QualityOption.audio.map((q) => q.value).toList();
      expect(a, [...a]..sort());
      final v = QualityOption.video.where((q) => !q.isBest).map((q) => q.value).toList();
      expect(v, [...v]..sort());
      expect(QualityOption.video.last.isBest, isTrue);
    });

    test('fromKey round-trips', () {
      for (final q in [...QualityOption.audio, ...QualityOption.video]) {
        expect(QualityOption.fromKey(q.key).key, q.key);
      }
    });
  });

  group('videoId', () {
    test('reads the id from every common link shape', () {
      expect(UrlUtils.videoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(UrlUtils.videoId('https://youtu.be/dQw4w9WgXcQ?si=abc'), 'dQw4w9WgXcQ');
      expect(UrlUtils.videoId('https://m.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(UrlUtils.videoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx'), 'dQw4w9WgXcQ');
    });

    test('is null for playlists, other sites and junk', () {
      expect(UrlUtils.videoId('https://www.youtube.com/playlist?list=PLx'), isNull);
      expect(UrlUtils.videoId('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
      expect(UrlUtils.videoId('https://www.youtube.com/watch?v=short'), isNull);
      expect(UrlUtils.videoId('not a url'), isNull);
    });
  });

  group('page kinds', () {
    test('playlist pages versus videos inside a playlist', () {
      expect(UrlUtils.isPlaylistPage('https://youtube.com/playlist?list=RDCLAK5uy'), isTrue);
      expect(UrlUtils.isPlaylistPage('https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx'), isFalse);
      expect(UrlUtils.isPlaylistPage('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), isFalse);
    });

    test('downloadable pages for the Browse button', () {
      expect(UrlUtils.isDownloadablePage('https://m.youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
      expect(UrlUtils.isDownloadablePage('https://m.youtube.com/playlist?list=PLx'), isTrue);
      expect(UrlUtils.isDownloadablePage('https://m.youtube.com/'), isFalse);
      expect(UrlUtils.isDownloadablePage('https://example.com/watch?v=dQw4w9WgXcQ'), isFalse);
    });
  });
}
