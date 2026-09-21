import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/wellness.dart';
import 'package:sanctuary/services/daily_review.dart';

Goal _sleep([double target = 7]) => Goal.forMetric(
      metric: Metric.sleep, target: target, label: 'sleep 7 hours');
Goal _move([double target = 30]) => Goal.forMetric(
      metric: Metric.movement, target: target, label: 'move 30 minutes');
Goal _water([double target = 2]) => Goal.forMetric(
      metric: Metric.water, target: target, label: 'drink 2 litres');
Goal _habit(String name) => Goal.forMetric(
      metric: Metric.habit(name), target: 1, label: name);

Map<String, double> _map(List<LoggedValue> v) =>
    {for (final x in v) x.metric: x.value};

void main() {
  group('reading a number out of an answer', () {
    test('picks the number next to the metric it belongs to', () {
      final got = _map(GoalReplyParser.parse(
        'slept 7 hours and walked 40 minutes',
        [_sleep(), _move()],
      ));
      expect(got[Metric.sleep], 7);
      expect(got[Metric.movement], 40);
    });

    test('a number in one clause never lands on another metric', () {
      // The whole reason parsing is clause-based. A sentence-wide number hunt
      // would put 7 on movement here.
      final got = _map(GoalReplyParser.parse(
        'slept 7 hours, no walk at all',
        [_sleep(), _move()],
      ));
      expect(got[Metric.sleep], 7);
      expect(got[Metric.movement], 0);
    });

    test('accepts a decimal, and a comma as a decimal point', () {
      expect(
        _map(GoalReplyParser.parse('about 6.5 hours sleep', [_sleep()]))[
            Metric.sleep],
        6.5,
      );
      expect(
        _map(GoalReplyParser.parse('drank 1,5 litres', [_water()]))[
            Metric.water],
        1.5,
      );
    });
  });

  group('negation beats a number', () {
    test("didn't do the 30 minutes records a miss, not thirty", () {
      // The single most damaging misread available: logging the target the user
      // just said they missed would both corrupt the number and award them a
      // streak day they did not earn.
      final got = _map(GoalReplyParser.parse(
        "didn't manage the 30 minutes",
        [_move()],
      ));
      expect(got[Metric.movement], 0);
    });

    test('recognises the ordinary ways of saying no', () {
      for (final reply in [
        'nope',
        'no, skipped it',
        'forgot again',
        'missed it today',
        'nothing',
      ]) {
        expect(_map(GoalReplyParser.parse(reply, [_move()]))[Metric.movement],
            0, reason: reply);
      }
    });
  });

  group('yes, against each kind of goal', () {
    test('a bare yes on a quantified goal records the target', () {
      // No more precise reading is available, and the alternative is throwing
      // the answer away.
      expect(
        _map(GoalReplyParser.parse('yep', [_sleep(7)]))[Metric.sleep],
        7,
      );
    });

    test('a habit records done, never a quantity', () {
      final goal = _habit('meditate');
      expect(_map(GoalReplyParser.parse('yes', [goal]))[goal.metric], 1);
      // A number against a habit is noise — "meditated 2 times" is still done.
      expect(_map(GoalReplyParser.parse('did it 2 times', [goal]))[goal.metric],
          1);
    });

    test('a habit is matched by its own name', () {
      final goal = _habit('meditate');
      final got = _map(GoalReplyParser.parse(
        'walked 20 minutes and meditated',
        [_move(), goal],
      ));
      expect(got[Metric.movement], 20);
      expect(got[goal.metric], 1);
    });
  });

  group('a plan is not a log', () {
    test('a number inside an intention is not recorded', () {
      // Without this the parser reads "I'll walk 30 minutes tomorrow" as thirty
      // minutes walked today.
      expect(
        GoalReplyParser.parse("I'll do the 30 minutes tomorrow", [_move()]),
        isEmpty,
      );
    });

    test('an intention is not a miss either', () {
      // Nothing, not zero — they have not said they failed, and a zero would
      // break a streak on the strength of a plan.
      for (final reply in [
        'going to do it after dinner',
        'want to get back to it',
        'will try later',
      ]) {
        expect(GoalReplyParser.parse(reply, [_move()]), isEmpty, reason: reply);
      }
    });

    test('a miss still beats an intention in the same clause', () {
      // "didn't" has to win, or the plan swallows the admission.
      expect(
        _map(GoalReplyParser.parse("didn't, will do it tomorrow", [_move()]))[
            Metric.movement],
        0,
      );
    });
  });

  group('staying silent rather than guessing', () {
    test('an unanswered goal is absent, not zero', () {
      // Recording a miss the user never claimed breaks a streak they earned.
      final got = _map(GoalReplyParser.parse(
        'slept 8 hours',
        [_sleep(), _move()],
      ));
      expect(got[Metric.sleep], 8);
      expect(got.containsKey(Metric.movement), isFalse);
    });

    test('an answer about something else records nothing', () {
      final got = GoalReplyParser.parse(
        'work was a nightmare today honestly',
        [_sleep(), _move()],
      );
      expect(got, isEmpty);
    });

    test('no goals asked, nothing parsed', () {
      expect(GoalReplyParser.parse('slept 7 hours', const []), isEmpty);
    });
  });

  group('a single goal takes an answer that never names it', () {
    test('a bare number', () {
      expect(_map(GoalReplyParser.parse('7', [_sleep()]))[Metric.sleep], 7);
    });

    test('a bare yes or no', () {
      expect(_map(GoalReplyParser.parse('yeah', [_move(30)]))[Metric.movement],
          30);
      expect(
          _map(GoalReplyParser.parse('not today', [_move()]))[Metric.movement],
          0);
    });

    test('but with two goals asked, an unattributable answer is dropped', () {
      // Guessing which of two metrics "yeah" meant is exactly the kind of
      // invention this parser exists to avoid.
      expect(GoalReplyParser.parse('yeah', [_sleep(), _move()]), isEmpty);
    });
  });

  group('which day the question is about', () {
    DateTime? dayAt(int hour, {int day = 14}) =>
        DailyReview.reviewDay(DateTime(2026, 9, day, hour));

    test('nothing during the day — the day is not over to ask about', () {
      for (final hour in [7, 9, 12, 17, 19]) {
        expect(dayAt(hour), isNull, reason: '$hour:00');
      }
    });

    test('the evening reviews the day in progress', () {
      expect(dayAt(20), DateTime(2026, 9, 14));
      expect(dayAt(23), DateTime(2026, 9, 14));
    });

    test('the small hours review the day that just ended', () {
      // Someone answering at 00:30 is telling you about yesterday. Keying this
      // to the new calendar day would ask about a day minutes old and spend its
      // marker before its real evening arrived.
      expect(dayAt(0, day: 15), DateTime(2026, 9, 14));
      expect(dayAt(6, day: 15), DateTime(2026, 9, 14));
    });

    test('the window closes at the start of the morning', () {
      expect(dayAt(6, day: 15), isNotNull);
      expect(dayAt(7, day: 15), isNull);
    });

    test('rolls back over a month boundary', () {
      // DateTime(y, m, 0) is the last day of the previous month, which is the
      // whole reason this is calendar arithmetic and not a Duration.
      expect(DailyReview.reviewDay(DateTime(2026, 10, 1, 2)),
          DateTime(2026, 9, 30));
      expect(DailyReview.reviewDay(DateTime(2026, 1, 1, 2)),
          DateTime(2025, 12, 31));
      expect(DailyReview.reviewDay(DateTime(2024, 3, 1, 2)),
          DateTime(2024, 2, 29));
    });

    test('asks about at most a sentence worth of goals', () {
      expect(DailyReview.maxGoalsAsked, lessThanOrEqualTo(3));
    });
  });
}
