import 'package:sqflite/sqflite.dart';

import '../models/journal_entry.dart';
import '../models/memory_chunk.dart';
import 'database_service.dart';
import 'memory_scorer.dart';

/// Episodic memory: what was actually said, indexed for retrieval.
///
/// This is the half of "dynamic memory" that scales. `MemoryStore` keeps a
/// bounded, always-loaded profile — name, city, constraints — which works
/// precisely because it is bounded. Conversations are not bounded, so they are
/// chunked here and pulled in only when the current message calls for them.
class ChunkStore {
  static final ChunkStore instance = ChunkStore._();

  ChunkStore._();

  final DatabaseService _db = DatabaseService();

  Future<Database> get _database => _db.database;

  /// Chosen per device, not per build.
  ///
  /// FTS5 is absent from some Android SQLite builds — including the one this
  /// app is developed against — so the ranker is picked from what the platform
  /// actually provides. Both implement [MemoryScorer] and score on identical
  /// terms, so retrieval behaves the same either way; only where the arithmetic
  /// happens differs. This is the interface earning its keep.
  MemoryScorer get _scorer => DatabaseService.hasFts5
      ? Bm25Scorer(() => _database)
      : DartBm25Scorer(() => _database);

  /// Chunks shorter than this are not worth indexing.
  ///
  /// "ok", "thanks", "yeah" carry no retrievable content and would only add
  /// noise to BM25's document statistics.
  static const int minChunkLength = 40;

  /// Chunks longer than this are split.
  ///
  /// A retrieved chunk is pasted into a 4096-token context that also has to
  /// hold the persona, the profile and the history, so one runaway journal
  /// paragraph cannot be allowed to consume the whole episodic budget.
  static const int maxChunkLength = 900;

  /// How many chunks a single turn may recall.
  static const int maxRecall = 3;

  // ── Writing ─────────────────────────────────────────────────────────────

  /// Stores one completed exchange as a single chunk.
  ///
  /// The user's turn and the reply are kept together rather than separately:
  /// retrieved alone, *"I don't think I can face it"* is unusable, and the
  /// pair is what carries the meaning. Prefixed with speaker labels so the
  /// model can tell, when this is quoted back months later, who said what.
  Future<void> addExchange({
    required String userText,
    required String replyText,
  }) async {
    final text = 'They said: ${userText.trim()}\n'
        'You replied: ${replyText.trim()}';
    if (text.length < minChunkLength) return;
    await _insert(
      text: text,
      source: ChunkSource.chat,
      sourceId: null,
    );
  }

  /// Stores a condensed past session.
  ///
  /// Keyed by when the session ended, so closing the app repeatedly without
  /// talking rewrites one row rather than accumulating near-identical copies.
  Future<void> addSessionSummary({
    required String text,
    required DateTime endedAt,
  }) async {
    final db = await _database;
    await db.insert(
      'memory_chunk',
      MemoryChunk(
        id: 'session:${endedAt.toUtc().toIso8601String()}',
        text: text,
        source: ChunkSource.session,
        createdAt: endedAt,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The most recent session summaries, newest first.
  ///
  /// Carried in the system instruction so a returning user is not met by a
  /// companion starting from nothing.
  Future<List<MemoryChunk>> recentSessions({int limit = 3}) async {
    final db = await _database;
    final rows = await db.query(
      'memory_chunk',
      where: 'source = ?',
      whereArgs: [ChunkSource.session.name],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(MemoryChunk.fromMap).toList(growable: false);
  }

  /// Re-chunks a journal entry, replacing anything previously derived from it.
  ///
  /// Matches `MemoryStore.syncJournal`: withdrawing permission stops the entry
  /// being re-read, but does not delete chunks already made from it. The two
  /// stores have to agree, or a revoked entry would vanish from the profile
  /// while still being quotable through retrieval — the worst of both.
  ///
  /// Erasing is deliberate and explicit: deleting the entry, or "Forget all".
  Future<void> syncJournal(JournalEntry entry) async {
    if (!entry.allowAiAccess) return;
    await removeSource(entry.id);

    for (final piece in _split('${entry.title}. ${entry.content}')) {
      await _insert(
        text: piece,
        source: ChunkSource.journal,
        sourceId: entry.id,
      );
    }
  }

  Future<void> _insert({
    required String text,
    required ChunkSource source,
    String? sourceId,
  }) async {
    final db = await _database;
    final now = DateTime.now();
    await db.insert(
      'memory_chunk',
      MemoryChunk(
        id: '${source.name}:${now.microsecondsSinceEpoch}:${text.hashCode}',
        text: text,
        source: source,
        sourceId: sourceId,
        createdAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Paragraph-aware split, falling back to sentence boundaries for a
  /// paragraph that is itself too long.
  static List<String> _split(String text) {
    final out = <String>[];
    for (final para in text.split(RegExp(r'\n\s*\n'))) {
      final trimmed = para.trim();
      if (trimmed.length < minChunkLength) continue;
      if (trimmed.length <= maxChunkLength) {
        out.add(trimmed);
        continue;
      }
      // Accumulate sentences until the budget is reached, so a chunk never
      // ends mid-sentence — a half-sentence quoted back reads as the companion
      // misremembering.
      final buffer = StringBuffer();
      for (final sentence
          in RegExp(r'[^.!?]+[.!?]*').allMatches(trimmed).map((m) => m.group(0)!)) {
        if (buffer.length + sentence.length > maxChunkLength &&
            buffer.length >= minChunkLength) {
          out.add(buffer.toString().trim());
          buffer.clear();
        }
        buffer.write(sentence);
      }
      if (buffer.length >= minChunkLength) out.add(buffer.toString().trim());
    }
    return out;
  }

  // ── Reading ─────────────────────────────────────────────────────────────

  /// The chunks most relevant to [query]. Usually empty.
  Future<List<ScoredChunk>> recall(String query) =>
      _scorer.rank(query, limit: maxRecall);

  /// A prompt block quoting what the companion remembers, or null when nothing
  /// is relevant enough.
  ///
  /// Injected into the *user turn* rather than the system instruction, because
  /// the system instruction is fixed for the life of a conversation and this
  /// changes every message. Same mechanism `MemoryStore.recallBlock` uses.
  ///
  /// Framed as recollection, not as data. An earlier version of the sibling
  /// block ended with "do not mention that you have it written down", which the
  /// model read as an instruction to deny knowledge — it answered *"I don't
  /// have access to your personal information"*.
  Future<String?> recallBlock(String query) async {
    final hits = await recall(query);
    if (hits.isEmpty) return null;

    final buffer = StringBuffer(
      'Earlier conversations that seem related to this. '
      'Draw on them naturally if they help; ignore them if they do not:',
    );
    for (final hit in hits) {
      buffer.writeln();
      buffer.writeln('---');
      buffer.write(hit.chunk.text);
    }
    return buffer.toString();
  }

  /// The most recent chunks regardless of query — what a nudge reaches for
  /// when it wants to pick the thread back up.
  Future<List<MemoryChunk>> latest({int limit = 3}) async {
    final db = await _database;
    final rows = await db.query(
      'memory_chunk',
      where: 'source = ?',
      whereArgs: [ChunkSource.chat.name],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(MemoryChunk.fromMap).toList(growable: false);
  }

  Future<int> count() async {
    final db = await _database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM memory_chunk');
    return (rows.first['n'] as int?) ?? 0;
  }

  // ── Deleting ────────────────────────────────────────────────────────────

  Future<void> removeSource(String sourceId) async {
    final db = await _database;
    await db.delete(
      'memory_chunk',
      where: 'sourceId = ?',
      whereArgs: [sourceId],
    );
  }

  /// Drops every chunk. Part of "forget everything", not of clearing the chat.
  Future<void> clear() async {
    final db = await _database;
    await db.delete('memory_chunk');
  }
}
