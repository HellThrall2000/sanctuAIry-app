import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/plan.dart';
import 'package:sanctuary/models/wellness.dart';
import 'package:sanctuary/services/tracker_commands.dart';

TrackerCommand? one(String text, {List<Goal> existing = const []}) {
  final found = TrackerCommandParser.parse(text, existing: existing);
  return found.isEmpty ? null : found.first;
}

Goal habit(String name,
        {double target = 1, String unit = Unit.times, Set<int> days = const {}}) =>
    Goal.forMetric(
      metric: Metric.habit(name),
      target: target,
      unit: unit,
      weekdays: days,
      label: target > 1 ? '$name ${Unit.render(target, unit)}' : name,
    );

void main() {
  group('editing something already tracked', () {
    final meditation =
        habit('meditation', target: 20, unit: Unit.minutes, days: {1, 2, 3, 4, 5});

    test('the phrasing that used to do nothing at all', () {
      // The reported bug: this message changed nothing, because the parser had
      // no edit verbs — only "track" and friends.
      final c = one('change the meditation to 15 mins per day',
          existing: [meditation])!;
      expect(c.action, TrackerAction.editHabit);
      expect(c.goal!.target, 15);
      expect(c.goal!.unit, Unit.minutes);
    });

    test('the other ways of saying it', () {
      for (final text in [
        'change meditation to 15 minutes',
        'update meditation to 15 minutes',
        'make meditation 15 minutes',
        'set meditation to 15 minutes',
        'reduce meditation to 15 minutes',
      ]) {
        final c = one(text, existing: [meditation]);
        expect(c?.action, TrackerAction.editHabit, reason: text);
        expect(c?.goal?.target, 15, reason: text);
      }
    });

    test('an edit keeps everything that was not mentioned', () {
      // The silent-destruction case: changing the amount must not wipe the
      // schedule, and changing the schedule must not reset the amount.
      final amount = one('change meditation to 15 minutes',
          existing: [meditation])!;
      expect(amount.goal!.weekdays, {1, 2, 3, 4, 5});

      final days = one('move meditation to weekends', existing: [meditation])!;
      expect(days.goal!.target, 20);
      expect(days.goal!.unit, Unit.minutes);
      expect(days.goal!.weekdays, {6, 7});
    });

    test('the label is rewritten to match the new amount', () {
      // Or the tracker would show "meditation 20 minutes" with a target of 15.
      expect(one('change meditation to 15 minutes', existing: [meditation])!
          .goal!.label, 'meditation 15 minutes');
    });

    test('it edits in place rather than creating a second goal', () {
      final c = one('track meditation 45 minutes', existing: [meditation])!;
      expect(c.action, TrackerAction.editHabit);
      expect(c.goal!.metric, meditation.metric);
    });

    test('asking for what is already true changes nothing', () {
      expect(one('change meditation to 20 minutes', existing: [meditation]),
          isNull);
    });

    test('the confirmation says what actually changed', () {
      expect(
        one('change meditation to 15 minutes', existing: [meditation])!
            .confirmation,
        'changed meditation to now 15 minutes',
      );
    });
  });

  group('hours and minutes together', () {
    test('a combined duration lands on one number of minutes', () {
      for (final text in [
        'track guitar 1 hour 30 minutes',
        'track guitar 1h 30m',
        'track guitar 1 hour and 30 minutes',
      ]) {
        final c = one(text);
        expect(c?.goal?.target, 90, reason: text);
        expect(c?.goal?.unit, Unit.minutes, reason: text);
      }
    });

    test('and reads back the way it was said', () {
      expect(Unit.render(90, Unit.minutes), '1 hour 30 minutes');
      expect(Unit.render(120, Unit.minutes), '2 hours');
      expect(Unit.render(45, Unit.minutes), '45 minutes');
      expect(Unit.render(60, Unit.minutes), '1 hour');
    });

    test('a fraction of an hour becomes minutes, not an unsayable decimal', () {
      final c = one('track reading 2.5 hours')!;
      expect(c.goal!.target, 150);
      expect(c.goal!.unit, Unit.minutes);
      expect(c.goal!.label, 'reading 2 hours 30 minutes');
    });

    test('a whole number of hours stays in hours', () {
      final c = one('track sleep 7 hours')!;
      expect(c.goal!.target, 7);
      expect(c.goal!.unit, Unit.hours);
    });
  });

  group('no goal type is written down anywhere', () {
    test('a habit nobody anticipated works the same as a built-in', () {
      // The point of the rewrite: no lexicon of known activities.
      for (final (text, name, target, unit) in [
        ('track duolingo 3 sessions', 'duolingo', 3.0, Unit.times),
        ('track guitar 45 minutes', 'guitar', 45.0, Unit.minutes),
        ('track kombucha 2 glasses', 'kombucha', 2.0, Unit.glasses),
        ('track physio 12 pages', 'physio', 12.0, Unit.pages),
      ]) {
        final c = one(text);
        expect(c?.goal?.metric, Metric.habit(name), reason: text);
        expect(c?.goal?.target, target, reason: text);
        expect(c?.goal?.unit, unit, reason: text);
      }
    });

    test('built-ins are matched on their published labels, not synonyms', () {
      expect(one('track sleep 7 hours')!.goal!.metric, Metric.sleep);
      expect(one('track water 2 litres')!.goal!.metric, Metric.water);
      // Anything else is simply a habit — no hidden mapping claims it.
      expect(one('track hydration 2 litres')!.goal!.metric,
          Metric.habit('hydration'));
    });

    test('an existing goal is found by any of the names it goes by', () {
      final gym = habit('gym', target: 45, unit: Unit.minutes);
      for (final text in [
        'change gym to 30 minutes',
        'change gym 45 minutes to 30 minutes',
      ]) {
        expect(one(text, existing: [gym])?.action, TrackerAction.editHabit,
            reason: text);
      }
    });
  });

  group('a name is matched by its stem, not word-for-word', () {
    final meditation = habit('meditation', target: 20, unit: Unit.minutes);

    test('an inflection of the habit name still finds it', () {
      // Set up as "meditation", reported as "meditated". Whole-word matching
      // missed every ending, so a custom habit could be created by name and
      // then never recognised again.
      expect(one('change meditated to 15 minutes', existing: [meditation])
          ?.action, TrackerAction.editHabit);
    });

    test('but a different habit with a shared start is not stolen', () {
      final read = habit('read', target: 20, unit: Unit.pages);
      // Whole-word first, stem second: "ready" must not answer for "read".
      expect(read.isMentionedIn('i feel ready'), isFalse);
      expect(read.isMentionedIn('i read today'), isTrue);
    });

    test('the stem rule is generic, not a list', () {
      for (final (name, spoken) in [
        ('meditation', 'meditated'),
        ('journaling', 'journalled'),
        ('stretching', 'stretched'),
        ('swimming', 'swimming'),
      ]) {
        expect(habit(name).isMentionedIn('i $spoken for a while'), isTrue,
            reason: '$name / $spoken');
      }
    });
  });

  group('a unit nobody shipped', () {
    test('any word after a number is taken as the unit', () {
      for (final (text, name, target, unit) in [
        ('track pushups 40 reps', 'pushups', 40.0, 'reps'),
        ('track reading 3 chapters', 'reading', 3.0, 'chapters'),
        ('track swimming 12 laps', 'swimming', 12.0, 'laps'),
      ]) {
        final c = one(text);
        expect(c?.goal?.metric, Metric.habit(name), reason: text);
        expect(c?.goal?.target, target, reason: text);
        expect(c?.goal?.unit, unit, reason: text);
      }
    });

    test('and it reads back as English on the card and in the prompt', () {
      expect(one('track pushups 40 reps')!.goal!.label, 'pushups 40 reps');
      expect(one('track pushups 1 rep')!.goal!.label, 'pushups 1 rep');
    });

    test('a known spelling still wins over the fallback', () {
      // "mins" must not become a unit called "mins".
      expect(one('track meditation 15 mins')!.goal!.unit, Unit.minutes);
      expect(one('track sleep 7 hours')!.goal!.unit, Unit.hours);
    });

    test('a word that follows a number without being a unit is refused', () {
      // "3 times a week" — "a" is not a unit, and neither is a weekday.
      expect(Unit.parseAmount('3 a week')?.$2, isNot('a'));
      expect(Unit.parseAmount('5 monday'), isNull);
      expect(Unit.parseAmount('2 days'), isNull);
    });

    test('a number with no word after it is not an amount', () {
      // Guards habit names that contain a figure, like "couch to 5k".
      expect(Unit.parseAmount('couch to 5k'), isNull);
    });
  });

  group('adding and dropping', () {
    test('adding still works with no amount', () {
      final c = one('add a habit flossing')!;
      expect(c.action, TrackerAction.addHabit);
      expect(c.goal!.isBinary, isTrue);
    });

    test('days are read when given', () {
      expect(one('track gym 45 minutes on Mondays and Thursdays')!.goal!.weekdays,
          {DateTime.monday, DateTime.thursday});
      expect(one('track stretching on weekdays')!.goal!.weekdays, {1, 2, 3, 4, 5});
    });

    test('dropping names the goal it found', () {
      final yoga = habit('yoga', target: 30, unit: Unit.minutes);
      final c = one('stop tracking yoga', existing: [yoga])!;
      expect(c.action, TrackerAction.dropHabit);
      expect(c.goal!.metric, yoga.metric);
      expect(c.confirmation, contains('yoga 30 minutes'));
    });

    test('the removal phrasings', () {
      for (final text in [
        'remove the gym habit',
        'delete my flossing habit',
        'drop the habit yoga',
        'cancel the reading goal',
      ]) {
        expect(one(text)?.action, TrackerAction.dropHabit, reason: text);
      }
    });
  });

  group('tasks', () {
    test('remind me to X becomes a task', () {
      expect(one('remind me to call the dentist')!.taskText, 'call the dentist');
    });

    test('a list is one task, not three', () {
      expect(one('remind me to call mum, dad and the dentist')!.taskText,
          'call mum, dad and the dentist');
    });

    test('urgency is read but not invented', () {
      expect(one('add a task submit the form asap')!.priority, TodoPriority.high);
      expect(one('add a task water the plants')!.priority, TodoPriority.normal);
    });

    test('ticking one off', () {
      final c = one('mark the dentist as done')!;
      expect(c.action, TrackerAction.completeTask);
      expect(c.taskText, 'dentist');
    });
  });

  group('two instructions in one message', () {
    test('are both read', () {
      final found = TrackerCommandParser.parse(
          'track meditation 15 minutes. also remind me to buy milk');
      expect(found, hasLength(2));
      expect(found[0].action, TrackerAction.addHabit);
      expect(found[1].action, TrackerAction.addTask);
    });
  });

  group('what it refuses to do', () {
    test('ordinary conversation creates nothing', () {
      for (final text in [
        'I had a really long day today',
        'work was a nightmare honestly',
        'I feel like everything is piling up',
        'my sister called last week',
      ]) {
        expect(TrackerCommandParser.parse(text), isEmpty, reason: text);
      }
    });

    test('a report of what happened is not an instruction', () {
      // This is GoalReplyParser's job. Creating or editing a habit here would
      // mean any mention of an activity silently became a commitment.
      for (final text in [
        'I meditated for twenty minutes',
        'slept 6.5 hours but skipped the water',
        'went to the gym today',
      ]) {
        expect(TrackerCommandParser.parse(text), isEmpty, reason: text);
      }
    });

    test('a sentence is not a habit name', () {
      expect(
        TrackerCommandParser.parse(
            'track how I am going to be better about going to bed earlier'),
        isEmpty,
      );
    });

    test('a verb with nothing after it creates nothing', () {
      expect(TrackerCommandParser.parse('track'), isEmpty);
      expect(TrackerCommandParser.parse('add a habit'), isEmpty);
      expect(TrackerCommandParser.parse('remind me to'), isEmpty);
    });
  });
}
