import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/wellness.dart';
import 'package:sanctuary/services/wellness_log.dart';

/// Values are **newest first**, matching `WellnessLog.history` — index 0 is
/// today. `null` means the day was never logged.
Goal _daily(double target) => Goal.forMetric(
      metric: Metric.sleep,
      target: target,
      label: 'sleep ${target.round()} hours',
    );

Goal _weekly(double timesPerWeek) => Goal.forMetric(
      metric: Metric.movement,
      target: timesPerWeek,
      label: 'move ${timesPerWeek.round()} times a week',
      cadence: GoalCadence.weekly,
    );

void main() {
  group('streaks', () {
    test('counts consecutive days the target was met', () {
      expect(WellnessLog.streakFrom([8, 7.5, 7, 6, 8], _daily(7)), 3);
    });

    test('an unlogged today does not break the streak', () {
      // The humane rule, and the one users notice. At 9am nobody has slept
      // seven hours *today*; resetting on the clock rollover punishes them for
      // the date rather than the behaviour.
      expect(WellnessLog.streakFrom([null, 8, 8, 8], _daily(7)), 3);
    });

    test('but an unlogged yesterday does', () {
      expect(WellnessLog.streakFrom([null, null, 8, 8], _daily(7)), 0);
    });

    test('a logged day that missed the target breaks it', () {
      // Distinct from a gap: they showed up and fell short. Still a break.
      expect(WellnessLog.streakFrom([8, 5, 8, 8], _daily(7)), 1);
    });

    test('meeting the target exactly counts — a goal is a floor', () {
      expect(WellnessLog.streakFrom([7, 7, 7], _daily(7)), 3);
    });

    test('is zero on an empty history', () {
      expect(WellnessLog.streakFrom([], _daily(7)), 0);
      expect(WellnessLog.streakFrom([null, null], _daily(7)), 0);
    });

    test('a weekly goal has no streak', () {
      // "Three times a week" is not a run of days. Scoring it as one would
      // report a streak of 1 forever, which is worse than reporting nothing.
      expect(WellnessLog.streakFrom([1, 1, 1, 1], _weekly(3)), 0);
    });
  });

  group('a habit that only runs on some days', () {
    // Thursday 17 September 2026, so index 0 is a Thursday and index 1 a
    // Wednesday. Pinned rather than relative, or the test would mean something
    // different depending on the day it ran.
    final thursday = DateTime(2026, 9, 17, 12);

    Goal onDays(Set<int> days, {double target = 1}) => Goal.forMetric(
          metric: Metric.habit('gym'),
          target: target,
          unit: Unit.times,
          weekdays: days,
          label: 'gym',
        );

    test('days off do not break the streak', () {
      // Tue + Thu only. The four days between them are not misses, so the run
      // reaches back through them to the previous Tuesday.
      final goal = onDays({DateTime.tuesday, DateTime.thursday});
      //                   Thu  Wed   Tue  Mon   Sun   Sat   Fri  Thu
      final history = <double?>[1, null, 1, null, null, null, null, 1];
      expect(WellnessLog.streakFrom(history, goal, from: thursday), 3);
    });

    test('and without the rule the same history reads as a streak of one', () {
      // What this looked like before: an every-day goal breaks on Wednesday.
      final everyDay = onDays(const {});
      final history = <double?>[1, null, 1, null, null, null, null, 1];
      expect(WellnessLog.streakFrom(history, everyDay, from: thursday), 1);
    });

    test('a missed day that the habit does run on still breaks it', () {
      // The rule must not become a way of never failing.
      final goal = onDays({DateTime.tuesday, DateTime.thursday});
      //                  Thu  Wed   Tue    Mon
      final history = <double?>[1, null, null, null];
      expect(WellnessLog.streakFrom(history, goal, from: thursday), 1);
    });

    test('adherence counts only the days it was asked for', () {
      // Two applicable days in the window, both met. Scoring it over all seven
      // would cap a perfectly kept Tue/Thu habit at two sevenths.
      final goal = onDays({DateTime.tuesday, DateTime.thursday});
      final week = <double?>[1, null, 1, null, null, null, null];
      expect(WellnessLog.adherenceFrom(week, goal, from: thursday), 1.0);
    });

    test('a window with no applicable day is not a failure', () {
      // Nothing was asked of them, so nothing was missed. Zero would read as
      // total failure and would put the goal top of the "slipping" list.
      final saturdayOnly = onDays({DateTime.saturday});
      final midweek = <double?>[null, null, null];
      expect(WellnessLog.adherenceFrom(midweek, saturdayOnly, from: thursday),
          1.0);
    });

    test('an unscheduled goal still applies every day', () {
      final goal = onDays(const {});
      expect(goal.isEveryDay, isTrue);
      expect(goal.appliesOn(thursday), isTrue);
      expect(goal.appliesOn(DateTime(2026, 9, 20)), isTrue);
    });
  });

  group('adherence', () {
    test('daily scores met days over the whole window', () {
      // Five of seven, including the two never-logged days as misses — the
      // point of a daily goal is the day, so a gap is a miss.
      final week = <double?>[8, 8, null, 8, 8, null, 8];
      expect(WellnessLog.adherenceFrom(week, _daily(7)), closeTo(5 / 7, 1e-9));
    });

    test('is 1.0 when every day is met and 0.0 when none are', () {
      expect(WellnessLog.adherenceFrom([8, 8, 8], _daily(7)), 1.0);
      expect(WellnessLog.adherenceFrom([5, 5, 5], _daily(7)), 0.0);
    });

    test('weekly counts days logged against the target, and caps at 1.0', () {
      // Moving three times satisfies "three times a week"; moving seven does
      // not make you 233% adherent.
      final three = <double?>[1, null, 1, null, 1, null, null];
      expect(WellnessLog.adherenceFrom(three, _weekly(3)), 1.0);

      final two = <double?>[1, null, 1, null, null, null, null];
      expect(WellnessLog.adherenceFrom(two, _weekly(3)), closeTo(2 / 3, 1e-9));
    });

    test('weekly treats a zero value as not done', () {
      // Booleans are stored as 0.0 / 1.0 in the same REAL column, so an
      // explicit "no" must not count as a day logged toward the target.
      final zeros = <double?>[0, 0, 0, 0, 0, 0, 0];
      expect(WellnessLog.adherenceFrom(zeros, _weekly(3)), 0.0);
    });

    test('a weekly goal with a nonsense target scores zero, not infinity', () {
      expect(WellnessLog.adherenceFrom([1, 1], _weekly(0)), 0.0);
    });

    test('is zero on an empty history rather than dividing by zero', () {
      expect(WellnessLog.adherenceFrom([], _daily(7)), 0.0);
    });
  });

  group('the thresholds that decide whether to say anything', () {
    test('slipping is below half, so half is not slipping', () {
      // Guards the boundary the digest will read: "movement is the one
      // slipping" must not fire on a week someone kept half the time.
      final half = <double?>[8, 5, 8, 5, 8, 5];
      final score = WellnessLog.adherenceFrom(half, _daily(7));
      expect(score, 0.5);
      expect(score < WellnessLog.slippingBelow, isFalse);
    });

    test('a run below minStreakToMention is not a streak worth mentioning', () {
      expect(WellnessLog.streakFrom([8, 8, 5], _daily(7)),
          lessThan(WellnessLog.minStreakToMention));
    });
  });

  group('goals are slot-keyed so they self-correct', () {
    test('two goals for one metric share an id', () {
      final first = Goal.forMetric(
          metric: Metric.sleep, target: 7, label: 'sleep 7 hours');
      final revised = Goal.forMetric(
          metric: Metric.sleep, target: 8, label: 'sleep 8 hours');
      expect(first.id, revised.id);
      expect(first.id, 'goal:sleep');
    });

    test('a habit goal cannot collide with a built-in metric', () {
      expect(Metric.habit('Meditate'), 'habit:meditate');
      expect(Goal.idFor(Metric.habit('meditate')), 'goal:habit:meditate');
    });

    test('archiving preserves the goal rather than deleting it', () {
      final goal = _daily(7);
      expect(goal.isActive, isTrue);
      final done = goal.archived(at: DateTime(2026, 9, 10));
      expect(done.isActive, isFalse);
      expect(done.target, goal.target);
      expect(done.createdAt, goal.createdAt);
    });

    test('survives a round trip through the database map', () {
      final goal = _weekly(3);
      final back = Goal.fromMap(goal.toMap());
      expect(back.id, goal.id);
      expect(back.metric, goal.metric);
      expect(back.target, goal.target);
      expect(back.cadence, GoalCadence.weekly);
      expect(back.label, goal.label);
    });

    test('an unknown cadence from an older row falls back to daily', () {
      final map = _daily(7).toMap()..['cadence'] = 'fortnightly';
      expect(Goal.fromMap(map).cadence, GoalCadence.daily);
    });
  });

  group('a metric nobody shipped', () {
    test('a unit the user invented renders and pluralises', () {
      // The unit list stopped being a limit. Nothing in the app knows what a
      // rep is, and it still reads like English on the card and in the prompt.
      expect(Unit.render(12, 'rep'), '12 reps');
      expect(Unit.render(1, 'rep'), '1 rep');
      expect(Unit.render(3, 'chapters'), '3 chapters');
    });

    test('a custom goal carries its own unit through the label', () {
      // This label is what the prompt block quotes, so the companion sees the
      // user's own words for a metric the code has never heard of.
      final goal = Goal.forMetric(
        metric: Metric.habit('pushups'),
        target: 40,
        unit: 'rep',
        label: 'pushups ${Unit.render(40, 'rep')}',
      );
      expect(goal.label, 'pushups 40 reps');
      expect(goal.renderValue(25), '25 reps');
      expect(goal.isBinary, isFalse);
    });

    test('mood is still a metric but is never offered as a goal', () {
      // Read from how someone writes, not aimed at: "feel 3 out of 5" turns a
      // bad day into a failed day.
      expect(Metric.builtIns, contains(Metric.mood));
      expect(Metric.trackable, isNot(contains(Metric.mood)));
      expect(Metric.trackable,
          containsAll([Metric.sleep, Metric.water, Metric.movement]));
    });
  });

  group('the face on a goal', () {
    test('the app ships one for its own metrics only', () {
      expect(Metric.defaultEmojiFor(Metric.sleep), isNotNull);
      // A habit is whatever the user invented; guessing a picture for it is
      // the lookup table this deliberately does not have.
      expect(Metric.defaultEmojiFor(Metric.habit('duolingo')), isNull);
    });

    test('a chosen one survives a round trip', () {
      final goal = Goal.forMetric(
        metric: Metric.habit('guitar'),
        target: 30,
        unit: Unit.minutes,
        emoji: '🎸',
        label: 'guitar',
      );
      expect(Goal.fromMap(goal.toMap()).emoji, '🎸');
    });

    test('an older row with no emoji still reads', () {
      final map = Goal.forMetric(
              metric: Metric.habit('reading'), target: 1, label: 'reading')
          .toMap()
        ..remove('emoji');
      expect(Goal.fromMap(map).emoji, isNull);
    });
  });

  group('rendering values as English, not as a data table', () {
    test('drops a trailing .0 so a whole number reads like speech', () {
      expect(Metric.render(Metric.sleep, 7), '7 hours');
      expect(Metric.render(Metric.sleep, 6.5), '6.5 hours');
    });

    test('singular and plural', () {
      expect(Metric.render(Metric.water, 1), '1 litre');
      expect(Metric.render(Metric.water, 2), '2 litres');
    });

    test('a habit with no amount still reads as done or not done', () {
      // A bare metric cannot know this any more — "meditate" might be counted
      // in minutes — so the question is asked of the goal, which knows its
      // unit. Once a day, counted in occurrences, is the old tick.
      final tick = Goal.forMetric(
          metric: Metric.habit('meditate'), target: 1, label: 'meditate');
      expect(tick.isBinary, isTrue);
      expect(tick.renderValue(1), 'done');
      expect(tick.renderValue(0), 'not done');
    });

    test('but a habit with an amount reads in its own unit', () {
      // The whole point of the change: thirty minutes of meditation and two
      // minutes of it used to be the same row.
      final measured = Goal.forMetric(
        metric: Metric.habit('meditate'),
        target: 30,
        unit: Unit.minutes,
        label: 'meditate 30 minutes',
      );
      expect(measured.isBinary, isFalse);
      expect(measured.renderValue(20), '20 minutes');
      expect(measured.targetLabel, '30 minutes');
    });

    test('units render singular and plural, and trim a whole number', () {
      expect(Unit.render(1, Unit.hours), '1 hour');
      expect(Unit.render(7, Unit.hours), '7 hours');
      expect(Unit.render(6.5, Unit.hours), '6.5 hours');
      expect(Unit.render(1, Unit.times), '1 time');
      expect(Unit.render(3, Unit.glasses), '3 glasses');
      expect(Unit.render(5, Unit.kilometres), '5 km');
    });

    test('units are parsed from the abbreviations people type', () {
      expect(Unit.parse('mins'), Unit.minutes);
      expect(Unit.parse('minute'), Unit.minutes);
      expect(Unit.parse('hrs'), Unit.hours);
      expect(Unit.parse('L'), Unit.litres);
      expect(Unit.parse('sessions'), Unit.times);
      expect(Unit.parse('bananas'), isNull);
    });

    test('mood is spelled out rather than left as a bare number', () {
      expect(Metric.render(Metric.mood, 4), '4 out of 5');
    });
  });
}
