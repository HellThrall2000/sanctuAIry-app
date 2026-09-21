import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/day_key.dart';

void main() {
  group('a day key is the local calendar day', () {
    test('formats zero-padded so keys sort in date order', () {
      expect(DayKey.of(DateTime(2026, 1, 5)), '2026-01-05');
      expect(DayKey.of(DateTime(2026, 12, 31)), '2026-12-31');

      // The whole point of padding: string sort == date sort, so SQLite can
      // ORDER BY day DESC without parsing anything.
      final keys = [
        DayKey.of(DateTime(2026, 9, 9)),
        DayKey.of(DateTime(2026, 10, 1)),
        DayKey.of(DateTime(2026, 9, 10)),
      ]..sort();
      expect(keys, ['2026-09-09', '2026-09-10', '2026-10-01']);
    });

    test('late evening stays on today, not tomorrow', () {
      // The bug this class exists to prevent. A UTC key would roll 23:30 in IST
      // into the next day and file the entry under a day the user has not
      // lived yet.
      expect(DayKey.of(DateTime(2026, 9, 10, 23, 30)), '2026-09-10');
      expect(DayKey.of(DateTime(2026, 9, 10, 0, 1)), '2026-09-10');
    });
  });

  group('walking backwards through the calendar', () {
    test('crosses a month boundary', () {
      final from = DateTime(2026, 3, 2);
      expect(DayKey.daysAgo(1, from: from), '2026-03-01');
      expect(DayKey.daysAgo(2, from: from), '2026-02-28');
    });

    test('crosses a leap day', () {
      expect(DayKey.daysAgo(1, from: DateTime(2028, 3, 1)), '2028-02-29');
    });

    test('crosses a year boundary', () {
      expect(DayKey.daysAgo(2, from: DateTime(2027, 1, 1)), '2026-12-30');
    });

    test('is calendar arithmetic, not 24-hour arithmetic', () {
      // `subtract(Duration(days: 1))` from just after midnight lands on the
      // previous day at 00:30 — usually right, but an hour of DST shift moves
      // it to 23:30 two days back. Asking the calendar cannot do that.
      final justAfterMidnight = DateTime(2026, 10, 25, 0, 30);
      expect(DayKey.daysAgo(1, from: justAfterMidnight), '2026-10-24');
    });

    test('lastDays is newest first and contiguous', () {
      final days = DayKey.lastDays(4, from: DateTime(2026, 9, 10));
      expect(days, ['2026-09-10', '2026-09-09', '2026-09-08', '2026-09-07']);
    });

    test('lastDays(0) is empty rather than throwing', () {
      expect(DayKey.lastDays(0, from: DateTime(2026, 9, 10)), isEmpty);
    });
  });

  group('parsing back', () {
    test('round-trips', () {
      final day = DateTime(2026, 9, 10);
      expect(DayKey.parse(DayKey.of(day)), day);
    });

    test('returns null rather than throwing on junk', () {
      // These strings come out of SQLite. A row written by an older or newer
      // build must never be able to crash a read.
      for (final junk in ['', 'today', '2026-09', '2026-09-10-11', 'x-y-z']) {
        expect(DayKey.parse(junk), isNull, reason: junk);
      }
    });

    test('rejects a date that does not exist', () {
      // DateTime would silently roll 31 Feb into March; a key that parses to a
      // different day than it names is worse than one that fails.
      expect(DayKey.parse('2026-02-31'), isNull);
      expect(DayKey.parse('2026-13-01'), isNull);
      expect(DayKey.parse('2026-00-10'), isNull);
    });
  });
}
