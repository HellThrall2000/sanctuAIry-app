import 'package:sqflite/sqflite.dart';

import '../models/upcoming_event.dart';
import 'database_service.dart';
import 'event_extractor.dart';

/// What the user said is coming up.
class EventStore {
  static final EventStore instance = EventStore._();

  EventStore._();

  final DatabaseService _db = DatabaseService();

  Future<Database> get _database => _db.database;

  /// How long after an event has passed it is still natural to ask about it.
  ///
  /// A week. Beyond that "how did the interview go?" stops sounding attentive
  /// and starts sounding like a system that has only just noticed.
  static const Duration askWindow = Duration(days: 7);

  /// Extracts and stores any events in [text].
  Future<List<UpcomingEvent>> learnFrom(String text) async {
    final events = EventExtractor.extract(text);
    if (events.isEmpty) return const [];

    final db = await _database;
    final batch = db.batch();
    for (final event in events) {
      batch.insert(
        'upcoming_events',
        event.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    return events;
  }

  /// The event most worth asking about, or null.
  ///
  /// Prefers the most recently passed one: if two things happened, the fresher
  /// is the one on the user's mind. Events whose time has not yet come are not
  /// returned — asking "how did it go" before it has gone is the single most
  /// obvious way to reveal that nobody is really paying attention.
  Future<UpcomingEvent?> nextToAskAbout({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final db = await _database;
    final rows = await db.query(
      'upcoming_events',
      where: 'askedAfter = 0 AND dueAt IS NOT NULL AND dueAt <= ? AND dueAt >= ?',
      whereArgs: [
        at.toUtc().toIso8601String(),
        at.subtract(askWindow).toUtc().toIso8601String(),
      ],
      orderBy: 'dueAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UpcomingEvent.fromMap(rows.first);
  }

  /// An event still ahead of the user, for a "thinking of you before it"
  /// check-in.
  Future<UpcomingEvent?> nextUpcoming({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final db = await _database;
    final rows = await db.query(
      'upcoming_events',
      where: 'dueAt IS NOT NULL AND dueAt > ?',
      whereArgs: [at.toUtc().toIso8601String()],
      orderBy: 'dueAt ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UpcomingEvent.fromMap(rows.first);
  }

  /// Marks an event as followed up, so it is never asked about twice.
  Future<void> markAsked(String id) async {
    final db = await _database;
    await db.update(
      'upcoming_events',
      {'askedAfter': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<UpcomingEvent>> all() async {
    final db = await _database;
    final rows = await db.query('upcoming_events', orderBy: 'createdAt DESC');
    return rows.map(UpcomingEvent.fromMap).toList(growable: false);
  }

  Future<void> clear() async {
    final db = await _database;
    await db.delete('upcoming_events');
  }
}
