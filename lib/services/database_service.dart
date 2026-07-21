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
      version: 1,
      onCreate: _onCreate,
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
