import 'package:flutter_test/flutter_test.dart';
import 'package:tapnab/utils/format_utils.dart';

void main() {
  group('Fmt.bytes', () {
    test('empty when unknown', () {
      expect(Fmt.bytes(null), '');
      expect(Fmt.bytes(0), '');
    });

    test('scales units', () {
      expect(Fmt.bytes(512), '512 B');
      expect(Fmt.bytes(2048), '2 KB');
      expect(Fmt.bytes(3 * 1024 * 1024 + 400 * 1024), '3.4 MB');
    });
  });

  test('Fmt.time uses a 12 hour clock', () {
    expect(Fmt.time(DateTime(2026, 11, 14, 16, 22)), '4:22 PM');
    expect(Fmt.time(DateTime(2026, 1, 1, 0, 5)), '12:05 AM');
    expect(Fmt.time(DateTime(2026, 1, 1, 12, 0)), '12:00 PM');
  });

  test('Fmt.dayLabel', () {
    final now = DateTime(2026, 11, 14, 10);
    expect(Fmt.dayLabel(DateTime(2026, 11, 14, 1), now), 'Today');
    expect(Fmt.dayLabel(DateTime(2026, 11, 13, 23), now), 'Yesterday');
    expect(Fmt.dayLabel(DateTime(2026, 11, 10), now), 'Tue, 10 Nov');
    expect(Fmt.dayLabel(DateTime(2025, 12, 31), now), 'Wed, 31 Dec 2025');
  });
}
