import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/event_extractor.dart';

// A fixed Wednesday, so weekday maths is deterministic.
final _now = DateTime(2026, 8, 5, 10, 0);

List<String> texts(String input) =>
    EventExtractor.extract(input, now: _now).map((e) => e.text).toList();

void main() {
  group('finds what is coming up', () {
    test('"I have an X tomorrow"', () {
      expect(texts('i have an interview tomorrow'), contains('interview'));
    });

    test('"my X is on Friday"', () {
      expect(texts('my exam is on friday'), contains('exam'));
    });

    test('"I am seeing X next week"', () {
      expect(
        texts('i am seeing the consultant next week').first,
        contains('consultant'),
      );
    });

    test('captures the time expression verbatim', () {
      final e = EventExtractor.extract('i have a scan tomorrow', now: _now);
      expect(e.single.rawWhen, 'tomorrow');
    });

    test('keeps the sentence as evidence', () {
      final e = EventExtractor.extract(
        'i have a job interview tomorrow and i am terrified',
        now: _now,
      );
      expect(e.single.evidence, contains('terrified'));
    });
  });

  group('resolution', () {
    test('tomorrow resolves to the end of the next day', () {
      final e = EventExtractor.extract('i have a scan tomorrow', now: _now);
      expect(e.single.dueAt!.day, 6);
      // End of day, so an event is only "passed" once its whole day is over.
      expect(e.single.dueAt!.hour, 23);
    });

    test('a weekday resolves forwards, never backwards', () {
      // _now is a Wednesday; "on monday" must be the following week.
      final e = EventExtractor.extract('my review is on monday', now: _now);
      expect(e.single.dueAt!.isAfter(_now), isTrue);
      expect(e.single.dueAt!.weekday, DateTime.monday);
    });

    test('the same weekday as today means next week', () {
      final e = EventExtractor.extract('i have a call on wednesday', now: _now);
      expect(e.single.dueAt!.difference(_now).inDays, greaterThanOrEqualTo(6));
    });

    test('"in 3 days" resolves numerically', () {
      final e = EventExtractor.extract('i have a scan in 3 days', now: _now);
      expect(e.single.dueAt!.day, 8);
    });

    test('hasPassed is false before the day is over', () {
      final e = EventExtractor.extract('i have a scan tomorrow', now: _now);
      expect(e.single.hasPassed(_now), isFalse);
      expect(e.single.hasPassed(_now.add(const Duration(days: 2))), isTrue);
    });
  });

  group('silence — the expensive failure is a false positive', () {
    test('no time expression means no event', () {
      expect(texts('i have an interview'), isEmpty);
      expect(texts('i hate job interviews'), isEmpty);
    });

    test('a time expression with no event frame finds nothing', () {
      for (final line in [
        'tomorrow is going to be awful',
        'i felt terrible yesterday',
        'see you on friday',
        'next week will be hard',
      ]) {
        expect(texts(line), isEmpty, reason: 'invented an event from "$line"');
      }
    });

    test('ordinary conversation finds nothing', () {
      for (final line in [
        'i am sad',
        'hello',
        'i had a hard day',
        'my mum called me',
      ]) {
        expect(texts(line), isEmpty, reason: line);
      }
    });

    test('does not swallow the time expression into the event name', () {
      final names = texts('i have an interview tomorrow');
      expect(names.single, 'interview');
      expect(names.single, isNot(contains('tomorrow')));
    });

    test('the same event is not recorded twice from one message', () {
      final e = EventExtractor.extract(
        'i have an interview tomorrow, my interview is tomorrow',
        now: _now,
      );
      expect(e.map((x) => x.text).toSet().length, e.length);
    });

    test('the same event mentioned twice keeps one identity', () {
      // Stable across mentions, so re-raising it updates the row rather than
      // creating a second one the companion would ask about again.
      final first = EventExtractor.extract(
        'i have an interview tomorrow',
        now: _now,
      ).single;
      final later = EventExtractor.extract(
        'my interview is tomorrow and i am dreading it',
        now: _now.add(const Duration(hours: 3)),
      ).single;
      expect(first.id, later.id);
    });

    test('different days are different events', () {
      final a = EventExtractor.extract('i have a scan tomorrow', now: _now)
          .single;
      final b = EventExtractor.extract(
        'i have a scan next week',
        now: _now,
      ).single;
      expect(a.id, isNot(b.id));
    });
  });
}
