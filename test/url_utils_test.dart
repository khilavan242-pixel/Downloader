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
}
