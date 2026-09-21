import 'weekdays.dart';

/// What a goal is counted in.
///
/// **A habit carries a quantity now, not a tick.** It used to be that every
/// user-defined habit was boolean — "meditate" was done or not done — which
/// made the one thing people actually want to say about a habit unsayable:
/// *how much*. Thirty minutes of meditation and two minutes of it were the
/// same row. The unit is what closes that, and it belongs on the goal rather
/// than the metric because only the goal knows whether "meditate" is being
/// counted in minutes, in sessions, or in pages of a book.
///
/// Strings rather than an enum, for the same reason [Metric] is: these are
/// stored, and an enum index that shifts when someone inserts a value in the
/// middle silently rewrites history.
abstract final class Unit {
  const Unit._();

  static const minutes = 'minutes';
  static const hours = 'hours';
  static const times = 'times';
  static const litres = 'litres';
  static const glasses = 'glasses';
  static const pages = 'pages';
  static const steps = 'steps';
  static const kilometres = 'km';

  /// Mood only. Kept out of [choices] because nobody sets a goal in it.
  static const rating = 'rating';

  /// What the UI offers, in the order it offers them.
  static const choices = [
    minutes, hours, times, litres, glasses, pages, steps, kilometres,
  ];

  /// The unit a metric is counted in when nobody says otherwise.
  static String defaultFor(String metric) => switch (metric) {
        Metric.sleep => hours,
        Metric.water => litres,
        Metric.movement => minutes,
        Metric.mood => rating,
        // A habit with no unit given is counted in occurrences, which is what
        // the old boolean habit was — so an existing row reads unchanged.
        _ => times,
      };

  /// "30 minutes", "1 hour 30 minutes", "2.5 litres", "4 out of 5".
  ///
  /// Written out rather than suffixed (`30m`), because this text goes into the
  /// model's context and an abbreviation reads as a data table. The prompt
  /// block is meant to sound like something a friend noticed.
  ///
  /// Minutes past the hour are spoken as hours *and* minutes. Ninety minutes is
  /// something nobody says out loud, and a goal the user cannot read back in
  /// their own words is one they stop trusting.
  static String render(double value, String unit) {
    if (unit == rating) return '${_trim(value)} out of 5';
    if (unit == minutes && value >= 60) return _duration(value);
    final n = _trim(value);
    final one = value == 1;
    return switch (unit) {
      minutes => '$n ${one ? 'minute' : 'minutes'}',
      hours => '$n ${one ? 'hour' : 'hours'}',
      times => '$n ${one ? 'time' : 'times'}',
      litres => '$n ${one ? 'litre' : 'litres'}',
      glasses => '$n ${one ? 'glass' : 'glasses'}',
      pages => '$n ${one ? 'page' : 'pages'}',
      steps => '$n ${one ? 'step' : 'steps'}',
      kilometres => '$n km',
      // A unit the user invented. Pluralised naively rather than left bare,
      // because "12 rep" reads as a bug — and naively is as far as anyone
      // should go without knowing the word.
      _ => '$n ${one || unit.endsWith('s') ? unit : '${unit}s'}',
    };
  }

  /// A whole number of minutes as hours and minutes: `90` -> "1 hour 30
  /// minutes", `120` -> "2 hours".
  static String _duration(double value) {
    final total = value.round();
    final h = total ~/ 60;
    final m = total % 60;
    final hours = '$h ${h == 1 ? 'hour' : 'hours'}';
    if (m == 0) return hours;
    return '$hours $m ${m == 1 ? 'minute' : 'minutes'}';
  }

  /// Reads an amount and its unit out of free text, or null.
  ///
  /// **Hours and minutes together**, because that is how durations are said:
  /// "an hour and a half", "1h 30m", "90 minutes" are the same goal and all
  /// three have to land on the same number. Combined durations are returned in
  /// [minutes] so there is one canonical form to compare and add up; a bare
  /// whole number of hours keeps [hours], so "sleep 7 hours" is stored and
  /// spoken the way it was said.
  ///
  /// Fractional hours are converted too — 2.5 hours is 150 minutes, which
  /// renders as "2 hours 30 minutes" instead of the unsayable "2.5 hours".
  static (double, String)? parseAmount(String text) {
    final combined = _combined.firstMatch(text);
    if (combined != null) {
      final h = _number(combined.group(1));
      final m = _number(combined.group(2));
      if (h != null && m != null) return (h * 60 + m, minutes);
    }

    final single = _single.firstMatch(text);
    if (single != null) {
      final value = _number(single.group(1));
      final unit = parse(single.group(2)!);
      if (value != null && unit != null) {
        // A fraction of an hour is more precisely a count of minutes.
        if (unit == hours && value != value.roundToDouble()) {
          return (value * 60, minutes);
        }
        return (value, unit);
      }
    }

    // **A unit nobody shipped.** "40 reps", "3 chapters", "12 laps" — the list
    // above is a set of spellings this app happens to know, not a limit on
    // what a person may count. Anything else that directly follows a number
    // is taken at face value.
    //
    // Guarded by [_notAUnit] rather than by a list of permitted words, since
    // the whole point is that the permitted list cannot be written down. What
    // *can* be written down is the short set of words that follow a number
    // without being a unit — "3 times a week", "2 days", "5 monday".
    final any = _anyUnit.firstMatch(text);
    if (any == null) return null;
    final value = _number(any.group(1));
    final word = any.group(2)!.toLowerCase();
    if (value == null || _notAUnit.hasMatch(word)) return null;
    return (value, word);
  }

  /// A number and whatever word follows it.
  static final _anyUnit =
      RegExp(r'(\d+(?:[.,]\d+)?)\s*([a-z]{2,20})\b', caseSensitive: false);

  /// Words that follow a number without being a unit.
  static final _notAUnit = RegExp(
    r'^(?:a|an|per|each|every|and|or|to|of|on|in|for|the|my|'
    r'day|days|daily|week|weeks|weekly|month|months|year|years|'
    r'monday|tuesday|wednesday|thursday|friday|saturday|sunday|'
    r'mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays|'
    r'weekday|weekdays|weekend|weekends|am|pm|oclock)$',
    caseSensitive: false,
  );

  static double? _number(String? raw) =>
      raw == null ? null : double.tryParse(raw.replaceAll(',', '.'));

  /// "1h 30m", "1 hour and 30 minutes", "2 hrs 15".
  static final _combined = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(?:hours?|hrs?|h)\s*(?:and\s+)?'
    r'(\d+(?:[.,]\d+)?)\s*(?:minutes?|mins?|m)?\b',
    caseSensitive: false,
  );

  /// One amount and one unit. Longest alternative first, and anchored — with
  /// `mins?` ahead of `minutes?` the word "minutes" matches as "min" and leaves
  /// the letters "utes" behind in whatever the caller does with the remainder.
  static final _single = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*'
    r'(minutes?|mins?|hours?|hrs?|sessions?|times?|litres?|liters?|'
    r'glasses|glass|pages?|steps?|kilometres?|kilometers?|km|h|l|x)\b',
    caseSensitive: false,
  );

  /// The unit [word] names, or null. Understands the abbreviations people
  /// actually type, which is most of what makes the chat parser usable.
  static String? parse(String word) {
    final w = word.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return switch (w) {
      'min' || 'mins' || 'minute' || 'minutes' => minutes,
      'h' || 'hr' || 'hrs' || 'hour' || 'hours' => hours,
      'x' || 'time' || 'times' || 'session' || 'sessions' => times,
      'l' || 'litre' || 'litres' || 'liter' || 'liters' => litres,
      'glass' || 'glasses' => glasses,
      'page' || 'pages' => pages,
      'step' || 'steps' => steps,
      'km' || 'kilometre' || 'kilometres' || 'kilometer' || 'kilometers' => kilometres,
      _ => null,
    };
  }

  static String _trim(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(1);
  }
}

/// The things a wellness goal can be measured in.
///
/// **Strings, not an enum**, because a user-defined habit is a metric too and
/// there is no closed set of those. `'habit:meditate'` and `'sleep'` travel down
/// exactly the same code path, are stored in the same column, and are scored by
/// the same maths — one mechanism rather than a built-in system plus a custom
/// system that drift apart.
abstract final class Metric {
  const Metric._();

  static const String sleep = 'sleep';
  static const String water = 'water';
  static const String movement = 'movement';
  static const String mood = 'mood';

  /// The four the app knows about out of the box. Order is the order they are
  /// shown.
  static const List<String> builtIns = [sleep, movement, water, mood];

  /// The ones a goal can be set on.
  ///
  /// **Mood is deliberately absent.** It is read from how someone writes, not
  /// aimed at — and "feel okay or better, 3 out of 5" is a target that turns a
  /// bad day into a failed day. Nothing else in the app scores a person on
  /// their mood and the goal picker should not either. The metric stays: it is
  /// still logged, still charted, still something the companion notices.
  static const List<String> trackable = [sleep, movement, water];

  static const String _habitPrefix = 'habit:';

  /// The face the app ships for its own metrics, or null.
  ///
  /// Only the built-ins get one. A habit is whatever the user invented, and
  /// picking a picture for it on their behalf is the guessing game
  /// [Goal.emoji] exists to avoid — they choose, or it goes without.
  static String? defaultEmojiFor(String metric) => switch (metric) {
        sleep => '😴',
        water => '💧',
        movement => '🏃',
        mood => '🌤️',
        _ => null,
      };

  /// A user-defined habit, keyed so it cannot collide with a built-in.
  static String habit(String slug) => '$_habitPrefix${slug.trim().toLowerCase()}';

  static bool isHabit(String metric) => metric.startsWith(_habitPrefix);

  /// The habit's own name, for display. `'habit:meditate'` -> `'meditate'`.
  static String habitName(String metric) =>
      isHabit(metric) ? metric.substring(_habitPrefix.length) : metric;

  /// The verb-ish label used when talking about the metric.
  static String label(String metric) => switch (metric) {
        sleep => 'sleep',
        water => 'water',
        movement => 'movement',
        mood => 'mood',
        _ => habitName(metric),
      };

  /// [value] as English, in the metric's *default* unit.
  ///
  /// Prefer [Goal.renderValue] wherever a goal is in hand: only the goal knows
  /// what its habit is actually counted in, and this can do no better than the
  /// default. This exists for the places that hold a bare metric — a log row
  /// with no goal behind it any more, for instance.
  static String render(String metric, double value) =>
      Unit.render(value, Unit.defaultFor(metric));
}

/// How often a goal's target applies.
enum GoalCadence {
  /// The target must be met on each day — "sleep 7 hours".
  daily,

  /// The target is a count of days within a week — "move 3 times a week".
  weekly;

  static GoalCadence fromName(String name) => GoalCadence.values.firstWhere(
        (c) => c.name == name,
        orElse: () => GoalCadence.daily,
      );
}

/// Something the user is trying to do.
///
/// [id] is a **slot key** (`goal:sleep`), not a surrogate. Setting a goal for a
/// metric that already has one corrects it in place, which is what makes the
/// store self-correcting when someone changes their mind — the same reasoning
/// behind `MemoryFact.key`. It also means a goal and its metric can never drift
/// apart, because the id is derived from the metric.
class Goal {
  final String id;
  final String metric;

  /// Hours, litres, minutes, a 1–5 rating — or, for [GoalCadence.weekly], the
  /// number of days in the week the metric should be logged at all.
  final double target;

  final GoalCadence cadence;

  /// What [target] is counted in — see [Unit].
  final String unit;

  /// The face the user gave it, or null.
  ///
  /// **Chosen, never derived.** The obvious alternative is a lookup from habit
  /// name to picture, and it is wrong twice over: it is exactly the hardcoded
  /// vocabulary this app keeps removing, and it would fail on the habits that
  /// matter most to the person who invented them. A blank one is fine — the
  /// card falls back rather than guessing.
  final String? emoji;

  /// The days this applies on, empty meaning every day.
  ///
  /// A habit is not always a daily one: "gym on Tuesdays and Thursdays" is the
  /// ordinary case, not an advanced one, and without this the only way to say
  /// it was to accept a broken streak on every day off.
  final Set<int> weekdays;

  /// The user's own words: *"sleep 7 hours"*. Kept beside the parsed target so
  /// a prompt line can quote them rather than reconstructing English from a
  /// number and a unit.
  final String label;

  final DateTime createdAt;

  /// Null while the goal is active. Archived rather than deleted, so a past
  /// goal cannot silently rewrite the history that was scored against it.
  final DateTime? archivedAt;

  const Goal({
    required this.id,
    required this.metric,
    required this.target,
    required this.label,
    required this.createdAt,
    required this.unit,
    this.emoji,
    this.weekdays = const {},
    this.cadence = GoalCadence.daily,
    this.archivedAt,
  });

  bool get isActive => archivedAt == null;

  /// Whether this is the old done-or-not-done habit.
  ///
  /// Derived rather than stored: "once, counted in occurrences" *is* a tick,
  /// and giving it a separate flag would allow the two to disagree.
  bool get isBinary => unit == Unit.times && target <= 1;

  bool get isEveryDay => Weekdays.isEveryDay(weekdays);

  /// Whether the goal is in force on [day]. Days off are not misses.
  bool appliesOn(DateTime day) =>
      isEveryDay || weekdays.contains(day.weekday);

  String get daysLabel => Weekdays.label(weekdays);

  /// Whether [text] appears to name this goal.
  ///
  /// **Stem-matched**, so a habit called "meditation" is found by "meditated"
  /// and "reading" by "read". Comparing whole words missed every inflection,
  /// which meant a custom habit could be set up by name and then never
  /// recognised again in the sentence the user used to report it.
  ///
  /// [stemLength] characters is enough to separate the habits one person
  /// tracks while still absorbing English endings. It is not a stemmer and does
  /// not try to be: irregular verbs ("slept" for sleep) cannot be reached this
  /// way and are covered by the caller's own vocabulary where it has one.
  bool isMentionedIn(String text) {
    final haystack = text.toLowerCase();
    for (final name in [Metric.habitName(metric), Metric.label(metric)]) {
      final needle = name.toLowerCase().trim();
      if (needle.isEmpty) continue;
      // Whole words, not a raw substring: "ready" must not answer for a habit
      // called "read", and a short name makes that failure common.
      if (RegExp(r'\b' + RegExp.escape(needle) + r'\b').hasMatch(haystack)) {
        return true;
      }

      final stem = needle.length <= stemLength
          ? needle
          : needle.substring(0, stemLength);
      if (stem.length < stemLength) continue;
      for (final word in haystack.split(RegExp(r'[^a-z0-9]+'))) {
        if (word.startsWith(stem)) return true;
      }
    }
    return false;
  }

  /// How much of a name has to match before two words count as the same thing.
  ///
  /// Five is long enough that "read" does not claim "ready" — which four would
  /// — and short enough that "meditation" and "meditated" still meet.
  static const int stemLength = 5;

  /// [value] as English, in this goal's own unit.
  String renderValue(double value) =>
      isBinary ? (value > 0 ? 'done' : 'not done') : Unit.render(value, unit);

  /// The target as English — "30 minutes", or "every day" for a bare tick.
  String get targetLabel => isBinary ? 'once a day' : Unit.render(target, unit);

  static String idFor(String metric) => 'goal:$metric';


  /// A goal for [metric], with its slot id and timestamp filled in.
  factory Goal.forMetric({
    required String metric,
    required double target,
    required String label,
    String? unit,
    String? emoji,
    Set<int> weekdays = const {},
    GoalCadence cadence = GoalCadence.daily,
    DateTime? createdAt,
  }) =>
      Goal(
        id: idFor(metric),
        metric: metric,
        target: target,
        label: label.trim(),
        unit: unit ?? Unit.defaultFor(metric),
        emoji: emoji ?? Metric.defaultEmojiFor(metric),
        weekdays: weekdays,
        cadence: cadence,
        createdAt: createdAt ?? DateTime.now(),
      );

  Goal archived({DateTime? at}) => copyWith(archivedAt: at ?? DateTime.now());

  Goal copyWith({
    double? target,
    String? label,
    String? unit,
    String? emoji,
    Set<int>? weekdays,
    GoalCadence? cadence,
    DateTime? archivedAt,
  }) =>
      Goal(
        id: id,
        metric: metric,
        target: target ?? this.target,
        label: label ?? this.label,
        unit: unit ?? this.unit,
        emoji: emoji ?? this.emoji,
        weekdays: weekdays ?? this.weekdays,
        cadence: cadence ?? this.cadence,
        createdAt: createdAt,
        archivedAt: archivedAt ?? this.archivedAt,
      );

  /// Whether [value] logged on one day counts as meeting this goal.
  ///
  /// Greater-or-equal for everything, including mood: a goal is a floor, not a
  /// target to hit exactly.
  bool isMetBy(double value) => value >= target;

  Map<String, Object?> toMap() => {
        'id': id,
        'metric': metric,
        'target': target,
        'cadence': cadence.name,
        'unit': unit,
        'emoji': emoji,
        'weekdays': Weekdays.encode(weekdays),
        'label': label,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'archivedAt': archivedAt?.toUtc().toIso8601String(),
      };

  factory Goal.fromMap(Map<String, Object?> map) {
    final archived = map['archivedAt'] as String?;
    return Goal(
      id: map['id'] as String,
      metric: map['metric'] as String,
      target: (map['target'] as num).toDouble(),
      cadence: GoalCadence.fromName(map['cadence'] as String? ?? 'daily'),
      // Null on every row written before the column existed. Falling back to
      // the metric's default is what makes the migration a no-op for them:
      // a habit reads as "times", which is exactly the tick it used to be.
      unit: map['unit'] as String? ?? Unit.defaultFor(map['metric'] as String),
      // Null on every row written before the column existed, which reads as
      // the built-in default or, for a habit, as no face at all.
      emoji: map['emoji'] as String? ??
          Metric.defaultEmojiFor(map['metric'] as String),
      weekdays: Weekdays.decode(map['weekdays'] as String?),
      label: map['label'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String).toLocal(),
      archivedAt:
          archived == null ? null : DateTime.parse(archived).toLocal(),
    );
  }
}
