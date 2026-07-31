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

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'sanctuary_secure_diaries.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
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
  }

  /// v1 -> v2 adds the memory cache. Existing journals are untouched: this is a
  /// user's private diary and a migration that drops it is unrecoverable.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createMemoryTable(db);
    }
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
