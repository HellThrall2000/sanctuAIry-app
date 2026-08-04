import 'package:flutter/foundation.dart';
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

  /// Stores what the user said in one exchange.
  ///
  /// **The companion's own reply is deliberately not stored.** It used to be —
  /// the pair went in together as `"They said: …\nYou replied: …"`, on the
  /// reasoning that retrieved alone *"I don't think I can face it"* is unusable
  /// and the pair carries the meaning. That reasoning was sound and the
  /// consequence was not: it made generated text retrievable as memory, and
  /// generated text can be wrong.
  ///
  /// Measured on device. From the ambiguous sentence *"My sister called last
  /// week"* — where "called" is both a naming frame and a verb — the model
  /// answered *"your sister's name is Last"*. That reply was then written here
  /// as a chunk, retrieved by BM25 on the next question about the sister, and
  /// fed back into the prompt as evidence. Asked again, the companion repeated
  /// it with more confidence: *"Your sister is named Last. 😊"*
  ///
  /// So a single mis-parse became a durable false memory that reinforced itself
  /// every time the subject came up. **Only the user's own words are ground
  /// truth**; what the companion said about them is inference, and inference
  /// must not be recalled as fact. If it needs its own recent words it has the
  /// conversation history, which is bounded and does not persist as memory.
  ///
  /// [replyText] is still accepted so call sites read as a complete exchange,
  /// and because the length floor should consider what was actually said, not
  /// what was stored.
  Future<void> addExchange({
    required String userText,
    required String replyText,
  }) async {
    final text = 'They said: ${userText.trim()}';
    if (text.length < minChunkLength) return;
    await _insert(
      text: text,
      source: ChunkSource.chat,
      sourceId: null,
    );
  }

  /// Removes chunks that recorded the companion's own replies.
  ///
  /// Existing installs already hold them, including — on the test device — a
  /// chunk asserting a sister's name the user never gave. Left in place they
  /// keep being retrieved, so the fix above only stops new ones being created;
  /// this clears the ones already written.
  ///
  /// Matches on the stored `"You replied:"` marker, which no user-authored
  /// chunk can contain: journal chunks carry their own prefix and chat chunks
  /// now carry only `"They said:"`.
  ///
  /// Returns how many were removed, for the log.
  Future<int> purgeGeneratedChunks() async {
    try {
      final db = await _db.database;
      return await db.delete(
        'memory_chunk',
        where: 'text LIKE ?',
        whereArgs: ['%You replied:%'],
      );
    } catch (e) {
      debugPrint('Could not purge generated chunks: $e');
      return 0;
    }
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

  /// Comparison form for deciding two chunks say the same thing — case,
  /// punctuation and whitespace insensitive.
  static String _contentKey(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> _insert({
    required String text,
    required ChunkSource source,
    String? sourceId,
  }) async {
    final db = await _database;
    final now = DateTime.now();

    // **Content-addressed, so saying the same thing twice stores one chunk.**
    //
    // The id used to include a microsecond timestamp, which made every insert
    // unique and let a repeated sentence accumulate. On the test device one
    // sentence — *"My sister called last week…"* — was stored **five times**,
    // and since retrieval returns up to [maxRecall] chunks the model could be
    // handed three copies of it in a single prompt.
    //
    // That is bad twice over. It spends the episodic budget restating one
    // thing, and it *amplifies* whatever that thing says: three identical
    // copies of a sentence the model already mis-parses ("sister called last"
    // read as a name) push it further, not less far.
    //
    // Duplicates also corrupt BM25 itself. The ranking assumes documents are
    // distinct — repeated text inflates document frequency and depresses the
    // IDF of exactly the terms that made the chunk worth keeping.
    //
    // Hashing the normalised text and letting `ConflictAlgorithm.replace` do
    // the work means a re-said sentence refreshes its timestamp instead of
    // adding a row. `sourceId` is part of the key so the same line in two
    // different journal entries stays two chunks.
    final key = '${_contentKey(text)}|${sourceId ?? ''}'.hashCode;
    await db.insert(
      'memory_chunk',
      MemoryChunk(
        id: '${source.name}:$key',
        text: text,
        source: source,
        sourceId: sourceId,
        createdAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Collapses chunks stored before insertion became content-addressed.
  ///
  /// Existing installs already hold the duplicates, and they keep being
  /// retrieved. Keeps the newest row of each identical text.
  ///
  /// Returns how many were removed, for the log.
  Future<int> purgeDuplicateChunks() async {
    try {
      final db = await _database;
      final rows = await db.query('memory_chunk',
          columns: ['id', 'text', 'sourceId'], orderBy: 'createdAt DESC');

      final seen = <String>{};
      final doomed = <String>[];
      for (final row in rows) {
        final key = '${_contentKey(row['text'] as String? ?? '')}'
            '|${row['sourceId'] ?? ''}';
        if (!seen.add(key)) doomed.add(row['id'] as String);
      }
      if (doomed.isEmpty) return 0;

      final marks = List.filled(doomed.length, '?').join(',');
      return await db
          .delete('memory_chunk', where: 'id IN ($marks)', whereArgs: doomed);
    } catch (e) {
      debugPrint('Could not purge duplicate chunks: $e');
      return 0;
    }
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
