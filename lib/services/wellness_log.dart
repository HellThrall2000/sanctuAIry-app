import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/wellness.dart';
import 'database_service.dart';
import 'day_key.dart';

/// What the user logged, and how they are doing against what they set out to do.
///
/// **Assessment happens here, deterministically, and never in the model.** The
/// companion is handed a conclusion — *"movement is the one slipping"* — not the
/// table to derive it from. A 2B model asked to compute adherence from seven
/// rows will get it wrong some of the time and then coach confidently from the
/// wrong answer, which is worse than not coaching at all. It is also free: this
/// is a handful of integer comparisons, against the 15–30 seconds a generation
/// costs on this device.
///
/// Shaped after `RelationshipLog`: a singleton over `DatabaseService`, caps as
/// named constants with the reasoning attached, and every threshold chosen so
/// that saying nothing is the default.
class WellnessLog {
  static final WellnessLog instance = WellnessLog._();

  WellnessLog._();

  final DatabaseService _db = DatabaseService();

  Future<Database> get _database => _db.database;

  /// The window "lately" means.
  ///
  /// A week is the span a person can actually feel and remember. Shorter reads
  /// as nagging — three bad days is a bad week, not a pattern. Longer stops
  /// being actionable, because by then the thing to change has moved.
  static const int adherenceWindow = 7;

  /// Below this many logged days in the window, report nothing about how they
  /// are doing.
  ///
  /// The same reasoning as `RelationshipLog.minReadingsForTrend`: asserting a
  /// pattern off two days is exactly what makes a companion feel presumptuous,
  /// and someone who has just started tracking should not be told they are
  /// already failing.
  static const int minDaysForAssessment = 4;

  /// Adherence below this counts as slipping, and is worth mentioning.
  static const double slippingBelow = 0.5;

  /// Runs shorter than this are not streaks, they are a couple of good days.
  static const int minStreakToMention = 3;

  /// How far back a streak will be counted before giving up.
  ///
  /// A bound rather than a truth: nobody needs to be told their streak is 400,
  /// and it stops one query walking an unbounded history.
  static const int maxStreakLookback = 365;

  // ── Logging ────────────────────────────────────────────────────────────

  /// Records [value] for [metric] on the local day [when] falls in.
  ///
  /// An **upsert**, not an append: drinking water four times in a day is one row
  /// that grows, not four rows to sum at read time. It also makes a correction
  /// — "no, six hours" — a plain replace, with no ambiguity about which of two
  /// rows is true.
  /// Bumped after every write, so anything on screen can reload.
  ///
  /// **The tracker is edited from two places that cannot see each other.** A
  /// goal changed from the conversation and a goal changed in the panel go
  /// through the same store, but the panel is a drawer that slides off-screen
  /// rather than unmounting — so it kept showing whatever it loaded the first
  /// time it was built, and on a tablet it is visible *beside* the chat while
  /// the change is being made. Nothing short of the store announcing its own
  /// writes fixes that.
  ///
  /// A counter rather than the data itself: every listener reloads what it
  /// needs, and no store has to know what any screen is showing.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Announces a write.
  ///
  /// **Called after the row has landed, never before.** A listener reloads from
  /// the database, so announcing first is a race it would lose: it would read
  /// the old value and redraw exactly the stale screen this exists to fix.
  ///
  /// Scheduled rather than fired inline so a listener that rebuilds cannot run
  /// inside the caller's own frame.
  void _changed() =>
      scheduleMicrotask(() => revision.value = revision.value + 1);

  Future<void> log(String metric, double value, {DateTime? when}) async {
    final at = when ?? DateTime.now();
    final db = await _database;
    await db.insert(
      'daily_metric',
      {
        'day': DayKey.of(at),
        'metric': metric,
        'value': value,
        'loggedAt': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _changed();
  }

  /// Removes a single day's entry for [metric] — an undo, not a correction.
  Future<void> unlog(String metric, {DateTime? when}) async {
    final db = await _database;
    await db.delete(
      'daily_metric',
      where: 'day = ? AND metric = ?',
      whereArgs: [DayKey.of(when ?? DateTime.now()), metric],
    );
    _changed();
  }

  /// Everything logged on one local day, keyed by metric.
  Future<Map<String, double>> forDay([String? day]) async {
    final db = await _database;
    final rows = await db.query(
      'daily_metric',
      columns: ['metric', 'value'],
      where: 'day = ?',
      whereArgs: [day ?? DayKey.today()],
    );
    return {
      for (final r in rows) r['metric'] as String: (r['value'] as num).toDouble(),
    };
  }

  /// The last [days] days for [metric], **newest first**, with `null` for days
  /// that were never logged.
  ///
  /// One query, then aligned in Dart. The alternative — a query per day — is
  /// seven round trips to answer a question about a week.
  Future<List<double?>> history(String metric, {int days = adherenceWindow}) async {
    final keys = DayKey.lastDays(days);
    final db = await _database;
    final rows = await db.query(
      'daily_metric',
      columns: ['day', 'value'],
      where: 'metric = ? AND day >= ?',
      whereArgs: [metric, keys.last],
    );
    final byDay = {
      for (final r in rows) r['day'] as String: (r['value'] as num).toDouble(),
    };
    return [for (final k in keys) byDay[k]];
  }

  /// How many of the last [days] days have any entry at all.
  ///
  /// The gate for whether there is enough to say anything — see
  /// [minDaysForAssessment].
  Future<int> loggedDayCount({int days = adherenceWindow}) async {
    final keys = DayKey.lastDays(days);
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT day) AS n FROM daily_metric WHERE day >= ?',
      [keys.last],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  // ── Goals ──────────────────────────────────────────────────────────────

  /// A goal set since the companion last spoke, waiting to be acknowledged.
  ///
  /// **In memory on purpose.** Setting a goal is worth a reaction *now*; if the
  /// app is closed before the user says anything, the moment has passed and
  /// congratulating them about it on Thursday would be stranger than silence.
  /// Consumed exactly once by [takeNewGoal].
  String? _newGoal;

  /// The label of a goal set since the last turn, clearing it as it goes.
  String? takeNewGoal() {
    final label = _newGoal;
    _newGoal = null;
    return label;
  }

  /// Sets or corrects the goal for a metric. Keyed by slot, so there is only
  /// ever one active goal per metric.
  Future<void> setGoal(Goal goal) async {
    final db = await _database;
    final existing = await goalFor(goal.metric);
    await db.insert(
      'goals',
      goal.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Only a genuinely new goal is worth enthusiasm. Adjusting a target from
    // seven hours to eight is housekeeping, and reacting to it as a fresh start
    // would make the reaction meaningless the second time it happened.
    if (existing == null) _newGoal = goal.label;
    _changed();
  }

  Future<List<Goal>> activeGoals() async {
    final db = await _database;
    final rows = await db.query(
      'goals',
      where: 'archivedAt IS NULL',
      orderBy: 'createdAt ASC',
    );
    return rows.map(Goal.fromMap).toList(growable: false);
  }

  Future<Goal?> goalFor(String metric) async {
    final db = await _database;
    final rows = await db.query(
      'goals',
      where: 'id = ? AND archivedAt IS NULL',
      whereArgs: [Goal.idFor(metric)],
      limit: 1,
    );
    return rows.isEmpty ? null : Goal.fromMap(rows.first);
  }

  /// Retires a goal without deleting it, so the history scored against it stays
  /// explicable.
  Future<void> archiveGoal(String id, {DateTime? at}) async {
    final db = await _database;
    await db.update(
      'goals',
      {'archivedAt': (at ?? DateTime.now()).toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  // ── Assessment ─────────────────────────────────────────────────────────

  /// Consecutive days, most recent first, on which [goal] was met.
  ///
  /// **Today being unlogged does not break a streak.** At nine in the morning
  /// nobody has slept seven hours *today*, and a tracker that resets the moment
  /// the date rolls over punishes the user for the clock. So an empty today is
  /// skipped and counting starts at yesterday; an empty yesterday ends it.
  ///
  /// Returns 0 for a weekly goal — a run of days is not what "three times a
  /// week" means, and pretending otherwise would report a streak of 1 forever.
  Future<int> streak(Goal goal) async =>
      streakFrom(await history(goal.metric, days: maxStreakLookback), goal);

  /// The pure form of [streak], over [newestFirst] values aligned to
  /// consecutive days.
  ///
  /// Split out from the query so the maths is testable without a database.
  /// `sqflite` binds a platform SQLite that `flutter test` has no access to, so
  /// anything that touches a table can only be verified on a device — the
  /// arithmetic that actually decides what the companion says should not have to
  /// wait for that.
  static int streakFrom(List<double?> newestFirst, Goal goal, {DateTime? from}) {
    if (goal.cadence == GoalCadence.weekly) return 0;
    if (newestFirst.isEmpty) return 0;
    final today = from ?? DateTime.now();

    var index = 0;
    if (newestFirst.first == null) index = 1; // today not logged yet — grace

    var run = 0;
    for (var i = index; i < newestFirst.length; i++) {
      // Calendar arithmetic, not a Duration, for the reason DayKey.daysAgo
      // documents: 24 hours before midday is the wrong date on the day a
      // timezone shifts.
      final day = DateTime(today.year, today.month, today.day - i);

      // **A day off is neither kept nor broken.** Someone who runs on Tuesdays
      // and Thursdays has not failed on a Wednesday, and counting it as a miss
      // would make a scheduled habit permanently show a streak of one — which
      // is the fastest way to teach them the number means nothing.
      if (!goal.appliesOn(day)) continue;

      final value = newestFirst[i];
      if (value == null || !goal.isMetBy(value)) break;
      run++;
    }
    return run;
  }

  /// How much of [goal] has been kept over the window, from 0.0 to 1.0.
  ///
  /// Daily goals score met-days over the whole window, so a day never logged
  /// counts against you — that is the honest reading, since the point of a daily
  /// goal is the day. Weekly goals score days-logged against the target count,
  /// capped at 1.0, so "move 3 times a week" is satisfied by three days and not
  /// improved by seven.
  Future<double> adherence(Goal goal, {int days = adherenceWindow}) async =>
      adherenceFrom(await history(goal.metric, days: days), goal);

  /// The pure form of [adherence]. See [streakFrom] for why this is split out.
  static double adherenceFrom(List<double?> values, Goal goal,
      {DateTime? from}) {
    if (values.isEmpty) return 0;

    if (goal.cadence == GoalCadence.weekly) {
      if (goal.target <= 0) return 0;
      final logged = values.where((v) => v != null && v > 0).length;
      final ratio = logged / goal.target;
      return ratio > 1.0 ? 1.0 : ratio;
    }

    final today = from ?? DateTime.now();
    var applicable = 0;
    var met = 0;
    for (var i = 0; i < values.length; i++) {
      final day = DateTime(today.year, today.month, today.day - i);
      // Same rule as the streak: days the goal is not in force on are not part
      // of the denominator either, or a Mon/Thu habit could never score above
      // two sevenths however perfectly it was kept.
      if (!goal.appliesOn(day)) continue;
      applicable++;
      final value = values[i];
      if (value != null && goal.isMetBy(value)) met++;
    }
    // Every day in the window was a day off — nothing was asked, so nothing
    // was missed. Zero here would read as total failure.
    if (applicable == 0) return 1;
    return met / applicable;
  }

  /// The active goal being kept least well, or null when there is nothing
  /// worth saying.
  ///
  /// Returns null — deliberately, and in three separate cases — when there are
  /// no goals, when there is not yet enough logged to judge
  /// ([minDaysForAssessment]), or when nothing is actually slipping
  /// ([slippingBelow]). A companion that always has a criticism ready is not
  /// observant, it is tiring.
  Future<Goal?> weakestGoal({int days = adherenceWindow}) async {
    final goals = await activeGoals();
    if (goals.isEmpty) return null;

    final logged = await loggedDayCount(days: days);
    if (logged < minDaysForAssessment) return null;

    Goal? worst;
    var worstScore = double.infinity;
    for (final goal in goals) {
      final score = await adherence(goal, days: days);
      if (score < worstScore) {
        worstScore = score;
        worst = goal;
      }
    }
    return worstScore < slippingBelow ? worst : null;
  }

  /// Consecutive days on which *anything* was logged.
  ///
  /// Separate from [streak], which is per goal. This is the "you have shown up
  /// 12 days running" number, and showing up is worth something even on a day
  /// the target was missed.
  Future<int> loggingStreak() async {
    final keys = DayKey.lastDays(maxStreakLookback);
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT day FROM daily_metric WHERE day >= ?',
      [keys.last],
    );
    final logged = {for (final r in rows) r['day'] as String};
    if (logged.isEmpty) return 0;

    var index = 0;
    if (!logged.contains(keys.first)) index = 1; // same grace as [streak]

    var run = 0;
    for (var i = index; i < keys.length; i++) {
      if (!logged.contains(keys[i])) break;
      run++;
    }
    return run;
  }

  /// What the companion is told, in three or four short lines — or nothing.
  ///
  /// **Conclusions, not data.** The model receives "movement is the one
  /// slipping", never the seven rows that prove it. Everything here is decided
  /// by the arithmetic above before a single token is spent.
  ///
  /// Shaped after `RelationshipLog.promptBlock`, whose doc records the two rules
  /// this has to follow. It is **framed as observation, not instruction** — the
  /// model follows the shape of what it is given, so told to encourage someone
  /// it announces its encouragement. And it is **short**, because it competes
  /// for the same 4096 tokens as the persona, the profile and the conversation.
  ///
  /// Returns null whenever there is nothing worth saying, which is most of the
  /// time early on. A companion that always has a progress report ready is not
  /// attentive, it is a dashboard with opinions.
  Future<String?> promptBlock() async {
    final goals = await activeGoals();
    if (goals.isEmpty) return null;

    final lines = <String>[];

    // 1. What they are aiming at, in their own words.
    final named = goals.take(3).map((g) => g.label).join(', ');
    lines.add('They are working on: $named.');

    final logged = await loggedDayCount();
    if (logged >= minDaysForAssessment) {
      // 2. How the week actually went, for at most two goals. Naming four is a
      // report; naming two is a remark.
      final kept = <String>[];
      for (final goal in goals.take(2)) {
        final score = await adherence(goal);
        final days = (score * adherenceWindow).round();
        kept.add('${Metric.label(goal.metric)} $days of $adherenceWindow days');
      }
      if (kept.isNotEmpty) {
        lines.add('This past week they managed ${kept.join(' and ')}.');
      }

      // 3. The one thing slipping, if anything actually is.
      final weakest = await weakestGoal();
      if (weakest != null) {
        lines.add('${_capitalise(Metric.label(weakest.metric))} is the one '
            'slipping.');
      }
    }

    // 4. Showing up, which counts even on days the target was missed.
    final streak = await loggingStreak();
    if (streak >= minStreakToMention) {
      lines.add('They have logged something $streak days running.');
    }

    final rendered = lines.join('\n');
    // A cap enforced here rather than trusted to the lines above: every metric
    // added upstream steals tokens from the conversation itself.
    return rendered.length <= maxDigestChars
        ? rendered
        : rendered.substring(0, maxDigestChars);
  }

  /// Hard ceiling on [promptBlock]. Roughly 100 tokens at
  /// `ContextBudget.charsPerToken`, the same scale as the relationship block.
  static const int maxDigestChars = 360;

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Erases every tracked value and goal.
  ///
  /// Must be called from the app's "forget everything" path alongside
  /// `MemoryStore.forgetAll`, `ChunkStore.clear` and `RelationshipLog.clear` —
  /// a tracker that survives an erase is the worst kind of surprise.
  Future<void> clear() async {
    final db = await _database;
    await db.delete('daily_metric');
    await db.delete('goals');
  }
}
