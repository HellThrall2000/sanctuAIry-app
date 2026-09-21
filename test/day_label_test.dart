import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/day_key.dart';

void main() {
  // A fixed "now" so the test does not drift into a different answer overnight.
  final now = DateTime(2026, 9, 17, 14, 30);

  group('the two days people name', () {
    test('today, at any hour of it', () {
      for (final hour in [0, 9, 14, 23]) {
        expect(DayLabel.of(DateTime(2026, 9, 17, hour), now: now), 'Today',
            reason: '$hour:00');
      }
    });

    test('yesterday, at any hour of it', () {
      for (final hour in [0, 9, 23]) {
        expect(DayLabel.of(DateTime(2026, 9, 16, hour), now: now), 'Yesterday',
            reason: '$hour:00');
      }
    });

    test('one minute either side of midnight is a different day', () {
      // The boundary is the calendar, not 24 hours of elapsed time.
      expect(DayLabel.of(DateTime(2026, 9, 17, 0, 0), now: now), 'Today');
      expect(DayLabel.of(DateTime(2026, 9, 16, 23, 59), now: now), 'Yesterday');
    });
  });

  group('past that, a date', () {
    test('two days ago is written out, not counted', () {
      // "2 days ago" is where relative labels start costing more to read than
      // they save.
      expect(DayLabel.of(DateTime(2026, 9, 15), now: now), '15 September');
    });

    test('no year while it is the current one', () {
      expect(DayLabel.of(DateTime(2026, 1, 3), now: now), '3 January');
      expect(DayLabel.of(DateTime(2026, 12, 25), now: now), '25 December');
    });

    test('a year when it is not', () {
      expect(DayLabel.of(DateTime(2025, 9, 17), now: now), '17 September 2025');
      expect(DayLabel.of(DateTime(2027, 2, 1), now: now), '1 February 2027');
    });

    test('every month has a name', () {
      // Guards the off-by-one that a 1-indexed month into a 0-indexed list
      // invites, at both ends.
      expect(DayLabel.of(DateTime(2025, 1, 1), now: now), '1 January 2025');
      expect(DayLabel.of(DateTime(2025, 12, 31), now: now), '31 December 2025');
      expect(DayLabel.months, hasLength(12));
    });
  });

  group('boundaries that a Duration would get wrong', () {
    test('yesterday across the start of a month', () {
      final firstOfMonth = DateTime(2026, 10, 1, 9);
      expect(DayLabel.of(DateTime(2026, 9, 30, 9), now: firstOfMonth),
          'Yesterday');
    });

    test('yesterday across the start of a year', () {
      final newYear = DateTime(2026, 1, 1, 9);
      expect(DayLabel.of(DateTime(2025, 12, 31, 9), now: newYear), 'Yesterday');
    });

    test('yesterday across a leap day', () {
      final march = DateTime(2024, 3, 1, 9);
      expect(DayLabel.of(DateTime(2024, 2, 29, 9), now: march), 'Yesterday');
    });

    test('near midnight, where subtracting 24 hours lands on the wrong date',
        () {
      // The failure DayKey.daysAgo documents: a Duration is a fixed number of
      // hours, so at 00:30 minus 24h you land at 00:30 the previous day — right
      // here, but wrong on the day a timezone shifts. This asserts the calendar
      // answer at the hour where the two are easiest to confuse.
      final justAfterMidnight = DateTime(2026, 9, 17, 0, 30);
      expect(DayLabel.of(DateTime(2026, 9, 16, 23, 45), now: justAfterMidnight),
          'Yesterday');
      expect(DayLabel.of(DateTime(2026, 9, 17, 0, 5), now: justAfterMidnight),
          'Today');
    });
  });
}
