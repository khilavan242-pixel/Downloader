/// Small formatting helpers (no `intl` dependency needed).
class Fmt {
  Fmt._();

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// `3.4 MB`, `812 KB`. Empty when unknown.
  static String bytes(int? b) {
    if (b == null || b <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i < 2 ? 0 : 1)} ${units[i]}';
  }

  /// `4:22 PM`
  static String time(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// `Today`, `Yesterday`, `Fri, 14 Nov` (with the year when it is not this year).
  static String dayLabel(DateTime d, DateTime now) {
    final day = DateTime(d.year, d.month, d.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    final base = '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
    return d.year == now.year ? base : '$base ${d.year}';
  }
}
