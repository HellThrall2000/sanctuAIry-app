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
      version: 4,
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
  }

  /// Migrations are strictly additive.
  ///
  /// v1 -> v2 adds the memory cache. v2 -> v3 adds the conversation log,
  /// episodic chunks, the relationship log and upcoming events. v3 -> v4 adds
  /// `chat_messages.replyToId`, so a reply can name the message it answers.
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
