import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/plan.dart';
import 'database_service.dart';

/// The to-do list and the weekly routine.
///
/// One store for both because they are read together — "what does today look
/// like" needs the routine and the open items in the same breath, and splitting
/// them would mean two singletons racing for the same database handle to answer
/// one question.
class PlanStore {
  static final PlanStore instance = PlanStore._();

  PlanStore._();

  final DatabaseService _db = DatabaseService();
  final Uuid _uuid = const Uuid();

  Future<Database> get _database => _db.database;

  /// How many open items the prompt will ever name individually.
  ///
  /// The rest are counted, not listed. A companion that reads your whole list
  /// back is a worse version of the screen you are already looking at.
  static const int maxTodosInPrompt = 2;

  // ── To-dos ─────────────────────────────────────────────────────────────

  /// Adds an item and returns it, so the caller can show it without a re-read.
  /// Bumped after every write — see `WellnessLog.revision` for why the stores
  /// announce their own changes rather than leaving it to whoever wrote them.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Announces a write. Called *after* the row lands — see
  /// `WellnessLog._changed` for why announcing first is a race.
  void _changed() =>
      scheduleMicrotask(() => revision.value = revision.value + 1);

  Future<Todo> addTodo(
    String text, {
    DateTime? dueAt,
    TodoPriority priority = TodoPriority.normal,
  }) async {
    final todo = Todo(
      id: _uuid.v4(),
      text: text.trim(),
      createdAt: DateTime.now(),
      dueAt: dueAt,
      priority: priority,
    );
    final db = await _database;
    await db.insert('todos', todo.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _changed();
    return todo;
  }

  Future<void> updateTodo(Todo todo) async {
    final db = await _database;
    await db.update('todos', todo.toMap(), where: 'id = ?', whereArgs: [todo.id]);
    _changed();
  }

  Future<void> deleteTodo(String id) async {
    final db = await _database;
    await db.delete('todos', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Open items, most urgent first.
  ///
  /// Ordered by due date with undated items last, then by priority, then by
  /// age. Undated last because a to-do with no date is a someday, and letting
  /// those sit above a thing due tomorrow is how a list stops being trusted.
  Future<List<Todo>> openTodos() async {
    final db = await _database;
    final rows = await db.query(
      'todos',
      where: 'completedAt IS NULL',
      orderBy: 'dueAt IS NULL, dueAt ASC, priority DESC, createdAt ASC',
    );
    return rows.map(Todo.fromMap).toList(growable: false);
  }

  /// Items finished on a given local day, newest first — the "look what you
  /// did" list, which is the only reason completed items are kept at all.
  Future<List<Todo>> completedTodos({int limit = 20}) async {
    final db = await _database;
    final rows = await db.query(
      'todos',
      where: 'completedAt IS NOT NULL',
      orderBy: 'completedAt DESC',
      limit: limit,
    );
    return rows.map(Todo.fromMap).toList(growable: false);
  }

  Future<int> openCount() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM todos WHERE completedAt IS NULL',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Removes every ticked item. User action only.
  Future<void> clearCompleted() async {
    final db = await _database;
    await db.delete('todos', where: 'completedAt IS NOT NULL');
    _changed();
  }

  // ── Routine ────────────────────────────────────────────────────────────

  Future<RoutineBlock> addBlock({
    required String label,
    required int startMinute,
    int? endMinute,
    required Set<int> weekdays,
  }) async {
    final block = RoutineBlock(
      id: _uuid.v4(),
      label: label.trim(),
      startMinute: startMinute,
      endMinute: endMinute,
      weekdays: weekdays.isEmpty ? {1, 2, 3, 4, 5, 6, 7} : weekdays,
      createdAt: DateTime.now(),
    );
    final db = await _database;
    await db.insert('routine_block', block.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _changed();
    return block;
  }

  Future<void> deleteBlock(String id) async {
    final db = await _database;
    await db.delete('routine_block', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// The whole routine, in the order it happens.
  Future<List<RoutineBlock>> allBlocks() async {
    final db = await _database;
    final rows = await db.query('routine_block', orderBy: 'startMinute ASC');
    return rows.map(RoutineBlock.fromMap).toList(growable: false);
  }

  /// Just the blocks that fall on [day], in order.
  Future<List<RoutineBlock>> blocksFor(DateTime day) async {
    final all = await allBlocks();
    return all.where((b) => b.occursOn(day)).toList(growable: false);
  }

  /// The next block still to come today, or null once the day's routine is
  /// done. Used by the prompt so the companion can say "you have the gym at
  /// six" rather than reciting the whole week.
  Future<RoutineBlock?> nextBlockToday([DateTime? now]) async {
    final at = now ?? DateTime.now();
    final minute = at.hour * 60 + at.minute;
    final today = await blocksFor(at);
    for (final block in today) {
      if (block.startMinute >= minute) return block;
    }
    return null;
  }

  /// One line about today, or null.
  ///
  /// Deliberately thin. The routine and the list are on a screen the user can
  /// look at; what the companion needs is enough to say "before the gym" or "you
  /// still have the dentist to book" without reciting either. Open items are
  /// *counted*, with at most [maxTodosInPrompt] named — the list itself is not
  /// the companion's to read out.
  Future<String?> promptLine() async {
    final parts = <String>[];

    final next = await nextBlockToday();
    if (next != null) {
      parts.add('${next.label} at ${RoutineBlock.formatMinute(next.startMinute)}');
    }

    final open = await openTodos();
    if (open.isNotEmpty) {
      final named = open.take(maxTodosInPrompt).map((t) => t.text).join(', ');
      final rest = open.length - maxTodosInPrompt;
      parts.add(rest > 0
          ? 'still to do: $named, and $rest more'
          : 'still to do: $named');
    }

    if (parts.isEmpty) return null;
    return 'Today they have ${parts.join('; ')}.';
  }

  /// Erases the plan. Belongs in the app's "forget everything" path alongside
  /// `WellnessLog.clear`.
  Future<void> clear() async {
    final db = await _database;
    await db.delete('todos');
    await db.delete('routine_block');
  }
}
