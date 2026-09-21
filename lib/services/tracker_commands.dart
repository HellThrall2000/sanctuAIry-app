import 'package:flutter/foundation.dart';

import '../models/plan.dart';
import '../models/weekdays.dart';
import '../models/wellness.dart';

/// What the user asked the tracker to do, read out of an ordinary message.
enum TrackerAction {
  /// Start tracking something new.
  addHabit,

  /// Change something already tracked — its amount, its unit, or its days.
  editHabit,

  /// Stop tracking it.
  dropHabit,

  /// Put something on the to-do list.
  addTask,

  /// Tick something off it.
  completeTask,
}

/// One change to make, and the words to confirm it with.
@immutable
class TrackerCommand {
  final TrackerAction action;

  /// The goal to write, complete. For an edit this is the *existing* goal with
  /// the requested changes applied, so the caller stores it without needing to
  /// know which fields were mentioned.
  final Goal? goal;

  final String? taskText;
  final TodoPriority priority;

  /// What the companion should say it did, in the user's own terms.
  final String confirmation;

  const TrackerCommand({
    required this.action,
    required this.confirmation,
    this.goal,
    this.taskText,
    this.priority = TodoPriority.normal,
  });

  @override
  String toString() => '$action: $confirmation';
}

/// Turns "change meditation to 15 minutes" into a [TrackerCommand].
///
/// **Lexical, not generated.** Asking the model to emit structured changes
/// costs a second inference pass — 15 to 30 seconds on this device — and a 2B
/// model gets it wrong often enough to matter when the output is a write to the
/// user's own record. Same reasoning as `GoalReplyParser` and `FactExtractor`,
/// and it holds harder here: a misparse there logs a wrong number, a misparse
/// here silently invents or destroys a commitment.
///
/// **Nothing about a *kind* of goal is written down here.** There is no list of
/// sleep words or water words. A name is resolved against [parse]'s `existing`
/// — the goals the user actually has — and, failing that, against the metric
/// labels the model layer already publishes. Anything unrecognised becomes a
/// habit of its own with whatever unit was said. That is what lets someone
/// track "duolingo 3 sessions" or "guitar 45 minutes" and have it reach the
/// dashboard by the same path as sleep, without a line of code naming either.
///
/// **Deliberately hard to trigger.** Every command needs an explicit verb.
/// Saying *"I meditated for twenty minutes"* creates nothing, because it is a
/// report rather than an instruction, and logging it is `GoalReplyParser`'s
/// job. The costs are not symmetric: missing a command leaves the user to tap
/// it in, while inventing one puts a goal on their tracker they never set.
abstract final class TrackerCommandParser {
  const TrackerCommandParser._();

  /// Verbs that start tracking something new.
  static final _add = RegExp(
    r'\b(?:'
    r'track|start tracking|add (?:a |the )?habit|new habit|'
    r'set (?:a |the )?goal|make (?:a |the )?goal|goal(?: of|:)'
    r')\b',
    caseSensitive: false,
  );

  /// Verbs that change something already tracked.
  ///
  /// Separate from [_add] because the two need different defaults: an add with
  /// no amount is a daily tick, while an edit with no amount must leave the
  /// amount alone. There was no such set at all once, which is why "change
  /// meditation to 15 minutes" silently did nothing.
  static final _edit = RegExp(
    r'\b(?:change|update|edit|adjust|switch|move|set|make|'
    r'increase|decrease|reduce|raise|lower|bump)\b',
    caseSensitive: false,
  );

  static final _drop = RegExp(
    r'\b(?:stop tracking|untrack|'
    r'(?:remove|delete|drop|stop|cancel)\s+(?:\w+\s+){0,3}?(?:habit|goal)s?)\b',
    caseSensitive: false,
  );

  static final _addTask = RegExp(
    r'\b(?:remind me to|add (?:a )?task|new task|add to (?:my )?(?:to-?do|list)|'
    r'put .{1,40} on (?:my )?(?:to-?do|list)|to-?do:)\b',
    caseSensitive: false,
  );

  static final _completeTask = RegExp(
    r'\b(?:mark|tick|check)\s+(?:off\s+)?(?:the\s+|my\s+)?(.{2,60}?)\s+'
    r'(?:as\s+)?(?:done|complete[d]?|off)\b|'
    r'\b(?:done with|finished)\s+(.{2,60})$',
    caseSensitive: false,
  );

  /// Any mention of a weekday, so a schedule can be changed on its own.
  static final _hasDays = RegExp(
    r'\b(?:mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|'
    r'sundays?|weekdays?|weekends?|every ?day|daily)\b',
    caseSensitive: false,
  );

  static final _priorityHigh = RegExp(
      r'\b(?:urgent|asap|important|high priority)\b',
      caseSensitive: false);

  /// Filler that is never part of a habit's name.
  static final _filler = RegExp(
      r'\b(?:a day|per day|each day|a week|per week|'
      r'to|for|of|my|the|a|an|is|be|it|now|habit|goal|and|on|from|'
      r'track|tracking|untrack|add|new|start|stop|remove|delete|drop|cancel|'
      r'change|update|edit|adjust|switch|move|set|make|'
      r'increase|decrease|reduce|raise|lower|bump)\b',
      caseSensitive: false);

  /// How long a habit name may be before it is obviously a sentence.
  static const maxNameWords = 4;

  /// Every command [message] asks for, resolved against [existing].
  ///
  /// [existing] is what makes an edit possible and what keeps this free of
  /// hardcoded goal types: a spoken name is matched against the goals the user
  /// really has before anything else is tried.
  static List<TrackerCommand> parse(
    String message, {
    List<Goal> existing = const [],
  }) {
    final found = <TrackerCommand>[];
    if (message.trim().isEmpty) return const [];

    for (final clause in _clauses(message.trim())) {
      final command = _one(clause, existing);
      if (command != null) found.add(command);
    }
    return found;
  }

  /// Splits on the words that join two instructions.
  ///
  /// Not on commas: "remind me to call mum, dad and the dentist" is one task,
  /// and splitting it would create three.
  static List<String> _clauses(String text) => text
      .split(RegExp(r'\s*(?:;|\.\s|\balso\b|\band then\b)\s*',
          caseSensitive: false))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();

  static TrackerCommand? _one(String clause, List<Goal> existing) {
    // Order matters: "stop tracking" contains "track", and "set X to 15" is an
    // edit when X exists and an add when it does not.
    if (_drop.hasMatch(clause)) return _dropCommand(clause, existing);
    if (_completeTask.hasMatch(clause)) return _complete(clause);
    if (_addTask.hasMatch(clause)) return _task(clause);

    final hasAdd = _add.hasMatch(clause);
    final hasEdit = _edit.hasMatch(clause);
    // A bare "gym on Tuesdays and Thursdays" reschedules something that already
    // exists. Safe without a verb because naming weekdays is not something
    // ordinary conversation does by accident.
    if (!hasAdd && !hasEdit && !_hasDays.hasMatch(clause)) return null;

    return _habitCommand(clause, existing, explicitAdd: hasAdd);
  }

  static TrackerCommand? _habitCommand(
    String clause,
    List<Goal> existing, {
    required bool explicitAdd,
  }) {
    final name = _nameIn(clause);
    if (name == null) return null;

    final amount = _amountIn(clause);
    final days = _daysIn(clause);
    final current = _resolve(name, existing);

    if (current != null) {
      // **Only what was named changes.** "yoga on Mondays" says nothing about
      // how long for, and resetting the amount to a default would quietly
      // destroy a number the user chose. The same in reverse for the days.
      var updated = current.copyWith(
        target: amount?.$1,
        unit: amount?.$2,
        weekdays: days,
      );
      if (updated.target == current.target &&
          updated.unit == current.unit &&
          updated.weekdays == current.weekdays) {
        return null; // nothing was actually asked for
      }
      updated = updated.copyWith(label: _label(name, updated));
      return TrackerCommand(
        action: TrackerAction.editHabit,
        goal: updated,
        confirmation: _changeSummary(name, current, updated),
      );
    }

    // Nothing by that name yet. An edit verb with no such goal is a request to
    // start one — "make reading 20 minutes a day" is an ordinary way to set a
    // new goal, and refusing it because the verb was not "track" is pedantry
    // the user has no way to see.
    final metric = _metricFor(name);
    var goal = Goal.forMetric(
      metric: metric,
      target: amount?.$1 ?? 1,
      unit: amount?.$2 ?? Unit.defaultFor(metric),
      weekdays: days ?? const {},
      label: name,
    );
    goal = goal.copyWith(label: _label(name, goal));

    final when = days == null ? '' : ', ${Weekdays.label(days).toLowerCase()}';
    return TrackerCommand(
      action: TrackerAction.addHabit,
      goal: goal,
      confirmation: 'now tracking ${goal.label}$when',
    );
  }

  /// The goal [name] refers to, or null.
  ///
  /// Matched against what the user actually has rather than a list of known
  /// kinds — which is the whole reason this parser needs no per-metric
  /// vocabulary. The longest match wins, so "reading" does not capture
  /// "reading aloud" when both exist.
  static Goal? _resolve(String name, List<Goal> existing) {
    final needle = _normalise(name);
    if (needle.isEmpty) return null;

    Goal? best;
    var bestLength = -1;
    for (final goal in existing) {
      for (final candidate in [
        Metric.habitName(goal.metric),
        Metric.label(goal.metric),
        goal.label,
      ]) {
        final hay = _normalise(candidate);
        if (hay.isEmpty) continue;
        final hit = hay == needle ||
            hay.startsWith('$needle ') ||
            needle.startsWith('$hay ') ||
            hay.split(' ').first == needle ||
            // Falls back to the same stem rule the review parser uses, so
            // "meditated" reaches a habit called "meditation" here too.
            goal.isMentionedIn(needle);
        if (hit && hay.length > bestLength) {
          best = goal;
          bestLength = hay.length;
        }
      }
    }
    return best;
  }

  /// The metric a *new* goal by this name should use.
  ///
  /// Built-ins are matched on the labels the model layer already publishes, not
  /// on a synonym list kept here — so "sleep" lands on [Metric.sleep] while
  /// anything else becomes a habit of its own. Adding a built-in metric needs
  /// no change to this file.
  static String _metricFor(String name) {
    final needle = _normalise(name);
    for (final metric in Metric.builtIns) {
      if (_normalise(Metric.label(metric)) == needle) return metric;
    }
    return Metric.habit(needle);
  }

  /// The user's own words for the goal, plus the amount when there is one.
  static String _label(String name, Goal goal) =>
      goal.isBinary ? name : '$name ${Unit.render(goal.target, goal.unit)}';

  static String _changeSummary(String name, Goal before, Goal after) {
    final parts = <String>[];
    if (after.target != before.target || after.unit != before.unit) {
      parts.add('now ${Unit.render(after.target, after.unit)}');
    }
    if (after.weekdays != before.weekdays) {
      parts.add('on ${Weekdays.label(after.weekdays).toLowerCase()}');
    }
    return 'changed $name to ${parts.join(', ')}';
  }

  static TrackerCommand? _dropCommand(String clause, List<Goal> existing) {
    final name = _nameIn(clause);
    if (name == null) return null;
    final current = _resolve(name, existing);
    return TrackerCommand(
      action: TrackerAction.dropHabit,
      // Falls back to a synthetic goal so the caller can still look it up by
      // metric when no existing goals were supplied.
      goal: current ??
          Goal.forMetric(metric: _metricFor(name), target: 1, label: name),
      confirmation: 'stopped tracking ${current?.label ?? name}',
    );
  }

  static TrackerCommand? _task(String clause) {
    final match = _addTask.firstMatch(clause);
    if (match == null) return null;
    var text = clause.substring(match.end).trim();
    text = text.replaceFirst(RegExp(r'^(?:to|that|about)\s+'), '');
    text = _tidy(text);
    if (text.isEmpty) return null;

    return TrackerCommand(
      action: TrackerAction.addTask,
      taskText: text,
      priority: _priorityHigh.hasMatch(clause)
          ? TodoPriority.high
          : TodoPriority.normal,
      confirmation: 'added "$text" to the list',
    );
  }

  static TrackerCommand? _complete(String clause) {
    final match = _completeTask.firstMatch(clause);
    if (match == null) return null;
    final raw = match.group(1) ?? match.group(2);
    if (raw == null) return null;
    final text = _tidy(raw);
    if (text.isEmpty) return null;
    return TrackerCommand(
      action: TrackerAction.completeTask,
      taskText: text,
      confirmation: 'ticked off "$text"',
    );
  }

  /// The habit named in [clause], or null when it cannot be picked out.
  ///
  /// Everything left after the amount, the day names and the filler are taken
  /// out. Capped at [maxNameWords] because past that it is prose, and a goal
  /// called "to be better about going to bed earlier" helps nobody.
  static String? _nameIn(String clause) {
    var rest = clause;
    if (Unit.parseAmount(rest) != null) {
      // Strip the amount by its own shape — a number plus an optional unit
      // word, twice over for "1h 30m" — rather than by a fixed unit list, so a
      // habit with a number in its name survives when no unit follows it.
      rest = rest.replaceFirst(
          RegExp(
              r'\d+(?:[.,]\d+)?\s*[a-z]*\.?\s*(?:and\s+)?'
              r'(?:\d+(?:[.,]\d+)?\s*[a-z]*)?',
              caseSensitive: false),
          ' ');
    }
    rest = rest.replaceAll(_hasDays, ' ').replaceAll(_filler, ' ');

    final name = _tidy(rest);
    if (name.isEmpty) return null;
    if (name.split(RegExp(r'\s+')).length > maxNameWords) return null;
    return name;
  }

  /// The amount being asked for, which is not always the first one said.
  ///
  /// "change gym 45 minutes to 30 minutes" names the old value before the new
  /// one, and taking the first match would read the sentence as a request to
  /// change nothing. Anything after "to" wins; without a "to" there is only one
  /// amount and the distinction does not arise.
  static (double, String)? _amountIn(String clause) {
    final tail = RegExp(r'\bto\b(.*)$', caseSensitive: false)
        .firstMatch(clause)
        ?.group(1);
    if (tail != null) {
      final after = Unit.parseAmount(tail);
      if (after != null) return after;
    }
    return Unit.parseAmount(clause);
  }

  /// The weekdays named anywhere in [clause], or null if none are.
  static Set<int>? _daysIn(String clause) {
    final days = <int>{};
    for (final word in clause.toLowerCase().split(RegExp(r'[^a-z]+'))) {
      final parsed = Weekdays.parse(word);
      if (parsed != null) days.addAll(parsed);
    }
    return days.isEmpty ? null : days;
  }

  static String _normalise(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

  /// Collapses whitespace and strips trailing punctuation and filler.
  static String _tidy(String raw) => raw
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s,:;-]+|[\s,.:;!?-]+$'), '')
      .trim();
}
