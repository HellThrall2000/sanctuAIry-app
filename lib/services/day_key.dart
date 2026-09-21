/// A local calendar day, rendered as a sortable `yyyy-MM-dd` key.
///
/// **Local, deliberately, not UTC.** Everything else in this app stores UTC
/// ISO-8601 timestamps, and for an event that is correct — a message was sent at
/// an instant. A *day* is not an instant. "Did I drink enough water on Tuesday"
/// means the user's Tuesday, and a UTC key splits their evening across two days
/// for anyone west of Greenwich and steals the small hours for anyone east of
/// it. Someone in IST logging water at 23:30 would see it land on tomorrow.
///
/// This was already the rule in `UsageMetrics`, which had the only day-bucketing
/// code in the app and the comment explaining why. It is extracted here so the
/// tracker cannot quietly disagree with the usage ledger about when a day ends.
///
/// Keys sort lexicographically in date order, which is why the parts are
/// zero-padded — SQLite `ORDER BY day DESC` then needs no date parsing at all.
abstract final class DayKey {
  const DayKey._();

  /// The local calendar day [when] falls on.
  static String of(DateTime when) =>
      '${when.year.toString().padLeft(4, '0')}-'
      '${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')}';

  /// Today, locally.
  static String today() => of(DateTime.now());

  /// The day [count] days before [from], counting backwards on the calendar.
  ///
  /// **Not `subtract(Duration(days: count))`.** A `Duration` is a fixed number
  /// of hours, so on the day a timezone shifts for daylight saving, subtracting
  /// 24 hours from midday lands at 11:00 or 13:00 the previous day — usually the
  /// right date, but it lands on the *wrong* date when the clock is near
  /// midnight. `DateTime(y, m, d - count)` asks the calendar instead, and Dart
  /// normalises a negative or overflowing day into the previous month or year.
  static String daysAgo(int count, {DateTime? from}) {
    final now = from ?? DateTime.now();
    return of(DateTime(now.year, now.month, now.day - count));
  }

  /// The last [count] days, **newest first** — `[today, yesterday, …]`.
  ///
  /// Newest first because every consumer here walks backwards: a streak stops at
  /// the first miss, and an adherence window is "the last seven days".
  static List<String> lastDays(int count, {DateTime? from}) => [
        for (var i = 0; i < count; i++) daysAgo(i, from: from),
      ];

  /// Parses a key back to local midnight, or null if it is not a valid key.
  ///
  /// Returns null rather than throwing: these strings come out of SQLite, and a
  /// row written by an older or newer build must never be able to crash a read.
  static DateTime? parse(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    final parsed = DateTime(year, month, day);
    // Rejects 2026-02-31, which DateTime would silently roll into March.
    if (parsed.month != month || parsed.day != day) return null;
    return parsed;
  }
}

/// A local calendar day, written the way a person would say it.
///
/// Separate from [DayKey] because they answer different questions — one makes a
/// sortable key, this makes a label — but it lives in the same file because it
/// depends on the same rule, and the reasoning at the top of [DayKey] about
/// *whose* day it is applies to both. "Yesterday" computed in UTC is wrong for
/// anyone west of Greenwich for part of every evening.
abstract final class DayLabel {
  const DayLabel._();

  static const months = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// "Today", "Yesterday", "17 September", or "17 September 2025".
  ///
  /// Relative for the two days people actually think of by name, absolute after
  /// that — past two days "4 days ago" takes longer to decode than a date. The
  /// year appears only when it is not the current one, because "17 September
  /// 2026" in 2026 is three words where two would do.
  static String of(DateTime day, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final key = DayKey.of(day);
    if (key == DayKey.of(at)) return 'Today';
    if (key == DayKey.daysAgo(1, from: at)) return 'Yesterday';

    final date = '${day.day} ${months[day.month - 1]}';
    return day.year == at.year ? date : '$date ${day.year}';
  }
}
