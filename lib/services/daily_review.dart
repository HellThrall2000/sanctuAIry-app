import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wellness.dart';
import 'day_key.dart';
import 'wellness_log.dart';

/// One metric the user just told us about.
@immutable
class LoggedValue {
  final String metric;
  final double value;

  const LoggedValue(this.metric, this.value);

  @override
  String toString() => '$metric=$value';
}

/// The end-of-day question, and what it was asked about.
@immutable
class ReviewPrompt {
  final String text;

  /// The goals named in [text], in the order they were named — which is what
  /// lets a bare "yes, no, 40 minutes" be matched back positionally.
  final List<Goal> asked;

  /// The local day being asked about, at midnight.
  ///
  /// Carried rather than recomputed when the answer arrives: the question can
  /// be asked at 06:55 and answered at 07:05, and only the question knows which
  /// day it meant. Without this the answer would land on the wrong date exactly
  /// when someone is up late — the case the window exists to serve.
  final DateTime day;

  const ReviewPrompt(this.text, this.asked, this.day);
}

/// The evening check-in: asks how the day went, then reads the answer.
///
/// **The question is written, not generated.** It fires at a fixed hour and has
/// to be identical every night, which a sampler cannot promise — and a 15–30 s
/// generation to ask "did you sleep seven hours?" is the wrong trade. The
/// *reply* is where the model earns its place.
///
/// **The answer is parsed, not generated.** Asking a 2B model to turn "slept
/// about 7, skipped the walk" into structured values costs a second inference
/// pass and gets it wrong often enough to corrupt the log — and a tracker whose
/// numbers are sometimes invented is worse than one that missed a day. So the
/// parse is lexical and conservative: anything it is not sure about is left
/// unlogged rather than guessed, and the user can always tap it in.
class DailyReview {
  static final DailyReview instance = DailyReview._();

  DailyReview._();

  /// From this hour, the day is over enough to ask about.
  ///
  /// 20:00 rather than later because the point is to catch someone before they
  /// put the phone down, and rather than earlier because "did you move today"
  /// at 5pm is a question they cannot answer yet.
  static const int reviewHour = 20;

  /// Until this hour, the small hours still belong to the night before.
  ///
  /// Someone who opens the app at 00:30 is telling you about the day that just
  /// ended, not the one thirty minutes old — so the window runs from
  /// [reviewHour] through to here, and the day it is *about* is [reviewDay],
  /// which is not the same as the calendar day for the second half of it.
  static const int quietBefore = 7;

  static const String _lastReviewKey = 'sanctuary_last_review_day';

  /// The most goals one question will name.
  ///
  /// Three is about what someone will answer in one sentence. Past that the
  /// question becomes a form, and people stop filling in forms.
  static const int maxGoalsAsked = 3;

  /// The question for tonight, or null.
  ///
  /// Null in every ordinary case — too early, no goals, already asked today, or
  /// everything already logged. Asking about a day the user already recorded is
  /// the fastest way to teach them the question is not worth reading.
  Future<ReviewPrompt?> pending({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final day = reviewDay(at);
    if (day == null) return null;
    final key = DayKey.of(day);

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_lastReviewKey) == key) return null;

    final goals = await WellnessLog.instance.activeGoals();
    if (goals.isEmpty) return null;

    final logged = await WellnessLog.instance.forDay(key);
    final unlogged = goals
        // Not a day this goal runs on, so there is nothing to ask. Asking
        // anyway invites a "no" that would be recorded as a miss on a day the
        // user was never supposed to be doing it.
        .where((g) => g.appliesOn(day))
        .where((g) => !logged.containsKey(g.metric))
        .toList();
    if (unlogged.isEmpty) return null;

    final asked = unlogged.take(maxGoalsAsked).toList();
    return ReviewPrompt(_question(asked), asked, day);
  }

  /// The day a review happening at [at] is about, or null outside the window.
  ///
  /// After [reviewHour] that is the day in progress; before [quietBefore] it is
  /// the day that just ended. Keying the small hours to the new calendar day
  /// instead would do two wrong things at once — ask about a day only minutes
  /// old, and spend that day's "already asked" marker before its real evening
  /// ever arrived.
  ///
  /// Calendar arithmetic rather than `subtract(Duration(days: 1))`, for the
  /// reason [DayKey.daysAgo] documents: a duration is a fixed number of hours
  /// and lands on the wrong date near midnight when the clocks shift.
  static DateTime? reviewDay(DateTime at) {
    if (at.hour >= reviewHour) return DateTime(at.year, at.month, at.day);
    if (at.hour < quietBefore) return DateTime(at.year, at.month, at.day - 1);
    return null;
  }

  /// Marks [day]'s review as asked, so it happens once.
  Future<void> markDelivered(DateTime day) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastReviewKey, DayKey.of(day));
  }

  /// Writes everything [values] contains, on the local day of [when].
  Future<void> apply(List<LoggedValue> values, {DateTime? when}) async {
    for (final v in values) {
      await WellnessLog.instance.log(v.metric, v.value, when: when);
    }
  }

  /// The question itself.
  ///
  /// One sentence, their own words for the goals, and an explicit "or tell me
  /// what you did" so it does not read as a form to be completed exactly.
  static String _question(List<Goal> asked) {
    final names = asked.map((g) => g.label).toList();
    final joined = switch (names.length) {
      1 => names.first,
      2 => '${names[0]} and ${names[1]}',
      _ => '${names.sublist(0, names.length - 1).join(', ')} '
          'and ${names.last}',
    };
    return 'Before the day closes — how did you get on with $joined? '
        'Tell me however you like and I will note it down.';
  }
}

/// Turns "slept about 7 but skipped the walk" into values.
///
/// Clause-based rather than whole-sentence: people answer a multi-part question
/// in multiple parts, and the parts are separated by exactly the words you would
/// expect. Each clause is matched to at most one goal, so a number in one clause
/// can never be attributed to a metric mentioned in another.
abstract final class GoalReplyParser {
  const GoalReplyParser._();

  /// Words that mean "yes I did".
  static const _affirmative = {
    'yes', 'yeah', 'yep', 'yup', 'did', 'done', 'sure', 'definitely',
    'managed', 'completed', 'finished', 'aye', 'ya',
  };

  /// Words that mean "no I did not". Checked **before** any number, so
  /// "didn't do the 30 minutes" records a miss rather than thirty.
  static const _negative = {
    'no', 'nope', 'nah', 'not', 'never', 'missed', 'skipped', 'forgot',
    'failed', 'barely', 'nothing', 'zero', 'none',
  };

  /// Words that put the metric in the future rather than in the day just gone.
  ///
  /// "I'll walk it off tomorrow" is a plan, and a plan is neither a hit nor a
  /// miss — so these produce *nothing*, not a zero. Without them the number in
  /// an intention gets logged as if it had already happened.
  static const _intent = {
    'will', 'gonna', 'tomorrow', 'plan', 'planning', 'hope', 'hoping',
    'want', 'need', 'should', 'later', 'trying', 'try',
  };

  /// Irregular words for the metrics this app ships with.
  ///
  /// **Only the ones that cannot be derived.** "slept" is not reachable from
  /// "sleep" by any prefix rule, and no amount of generality will produce it,
  /// so the four built-ins keep a small vocabulary. Everything else — every
  /// habit a user invents — is matched by [Goal.isMentionedIn] against its own
  /// name, which is why adding a habit needs no entry here.
  static const Map<String, List<String>> _keywords = {
    Metric.sleep: ['sleep', 'slept', 'sleeping', 'bed', 'hours', 'hrs'],
    Metric.water: ['water', 'litre', 'litres', 'liter', 'liters', 'drank',
        'drink', 'glass', 'glasses', 'hydrat'],
    Metric.movement: ['walk', 'walked', 'walking', 'run', 'ran', 'running',
        'gym', 'move', 'moved', 'movement', 'exercise', 'exercised',
        'workout', 'steps', 'minutes', 'mins'],
    Metric.mood: ['mood', 'felt', 'feel', 'feeling', 'day was'],
  };

  static final RegExp _number = RegExp(r'(\d+(?:[.,]\d+)?)');
  /// Where one part of an answer ends and the next begins.
  ///
  /// The punctuation alternatives are guarded against digits on either side so
  /// that a decimal survives the split. `.` and `,` are both decimal points
  /// depending on where someone learned to write numbers, and cutting "about
  /// 6.5 hours" into "about 6" and "5 hours" logs five hours for a seven-hour
  /// night — a wrong number, silently, in the user's own record.
  static final RegExp _clauseSplit = RegExp(r'\s*(?:'
      r'[,.;](?!\d)|(?<!\d)[,.;]'
      r'|\band\b|\bbut\b|\balthough\b|\bthough\b'
      r')\s*');

  /// Values found in [reply] for the goals that were [asked] about.
  ///
  /// Conservative by design — a goal with no clear answer is simply absent from
  /// the result rather than defaulted to zero. Recording a miss the user never
  /// claimed is worse than recording nothing: it breaks a streak they earned.
  static List<LoggedValue> parse(String reply, List<Goal> asked) {
    if (asked.isEmpty) return const [];
    final text = reply.toLowerCase();
    final clauses = text
        .split(_clauseSplit)
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();

    final found = <String, double>{};

    for (final clause in clauses) {
      final goal = _goalFor(clause, asked);
      if (goal == null) continue;
      if (found.containsKey(goal.metric)) continue; // first mention wins
      final value = _valueIn(clause, goal, named: true);
      if (value != null) found[goal.metric] = value;
    }

    // A single goal asked, and an answer that never names it — "yeah", "7",
    // "not today". There is only one thing it can be about.
    if (found.isEmpty && asked.length == 1) {
      final value = _valueIn(text, asked.first, named: false);
      if (value != null) found[asked.first.metric] = value;
    }

    return [for (final e in found.entries) LoggedValue(e.key, e.value)];
  }

  /// The goal [clause] is talking about, or null.
  static Goal? _goalFor(String clause, List<Goal> asked) {
    // The irregulars first, then the general rule. Both passes run over every
    // goal before the next is tried, so a built-in's own vocabulary cannot be
    // stolen by a habit whose name happens to share a stem with it.
    for (final goal in asked) {
      final words = _keywords[goal.metric];
      if (words != null && words.any(clause.contains)) return goal;
    }
    for (final goal in asked) {
      if (goal.isMentionedIn(clause)) return goal;
    }
    return null;
  }

  /// What [clause] says the value was, or null when it is not clear.
  ///
  /// [named] says whether [clause] actually mentioned this goal's metric, which
  /// only the caller knows — the single-goal fallback passes text that never
  /// named it. It gates the last rule below, which would otherwise read a reply
  /// about something else entirely as a habit being done.
  static double? _valueIn(String clause, Goal goal, {required bool named}) {
    final words = clause.split(RegExp(r'[^a-z0-9.]+')).where((w) => w.isNotEmpty);

    // Negation first: "didn't manage the 30 minutes" is a miss, not thirty.
    if (words.any(_negative.contains) || clause.contains("n't")) return 0;

    // Then intent, which outranks any number in the same clause for the same
    // reason — but leaves no value at all rather than recording a miss.
    if (words.any(_intent.contains) ||
        clause.contains("'ll") ||
        clause.contains('going to')) {
      return null;
    }

    final match = _number.firstMatch(clause);
    if (match != null) {
      final raw = match.group(1)!.replaceAll(',', '.');
      final parsed = double.tryParse(raw);
      // A habit is done or not done; a number against one is noise.
      if (parsed != null && !goal.isBinary) return parsed;
      if (parsed != null && goal.isBinary) return 1;
    }

    if (words.any(_affirmative.contains)) {
      // "Yes" against a quantified goal means they hit the target; there is no
      // more precise reading available, and the alternative is discarding it.
      return goal.isBinary ? 1 : goal.target;
    }

    // "walked 20 minutes and meditated" — naming a habit in answer to a
    // question about that habit is the answer. Safe only because it is a
    // habit (there is no quantity to misread), only when the clause named it,
    // and only after negation and intent have taken the readings where saying
    // the word does not mean having done it.
    if (named && goal.isBinary) return 1;

    // A quantified goal gets no such licence: "slept well" is not seven hours.
    return null;
  }
}
