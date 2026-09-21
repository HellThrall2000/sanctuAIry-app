import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/journal_entry.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;

  factory DatabaseService() {
    return _instance;
  }

  DatabaseService._internal();

  /// In-flight open, so concurrent callers share one.
  ///
  /// Several stores ask for the database at once on startup — the chat view,
  /// the nudge check and the memory cache all race. Without this each of them
  /// saw `_database == null` and started its own open; the FTS5 probe running
  /// twice in the logs is what exposed it. Two concurrent `onCreate` runs
  /// against one file is a much worse outcome than a duplicated log line.
  static Future<Database>? _opening;

  Future<Database> get database async {
    if (_database != null) return _database!;
    return _database = await (_opening ??= _initDatabase());
  }

  Future<Database> _initDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'sanctuary_secure_diaries.db');

    final db = await openDatabase(
      path,
      version: 8,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    await _tryCreateFtsIndex(db);
    return db;
  }

  /// Whether this device's SQLite has the FTS5 module.
  ///
  /// Null until [_tryCreateFtsIndex] has run.
  static bool? _fts5;

  /// True when episodic search can use SQLite's own BM25.
  static bool get hasFts5 => _fts5 ?? false;

  /// Builds the full-text index, if this device can.
  ///
  /// **FTS5 is not guaranteed on Android.** `sqflite` does not bundle SQLite —
  /// it binds the one in the platform, and whether FTS5 was compiled in is up
  /// to the vendor. On the OnePlus Pad this app targets it is absent, and the
  /// `CREATE VIRTUAL TABLE` threw `no such module: fts5` from inside `onCreate`,
  /// which rolled the entire migration back and left the app unable to open its
  /// own database. `docs/MEMORY_GRAPH_ARCHITECTURE.md` §6.1 assumes FTS5 is
  /// always there; it is not.
  ///
  /// So it lives outside the migration, runs on every open, and is allowed to
  /// fail. When it fails, `ChunkStore` ranks in Dart instead — see
  /// `DartBm25Scorer`. Running every time also means the index appears by
  /// itself if a system update ever brings FTS5 with it.
  static Future<void> _tryCreateFtsIndex(Database db) async {
    if (_fts5 != null) return;
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunk_fts USING fts5(
          text,
          content='memory_chunk',
          content_rowid='rowid',
          tokenize='porter unicode61'
        )
      ''');
      // Triggers are created only alongside a working index. Created without
      // it they would fire on every chunk insert and fail the write.
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memory_chunk_ai AFTER INSERT ON memory_chunk BEGIN
          INSERT INTO memory_chunk_fts(rowid, text) VALUES (new.rowid, new.text);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memory_chunk_ad AFTER DELETE ON memory_chunk BEGIN
          INSERT INTO memory_chunk_fts(memory_chunk_fts, rowid, text)
          VALUES ('delete', old.rowid, old.text);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memory_chunk_au AFTER UPDATE ON memory_chunk BEGIN
          INSERT INTO memory_chunk_fts(memory_chunk_fts, rowid, text)
          VALUES ('delete', old.rowid, old.text);
          INSERT INTO memory_chunk_fts(rowid, text) VALUES (new.rowid, new.text);
        END
      ''');

      // Backfill anything written while the index was unavailable.
      await db.execute('''
        INSERT INTO memory_chunk_fts(rowid, text)
        SELECT rowid, text FROM memory_chunk
        WHERE rowid NOT IN (SELECT rowid FROM memory_chunk_fts)
      ''');

      _fts5 = true;
    } catch (e) {
      debugPrint('FTS5 unavailable, ranking episodic memory in Dart: $e');
      _fts5 = false;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE journals(
        id TEXT PRIMARY KEY,
        title TEXT,
        content TEXT,
        date TEXT,
        allowAiAccess INTEGER
      )
    ''');
    await _createMemoryTable(db);
    await _createCompanionTables(db);
    await _createTrackerTables(db);
    await _createPlanTables(db);
  }

  /// Migrations are strictly additive.
  ///
  /// v1 -> v2 adds the memory cache. v2 -> v3 adds the conversation log,
  /// episodic chunks, the relationship log and upcoming events. v3 -> v4 adds
  /// `chat_messages.replyToId`, so a reply can name the message it answers.
  /// v4 -> v5 adds the wellness tracker: goals and one row per metric per day.
  /// v5 -> v6 adds the plan: a to-do list and a weekly routine. v6 -> v7 gives
  /// a goal a unit and a set of weekdays, so a habit can be "meditate 30
  /// minutes on weekdays" rather than a daily tick. v7 -> v8 lets a goal carry
  /// an emoji the user picked.
  /// Existing journals and facts are untouched: this is a user's private diary
  /// and a migration that drops it is unrecoverable.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createMemoryTable(db);
    }
    if (oldVersion < 3) {
      await _createCompanionTables(db);
    }
    if (oldVersion < 4) {
      await _addReplyToColumn(db);
    }
    if (oldVersion < 5) {
      await _createTrackerTables(db);
    }
    if (oldVersion < 6) {
      await _createPlanTables(db);
    }
    if (oldVersion < 7) {
      await _addGoalShapeColumns(db);
    }
    if (oldVersion < 8) {
      await _addGoalEmojiColumn(db);
    }
  }

  /// Adds `goals.emoji` to a database created before v8.
  ///
  /// Same guarded shape as the two migrations above, for the same reason:
  /// `ALTER TABLE` has no `IF NOT EXISTS`, and a throwing migration takes the
  /// whole upgrade down with it. A goal with no emoji reads as null, which the
  /// card renders without one.
  static Future<void> _addGoalEmojiColumn(Database db) async {
    try {
      final columns = await db.rawQuery('PRAGMA table_info(goals)');
      final present = {for (final c in columns) c['name'] as String};
      if (present.contains('emoji')) return;
      await db.execute('ALTER TABLE goals ADD COLUMN emoji TEXT');
    } catch (e) {
      debugPrint('Could not add goal emoji; cards go without: $e');
    }
  }

  /// Adds `goals.unit` and `goals.weekdays` to a database created before v7.
  ///
  /// Same shape as [_addReplyToColumn], and for the same reason: `ALTER TABLE`
  /// has no `IF NOT EXISTS`, so the column is checked for first and the whole
  /// thing is swallowed on failure. A migration that throws takes the entire
  /// `onUpgrade` transaction with it and leaves the app unable to open its own
  /// database — losing a habit's unit is cosmetic, losing the diary is not.
  ///
  /// Both columns are nullable with no default on purpose. `Goal.fromMap`
  /// reads a null unit as the metric's default, which for a habit is "times" —
  /// exactly the tick it was before the column existed — so every existing row
  /// keeps meaning what it meant.
  static Future<void> _addGoalShapeColumns(Database db) async {
    try {
      final columns = await db.rawQuery('PRAGMA table_info(goals)');
      final present = {for (final c in columns) c['name'] as String};
      if (!present.contains('unit')) {
        await db.execute('ALTER TABLE goals ADD COLUMN unit TEXT');
      }
      if (!present.contains('weekdays')) {
        await db.execute('ALTER TABLE goals ADD COLUMN weekdays TEXT');
      }
    } catch (e) {
      debugPrint('Could not widen goals; habits stay daily ticks: $e');
    }
  }

  /// Adds `chat_messages.replyToId` to a database created before v4.
  ///
  /// Guarded and swallowed rather than left to throw. A migration that fails
  /// takes the whole `onUpgrade` transaction down with it and leaves the app
  /// unable to open its own database — which is exactly how the FTS5 index once
  /// bricked this schema, and the reason nothing failable is allowed in here.
  /// Losing the quoted-reply link is a cosmetic loss; losing the diary is not.
  static Future<void> _addReplyToColumn(Database db) async {
    try {
      final columns = await db.rawQuery('PRAGMA table_info(chat_messages)');
      final present = columns.any((c) => c['name'] == 'replyToId');
      if (present) return;
      await db.execute('ALTER TABLE chat_messages ADD COLUMN replyToId TEXT');
    } catch (e) {
      debugPrint('Could not add replyToId; replies will not quote: $e');
    }
  }

  /// Everything added in v5: the wellness tracker.
  ///
  /// **Deliberately only `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT
  /// EXISTS`.** No `ALTER`, no backfill, no `SELECT` from a table that may not
  /// exist, no virtual table, no trigger. See `_addReplyToColumn` for why:
  /// anything in here that can fail takes the whole migration transaction with
  /// it and leaves the app unable to open its own database. `IF NOT EXISTS` is
  /// also what lets this one helper serve both `_onCreate` and `_onUpgrade`.
  static Future<void> _createTrackerTables(Database db) async {
    // ── Goals ──────────────────────────────────────────────────────────────
    //
    // `id` is a *slot* key — 'goal:sleep', 'goal:habit:meditate' — not a
    // surrogate. Restating a goal corrects it in place rather than leaving two
    // contradictory targets, the same trick `memory_facts` uses to make the
    // profile self-correcting when someone changes their mind.
    //
    // `label` keeps the user's own words next to the parsed target, so the
    // prompt can say "sleep 7 hours" rather than reconstructing English from a
    // number and a unit.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        metric TEXT NOT NULL,
        target REAL NOT NULL,
        cadence TEXT NOT NULL,
        unit TEXT,
        weekdays TEXT,
        emoji TEXT,
        label TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        archivedAt TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_goal_active ON goals(archivedAt, createdAt)',
    );

    // ── One row per metric per local day ───────────────────────────────────
    //
    // The composite primary key makes logging an upsert rather than an append:
    // drinking water four times in a day is one row that grows, not four rows
    // to sum. That also makes a correction ("no, six hours") a replace.
    //
    // `day` is a LOCAL `yyyy-MM-dd` key — see `DayKey` for why it is not UTC.
    // It is zero-padded so it sorts lexicographically in date order and
    // `ORDER BY day DESC` needs no date parsing.
    //
    // `value` is REAL for everything, including booleans, which are stored as
    // 0.0 / 1.0. One column and one query path serves "slept 6.5 hours",
    // "walked 8000 steps" and "meditated: yes".
    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_metric(
        day TEXT NOT NULL,
        metric TEXT NOT NULL,
        value REAL NOT NULL,
        loggedAt TEXT NOT NULL,
        PRIMARY KEY (day, metric)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_metric_day ON daily_metric(day DESC)',
    );
  }

  /// Everything added in v6: the to-do list and the weekly routine.
  ///
  /// Same rule as `_createTrackerTables` — only `CREATE … IF NOT EXISTS`,
  /// nothing that can fail, so one helper safely serves `_onCreate` and
  /// `_onUpgrade` both.
  static Future<void> _createPlanTables(Database db) async {
    // ── To-dos ─────────────────────────────────────────────────────────────
    //
    // `completedAt` is a nullable timestamp rather than a boolean, so "what did
    // I finish today" is a query rather than a second column that can disagree
    // with the first.
    //
    // Nothing is deleted on completion. A ticked item stays until the user
    // clears it, because a list that empties itself gives back nothing for the
    // effort of having done the work.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS todos(
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        completedAt TEXT,
        dueAt TEXT,
        priority TEXT NOT NULL DEFAULT 'normal',
        createdAt TEXT NOT NULL
      )
    ''');
    // Open items first, then by when they are due — the order the list is
    // always read in, so the index matches the query rather than the schema.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_todo_open ON todos(completedAt, dueAt)',
    );

    // ── The weekly routine ─────────────────────────────────────────────────
    //
    // A repeating shape of the week, not a calendar. `weekdays` is a sorted
    // comma-joined list of 1-7 (Mon-Sun) — see `RoutineBlock` for why a set
    // beats a bitmask here.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS routine_block(
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        startMinute INTEGER NOT NULL,
        endMinute INTEGER,
        weekdays TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_routine_start ON routine_block(startMinute)',
    );
  }

  /// Everything added in v3: the conversation itself, the episodic index built
  /// from it, the relationship log, and the events a nudge can refer to.
  static Future<void> _createCompanionTables(Database db) async {
    // ── The conversation ───────────────────────────────────────────────────
    //
    // Until now the transcript lived only in a `List<ChatMessage>` on the chat
    // widget's state, so closing the app erased every conversation the user had
    // ever had. A companion that forgets the entire relationship on process
    // death is not a companion. Nothing here is ever deleted except by explicit
    // user action.
    //
    // `sentToModel` distinguishes turns the model actually saw from banners,
    // guard responses and nudges, which are on screen but were never in its
    // context. Replay and repeat detection depend on that distinction.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages(
        id TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        moodLabel TEXT,
        moodScore REAL,
        sentToModel INTEGER NOT NULL DEFAULT 1,
        replyToId TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chat_created ON chat_messages(createdAt)',
    );

    // ── Episodic memory ────────────────────────────────────────────────────
    //
    // Chunks of past conversation and journal text, searchable by BM25. Kept
    // separate from `memory_facts`: facts are slot-keyed and self-correcting,
    // chunks are append-only raw text that can be re-processed later.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_chunk(
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        source TEXT NOT NULL,
        sourceId TEXT,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chunk_created ON memory_chunk(createdAt DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chunk_source ON memory_chunk(source, sourceId)',
    );

    // ── Relationship log ───────────────────────────────────────────────────
    //
    // Structured state about the relationship rather than about the user:
    // where their mood has been trending, what they keep returning to, and what
    // has actually happened between them and the companion.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mood_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL,
        score REAL NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_mood_created ON mood_log(createdAt DESC)',
    );

    // Topic frequency. `topic` is the primary key so a returning subject
    // increments rather than duplicating — the same reason `memory_facts` is
    // keyed by slot.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS topic_tally(
        topic TEXT PRIMARY KEY,
        mentions INTEGER NOT NULL,
        lastSeenAt TEXT NOT NULL
      )
    ''');

    // Things that happened *in the relationship*: first conversation, a diary
    // shared, a hard night, a piece of good news.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS milestones(
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        text TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_milestone_created ON milestones(createdAt DESC)',
    );

    // ── Upcoming events ────────────────────────────────────────────────────
    //
    // What the user said is coming: an interview on Friday, an exam tomorrow.
    // This is what lets a check-in be "how did the interview go?" rather than
    // "just checking in", which is the difference between a companion and a
    // retention notification.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS upcoming_events(
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        rawWhen TEXT,
        dueAt TEXT,
        evidence TEXT NOT NULL,
        askedAfter INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_event_due ON upcoming_events(dueAt)',
    );
  }

  /// Facts the companion knows about the user.
  ///
  /// `key` is the primary key rather than a surrogate id, so re-learning the
  /// same slot replaces it. That is what keeps the profile self-correcting when
  /// someone moves city or changes job — an append-only table would accumulate
  /// contradictions and feed all of them to the model at once.
  static Future<void> _createMemoryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_facts(
        key TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        value TEXT NOT NULL,
        text TEXT NOT NULL,
        source TEXT NOT NULL,
        sourceId TEXT,
        evidence TEXT,
        updatedAt TEXT NOT NULL
      )
    ''');
    // The profile is read on every conversation start and rebuilt whenever a
    // journal's permission is revoked; both order by recency.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memory_updated ON memory_facts(updatedAt DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memory_source ON memory_facts(source, sourceId)',
    );
  }

  // Insert a new journal entry
  Future<void> insertEntry(JournalEntry entry) async {
    final db = await database;
    await db.insert(
      'journals',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Get all journal entries
  Future<List<JournalEntry>> getEntries() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('journals', orderBy: 'date DESC');
    return List.generate(maps.length, (i) {
      return JournalEntry.fromMap(maps[i]);
    });
  }

  // Update a journal entry
  Future<void> updateEntry(JournalEntry entry) async {
    final db = await database;
    await db.update(
      'journals',
      entry.toMap(),
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  // Delete a journal entry
  Future<void> deleteEntry(String id) async {
    final db = await database;
    await db.delete(
      'journals',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
