import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import 'database_service.dart';

/// The conversation, on disk.
///
/// **Nothing here deletes on its own.** No rolling window, no retention policy,
/// no "keep the last N". The transcript is the relationship, and a companion
/// that silently drops last month's conversation is a companion that forgets
/// the user for its own convenience. Only [deleteMessage] and [deleteAll]
/// remove anything, and both are reachable only from an explicit user action.
///
/// This is separate from what the *model* sees. Context is 4096 tokens and the
/// transcript will outgrow it within a few sessions; the model gets a recent
/// window plus retrieved chunks (see `ChunkStore`), while the screen gets
/// everything.
class ChatStore {
  static final ChatStore instance = ChatStore._();

  ChatStore._();

  final DatabaseService _db = DatabaseService();

  Future<Database> get _database => _db.database;

  /// Bumped when the transcript is erased.
  ///
  /// Only on erasure, never on append: the chat view owns its own list and
  /// appends to it directly, so a notification per message would make every
  /// turn a full reload. This exists so that clearing from Settings — a
  /// different widget subtree entirely — reaches the conversation on screen.
  final ValueNotifier<int> cleared = ValueNotifier<int>(0);

  /// Appends a turn.
  Future<void> append(ChatMessage message) async {
    final db = await _database;
    await db.insert(
      'chat_messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Rewrites a turn's text.
  ///
  /// Used while a reply streams in: the row is written once when the slot is
  /// created and updated as tokens arrive, so an app killed mid-generation
  /// keeps the partial reply rather than losing the exchange.
  Future<void> updateText(String id, String text) async {
    final db = await _database;
    await db.update(
      'chat_messages',
      {'text': text},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// The whole conversation, oldest first.
  Future<List<ChatMessage>> all() async {
    final db = await _database;
    final rows = await db.query('chat_messages', orderBy: 'createdAt ASC');
    return rows.map(ChatMessage.fromMap).toList(growable: false);
  }

  /// The most recent [limit] turns, oldest first.
  ///
  /// Ordered descending in SQL to use the index, then reversed — the screen and
  /// the model both want chronological order.
  Future<List<ChatMessage>> recent({int limit = 200}) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatMessage.fromMap).toList(growable: false);
  }

  /// When the user last said something, or null if they never have.
  ///
  /// Drives the nudge timer. Deliberately the *user's* last turn: the
  /// companion's own reply, or a nudge it already sent, must not count as
  /// activity or it would keep resetting its own clock and never fire.
  Future<DateTime?> lastUserMessageAt() async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      columns: ['createdAt'],
      where: 'role = ?',
      whereArgs: [ChatRole.user.name],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.parse(rows.first['createdAt'] as String).toLocal();
  }

  /// When anything was last added, user or not.
  Future<DateTime?> lastActivityAt() async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      columns: ['createdAt'],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.parse(rows.first['createdAt'] as String).toLocal();
  }

  Future<int> count() async {
    final db = await _database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM chat_messages');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Removes one turn. User action only.
  Future<void> deleteMessage(String id) async {
    final db = await _database;
    await db.delete('chat_messages', where: 'id = ?', whereArgs: [id]);
  }

  /// Erases the whole conversation. User action only, and confirmed in the UI.
  ///
  /// Does not touch `memory_facts` or `memory_chunk`: clearing the transcript is
  /// not the same request as making the companion forget, and conflating them
  /// would delete a user's diary-derived profile because they wanted a tidy
  /// screen. "Forget everything" lives in the memory panel.
  Future<void> deleteAll() async {
    final db = await _database;
    await db.delete('chat_messages');
    cleared.value++;
  }
}
