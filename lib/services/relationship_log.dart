import 'package:sqflite/sqflite.dart';

import '../models/sentiment.dart';
import 'database_service.dart';

/// A thing that happened between the user and the companion.
enum MilestoneKind {
  firstConversation,
  diaryShared,
  hardNight,
  goodNews,
  returnedAfterAbsence;

  static MilestoneKind fromName(String name) => MilestoneKind.values
      .firstWhere((k) => k.name == name, orElse: () => goodNews);
}

class Milestone {
  final String id;
  final MilestoneKind kind;
  final String text;
  final DateTime createdAt;

  const Milestone({
    required this.id,
    required this.kind,
    required this.text,
    required this.createdAt,
  });
}

/// A subject the user keeps returning to.
class Topic {
  final String topic;
  final int mentions;
  final DateTime lastSeenAt;

  const Topic({
    required this.topic,
    required this.mentions,
    required this.lastSeenAt,
  });
}

/// Structured state about the *relationship*, as opposed to about the user.
///
/// `MemoryStore` answers "what do I know about this person" — name, city,
/// allergies. This answers "how have we been": where their mood has been
/// trending, what they keep circling back to, and what has actually happened
/// between them and the companion.
///
/// The distinction matters because the two decay differently. A fact like
/// *"allergic to peanuts"* is true until corrected. *"They have been low for
/// two weeks"* is only interesting while it is current, and stating it a month
/// later would be worse than saying nothing.
class RelationshipLog {
  static final RelationshipLog instance = RelationshipLog._();

  RelationshipLog._();

  final DatabaseService _db = DatabaseService();

  Future<Database> get _database => _db.database;

  /// How many recent readings define "lately".
  static const int trendWindow = 12;

  /// Below this, the companion has not seen enough to claim a trend.
  ///
  /// Three is the smallest number that can show a direction rather than a
  /// mood. Asserting "you've been low lately" off one bad afternoon is exactly
  /// the failure that makes a companion feel presumptuous.
  static const int minReadingsForTrend = 3;

  /// Topics below this are noise, not preoccupations.
  static const int minMentionsForTopic = 3;

  static const int maxTopicsInPrompt = 4;

  // ── Mood ────────────────────────────────────────────────────────────────

  /// Records a reading. Silently ignores unconvincing ones.
  ///
  /// Only [MoodReading.isSignal] readings are stored, so the trend is built
  /// from messages that actually carried feeling. Logging every "ok" would
  /// drag every average toward neutral and erase the signal entirely.
  Future<void> recordMood(MoodReading reading) async {
    if (!reading.isSignal) return;
    final db = await _database;
    await db.insert('mood_log', {
      'label': reading.label.name,
      'score': reading.valence,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// The last [trendWindow] readings, most recent first.
  Future<List<MoodReading>> recentMoods() async {
    final db = await _database;
    final rows = await db.query(
      'mood_log',
      orderBy: 'createdAt DESC',
      limit: trendWindow,
    );
    return rows
        .map((r) => MoodReading(
              label: MoodLabel.fromName(r['label'] as String),
              valence: (r['score'] as num).toDouble(),
              confidence: 1,
            ))
        .toList(growable: false);
  }

  /// One sentence about where the user has been, or null when there is not
  /// enough to say.
  Future<String?> moodTrend() async {
    final moods = await recentMoods();
    if (moods.length < minReadingsForTrend) return null;

    final mean =
        moods.map((m) => m.valence).reduce((a, b) => a + b) / moods.length;

    // Compare the newer half against the older half to get a direction. With
    // an odd count the middle reading is deliberately in neither.
    final half = moods.length ~/ 2;
    final newer = moods.take(half).map((m) => m.valence);
    final older = moods.skip(moods.length - half).map((m) => m.valence);
    final delta = (newer.reduce((a, b) => a + b) / half) -
        (older.reduce((a, b) => a + b) / half);

    final where = switch (mean) {
      < -0.5 => 'a hard stretch',
      < -0.15 => 'a low patch',
      < 0.15 => 'a fairly even stretch',
      < 0.5 => 'a reasonably good stretch',
      _ => 'a good stretch',
    };

    final direction = switch (delta) {
      > 0.3 => ', though things have been lifting recently',
      < -0.3 => ', and it has been getting heavier recently',
      _ => '',
    };

    return 'Over your recent conversations they have been going through '
        '$where$direction.';
  }

  // ── Topics ──────────────────────────────────────────────────────────────

  /// Increments the tally for each of [topics].
  Future<void> noteTopics(Iterable<String> topics) async {
    if (topics.isEmpty) return;
    final db = await _database;
    final now = DateTime.now().toUtc().toIso8601String();
    final batch = db.batch();
    for (final topic in topics.toSet()) {
      // Keyed by topic so a returning subject increments rather than
      // duplicating — the same reason memory_facts is keyed by slot.
      batch.rawInsert(
        '''
        INSERT INTO topic_tally(topic, mentions, lastSeenAt) VALUES(?, 1, ?)
        ON CONFLICT(topic) DO UPDATE SET
          mentions = mentions + 1,
          lastSeenAt = excluded.lastSeenAt
        ''',
        [topic, now],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Subjects the user returns to, most-mentioned first.
  Future<List<Topic>> favouriteTopics({int limit = maxTopicsInPrompt}) async {
    final db = await _database;
    final rows = await db.query(
      'topic_tally',
      where: 'mentions >= ?',
      whereArgs: [minMentionsForTopic],
      orderBy: 'mentions DESC, lastSeenAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => Topic(
              topic: r['topic'] as String,
              mentions: r['mentions'] as int,
              lastSeenAt:
                  DateTime.parse(r['lastSeenAt'] as String).toLocal(),
            ))
        .toList(growable: false);
  }

  // ── Milestones ──────────────────────────────────────────────────────────

  Future<void> recordMilestone(MilestoneKind kind, String text) async {
    final db = await _database;
    await db.insert('milestones', {
      'id': '${kind.name}:${DateTime.now().microsecondsSinceEpoch}',
      'kind': kind.name,
      'text': text,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Records [kind] only if it has never been recorded before.
  ///
  /// For the once-in-a-relationship events — the first conversation should be
  /// noted once, not on every cold start.
  Future<void> recordMilestoneOnce(MilestoneKind kind, String text) async {
    final db = await _database;
    final existing = await db.query(
      'milestones',
      where: 'kind = ?',
      whereArgs: [kind.name],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await recordMilestone(kind, text);
  }

  Future<List<Milestone>> milestones({int limit = 10}) async {
    final db = await _database;
    final rows = await db.query(
      'milestones',
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows
        .map((r) => Milestone(
              id: r['id'] as String,
              kind: MilestoneKind.fromName(r['kind'] as String),
              text: r['text'] as String,
              createdAt: DateTime.parse(r['createdAt'] as String).toLocal(),
            ))
        .toList(growable: false);
  }

  /// How long the two of them have been talking, or null before the first
  /// conversation is recorded.
  Future<Duration?> relationshipAge() async {
    final db = await _database;
    final rows = await db.query(
      'milestones',
      columns: ['createdAt'],
      orderBy: 'createdAt ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.now()
        .difference(DateTime.parse(rows.first['createdAt'] as String).toLocal());
  }

  // ── Prompt rendering ────────────────────────────────────────────────────

  /// The relationship block for the system instruction, or null when there is
  /// nothing worth saying yet.
  ///
  /// Kept to three short lines. This competes for the same context as the
  /// persona and the profile, and a long preamble is what pushed this model
  /// into answering the instructions instead of the user — see `Persona`.
  ///
  /// Framed as observation rather than instruction ("they have been…", not
  /// "be gentle because…"), because the model reliably follows the *shape* of
  /// what it is given: told to be gentle it announces its gentleness.
  Future<String?> promptBlock() async {
    final lines = <String>[];

    final age = await relationshipAge();
    if (age != null && age.inDays >= 7) {
      final weeks = age.inDays ~/ 7;
      lines.add(weeks >= 8
          ? 'You have been talking with this person for a few months.'
          : 'You have been talking with this person for '
              '$weeks ${weeks == 1 ? "week" : "weeks"}.');
    }

    final trend = await moodTrend();
    if (trend != null) lines.add(trend);

    final topics = await favouriteTopics();
    if (topics.isNotEmpty) {
      lines.add('Subjects they keep returning to: '
          '${topics.map((t) => t.topic).join(', ')}.');
    }

    if (lines.isEmpty) return null;
    return 'What you remember of your time together:\n${lines.join('\n')}';
  }

  /// Erases the relationship log. Paired with the memory panel's "forget
  /// everything", not with clearing the chat.
  Future<void> clear() async {
    final db = await _database;
    await db.delete('mood_log');
    await db.delete('topic_tally');
    await db.delete('milestones');
  }
}
