import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/memory_chunk.dart';

/// Ranks stored chunks against what the user just said.
///
/// An interface rather than a class because the ranking method is the part
/// most likely to change. Today it is BM25 over SQLite's FTS5 index; the
/// obvious upgrade is dense vectors from an embedding model, which
/// `docs/MEMORY_GRAPH_ARCHITECTURE.md` §6.1 deliberately defers ("add vectors
/// in Phase 2 only if measured recall justifies it"). When that happens it
/// implements this and nothing else moves.
///
/// The reason to defer is concrete: the vendored LiteRT plugin exposes
/// `createEngine`, `sendMessage` and `countTokens` and no embedding endpoint,
/// so vectors mean extending the native channel *and* shipping a second model
/// beside a 2.03 GB one.
abstract interface class MemoryScorer {
  /// The [limit] most relevant chunks, best first. Empty when nothing clears
  /// the implementation's relevance floor — which should be most turns.
  Future<List<ScoredChunk>> rank(String query, {int limit});
}

/// Lexical ranking over the FTS5 index.
///
/// ```
/// score = 0.70 · bm25_norm + 0.30 · recency_decay
/// ```
///
/// Recency is a modest term on purpose. A conversation from three months ago
/// that is squarely about the thing the user just raised should still beat
/// yesterday's small talk; recency is there to break ties between comparably
/// relevant chunks, not to outrank relevance.
class Bm25Scorer implements MemoryScorer {
  final Future<Database> Function() _db;

  const Bm25Scorer(this._db);

  /// Below this, a match is coincidence.
  ///
  /// Retrieval that fires every turn is worse than none: it fills the prompt
  /// with irrelevance and invites the companion to bring up things the user did
  /// not ask about. The same reasoning — and roughly the same effect — as
  /// `FactRanker.minScore`.
  static const double minScore = 0.22;

  /// Half-life of the recency term.
  static const double recencyHalfLifeDays = 90;

  /// Words too common to indicate relevance, and — because these go into an
  /// FTS5 `MATCH` expression — the ones most likely to match everything.
  static const _stopwords = {
    'a', 'about', 'am', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but',
    'by', 'can', 'could', 'did', 'do', 'does', 'for', 'from', 'get', 'got',
    'had', 'has', 'have', 'he', 'her', 'him', 'his', 'how', 'i', 'if', 'in',
    'is', 'it', 'its', 'just', 'like', 'me', 'more', 'much', 'my', 'no', 'not',
    'of', 'on', 'or', 'our', 'out', 'really', 'she', 'should', 'so', 'some',
    'that', 'the', 'their', 'them', 'then', 'there', 'they', 'this', 'to', 'up',
    'very', 'was', 'we', 'were', 'what', 'when', 'where', 'which', 'who', 'why',
    'will', 'with', 'would', 'you', 'your',
  };

  @override
  Future<List<ScoredChunk>> rank(String query, {int limit = 4}) async {
    final match = _toMatchExpression(query);
    if (match == null) return const [];

    final db = await _db();

    // bm25() returns *negative* numbers, better matches more negative, so
    // ascending order is best-first. Ask for more than `limit` because the
    // recency term can reorder the tail.
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.rawQuery(
        '''
        SELECT c.id, c.text, c.source, c.sourceId, c.createdAt,
               bm25(memory_chunk_fts) AS bm25
        FROM memory_chunk_fts
        JOIN memory_chunk c ON c.rowid = memory_chunk_fts.rowid
        WHERE memory_chunk_fts MATCH ?
        ORDER BY bm25 ASC
        LIMIT ?
        ''',
        [match, limit * 4],
      );
    } on DatabaseException {
      // A malformed MATCH expression is a bug in [_toMatchExpression], but it
      // must never take the conversation down with it — a failed recall is a
      // turn without extra context, not an error the user should see.
      return const [];
    }
    if (rows.isEmpty) return const [];

    // Normalise BM25 against the best hit in this result set. There is no
    // absolute scale for BM25, so the floor below is necessarily relative:
    // it asks "how close to the best match is this", not "is this good".
    final best = -((rows.first['bm25'] as num).toDouble());
    if (best <= 0) return const [];

    final now = DateTime.now();
    final scored = <ScoredChunk>[];
    for (final row in rows) {
      final chunk = MemoryChunk.fromMap(row);
      final bm25 = (-(row['bm25'] as num).toDouble()) / best;
      final ageDays = now.difference(chunk.createdAt).inHours / 24.0;
      final recency = pow(0.5, ageDays / recencyHalfLifeDays).toDouble();

      final score = 0.70 * bm25 + 0.30 * recency;
      if (score >= minScore) scored.add(ScoredChunk(chunk, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  /// Turns free text into a safe FTS5 `MATCH` expression, or null when there
  /// is nothing worth searching for.
  ///
  /// Every token is double-quoted. FTS5 treats bare `AND`, `OR`, `NOT`, `*`,
  /// `:`, `^` and parentheses as operators, so an unquoted user message
  /// containing any of them is a syntax error rather than a search — quoting
  /// makes every token a literal.
  static String? _toMatchExpression(String query) {
    final terms = terms_(query);
    if (terms.isEmpty) return null;
    return terms.map((t) => '"$t"').join(' OR ');
  }

  /// Content words, shared with [DartBm25Scorer] so both rankers agree on what
  /// a term is.
  /// Deliberately **not** stemmed. The FTS5 index is built with
  /// `tokenize='porter'`, which stems the query as well as the index, so
  /// passing raw words lets SQLite match `cheat` to `cheating` itself. Stemming
  /// here first would hand porter a non-word — our [stem] turns "hiking" into
  /// "hik" where porter produces "hike" — and the two would never meet.
  ///
  /// [DartBm25Scorer] has no porter and stems both sides itself.
  static List<String> terms_(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"['’]"), '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_stopwords.contains(w))
      .toSet()
      .take(12)
      .toList();

  /// Crude suffix stripping, matching `FactRanker._stem`.
  ///
  /// **This was missing, and it hid a diary entry from its own owner.** The
  /// entry said *"She was cheating on someone else"*; the user asked *"did she
  /// cheat on me"*; `cheat` and `cheating` are different strings, the chunk
  /// scored zero, and the companion answered that it did not know. `FactRanker`
  /// has stemmed since it was written — the chunk scorer simply never did, so
  /// the two halves of retrieval disagreed about what a word is.
  ///
  /// Applied to the index side as well as the query side, so both meet at the
  /// same stem. Over-stemming costs a false match; under-stemming costs a
  /// silent miss, which is far worse here.
  static String stem(String word) {
    var w = word;
    if (w.length > 4 && w.endsWith('ies')) {
      return '${w.substring(0, w.length - 3)}y';
    }
    if (w.length > 4 && w.endsWith('ing')) {
      w = w.substring(0, w.length - 3);
    } else if (w.length > 3 && w.endsWith('ed')) {
      w = w.substring(0, w.length - 2);
    } else if (w.length > 3 && w.endsWith('es')) {
      w = w.substring(0, w.length - 2);
    } else if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) {
      w = w.substring(0, w.length - 1);
    }
    // Makes hike/hiking and cheat/cheating agree: `-ing` removal yields "hik"
    // and "cheat", so the bare form has to lose a trailing `e` to meet it.
    if (w.length > 3 && w.endsWith('e')) w = w.substring(0, w.length - 1);
    return w;
  }
}

/// BM25 computed in Dart, for devices whose SQLite has no FTS5.
///
/// **Why this exists.** `sqflite` binds the platform's SQLite rather than
/// bundling one, and whether FTS5 was compiled in is the vendor's choice. On
/// the OnePlus Pad this app targets it is missing, so the query path had to
/// stop assuming it. The alternative — bundling SQLite via `sqlite3_flutter_libs`
/// — adds a native library beside `liblitertlm_jni.so`, and
/// `docs/MEMORY_GRAPH_ARCHITECTURE.md` §6.1 is explicit that overlapping native
/// stacks are "the single most likely way to break a working build".
///
/// Same formula SQLite's `bm25()` implements (k1 = 1.2, b = 0.75), over rows
/// loaded from `memory_chunk`. Viable because the corpus is small by
/// construction: one chunk per exchange, a few per journal entry. [_scanLimit]
/// bounds the work regardless.
class DartBm25Scorer implements MemoryScorer {
  final Future<Database> Function() _db;

  const DartBm25Scorer(this._db);

  static const double _k1 = 1.2;
  static const double _b = 0.75;

  /// Most recent chunks considered. Ranking 2000 rows in Dart is a few
  /// milliseconds; beyond that the cost stops being free and the older material
  /// is well past what a conversation refers back to.
  static const int _scanLimit = 2000;

  @override
  Future<List<ScoredChunk>> rank(String query, {int limit = 4}) async {
    // Stemmed, unlike the FTS5 path — there is no porter here to do it.
    final queryTerms =
        Bm25Scorer.terms_(query).map(Bm25Scorer.stem).toSet().toList();
    if (queryTerms.isEmpty) return const [];

    final db = await _db();
    final rows = await db.query(
      'memory_chunk',
      orderBy: 'createdAt DESC',
      limit: _scanLimit,
    );
    if (rows.isEmpty) return const [];

    // One pass to build the statistics BM25 needs.
    final docs = <MemoryChunk>[];
    final termCounts = <Map<String, int>>[];
    final lengths = <int>[];
    final docFreq = <String, int>{};

    for (final row in rows) {
      final chunk = MemoryChunk.fromMap(row);
      final tokens = _tokenize(chunk.text);
      final counts = <String, int>{};
      for (final t in tokens) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
      for (final t in counts.keys) {
        docFreq[t] = (docFreq[t] ?? 0) + 1;
      }
      docs.add(chunk);
      termCounts.add(counts);
      lengths.add(tokens.length);
    }

    final n = docs.length;
    final avgLen = lengths.reduce((a, b) => a + b) / n;

    var best = 0.0;
    final raw = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      var score = 0.0;
      for (final term in queryTerms) {
        final tf = termCounts[i][term];
        if (tf == null) continue;
        final df = docFreq[term] ?? 0;
        final idf = log(1 + (n - df + 0.5) / (df + 0.5));
        final norm = tf * (_k1 + 1) /
            (tf + _k1 * (1 - _b + _b * lengths[i] / avgLen));
        score += idf * norm;
      }
      raw[i] = score;
      if (score > best) best = score;
    }
    if (best <= 0) return const [];

    // Normalised against the best hit and blended with recency on exactly the
    // same terms as [Bm25Scorer], so switching ranker does not change which
    // chunks clear the floor.
    final now = DateTime.now();
    final scored = <ScoredChunk>[];
    for (var i = 0; i < n; i++) {
      if (raw[i] <= 0) continue;
      final ageDays = now.difference(docs[i].createdAt).inHours / 24.0;
      final recency =
          pow(0.5, ageDays / Bm25Scorer.recencyHalfLifeDays).toDouble();
      final score = 0.70 * (raw[i] / best) + 0.30 * recency;
      if (score >= Bm25Scorer.minScore) scored.add(ScoredChunk(docs[i], score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  /// All tokens, including repeats — BM25 needs term frequency, so this
  /// deliberately does not deduplicate the way the query side does.
  ///
  /// Stemmed with the same function as the query, or the two sides never meet.
  static List<String> _tokenize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"['’]"), '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !Bm25Scorer._stopwords.contains(w))
      .map(Bm25Scorer.stem)
      .toList(growable: false);
}
