import 'dart:math';

import '../models/memory_fact.dart';

/// A fact with its relevance to a query.
class ScoredFact {
  final MemoryFact fact;
  final double score;

  const ScoredFact(this.fact, this.score);
}

/// Ranks stored facts against what the user just said.
///
/// **Why not FTS5.** `docs/MEMORY_GRAPH_ARCHITECTURE.md` specifies SQLite FTS5 +
/// BM25, and that is still right for `memory_chunk` — journal chunks are large,
/// numerous, and grow with every entry. The *fact* table is different: it is
/// small by construction, because facts are keyed by slot and re-learning a slot
/// replaces it. A few hundred rows rank in well under a millisecond in Dart, so
/// FTS5 would add a migration, write-time index syncing, a second code path and
/// an availability assumption to optimise something that is not a bottleneck.
/// When chunk retrieval lands (P1.5), FTS5 belongs there.
///
/// **Scoring.** Term overlap weighted by inverse document frequency, so matching
/// a rare word like "peanuts" counts for far more than matching "the". A fact's
/// [MemoryFact.value] is weighted above its surrounding phrasing, because that
/// is the part that carries meaning — matching "hiking" in *They enjoy hiking*
/// should beat matching "they".
class FactRanker {
  const FactRanker._();

  /// Words too common to indicate relevance. Matching one is noise, and without
  /// this "what should I do today" retrieves everything containing "do".
  static const _stopwords = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but', 'by', 'can',
    'could', 'did', 'do', 'does', 'for', 'from', 'get', 'got', 'had', 'has',
    'have', 'he', 'her', 'him', 'his', 'how', 'i', 'if', 'in', 'is', 'it',
    'its', 'just', 'me', 'my', 'no', 'not', 'of', 'on', 'or', 'our', 'out',
    'she', 'should', 'so', 'some', 'that', 'the', 'their', 'them', 'then',
    'there', 'they', 'this', 'to', 'up', 'was', 'we', 'were', 'what', 'when',
    'where', 'which', 'who', 'why', 'will', 'with', 'would', 'you', 'your',
    'am', 'about', 'really', 'very', 'much', 'more', 'like', 'want', 'feel',
  };

  /// Below this, a match is coincidence rather than relevance.
  ///
  /// Retrieval that fires on every turn is worse than none: it fills the prompt
  /// with irrelevant facts and invites the model to talk about them unprompted.
  /// Most turns should retrieve nothing.
  ///
  /// Calibrated against the floor case: a term present in *every* stored fact
  /// scores exactly 1.0 (its IDF collapses to the floor), so the threshold sits
  /// just above it. A term matching a fact's own value clears it comfortably.
  static const double minScore = 1.2;

  /// The [limit] most relevant facts from [candidates], best first.
  ///
  /// Returns empty when nothing clears [minScore], which is the common case.
  static List<ScoredFact> rank(
    String query,
    List<MemoryFact> candidates, {
    int limit = 5,
  }) {
    if (candidates.isEmpty) return const [];

    final queryTerms = _terms(query);
    if (queryTerms.isEmpty) return const [];

    // IDF over the fact store itself: a term shared by most facts says little
    // about which one is wanted.
    final docFreq = <String, int>{};
    final candidateTerms = <int, Set<String>>{};
    final valueTerms = <int, Set<String>>{};
    for (var i = 0; i < candidates.length; i++) {
      final f = candidates[i];
      final terms = _terms('${f.text} ${f.evidence}');
      candidateTerms[i] = terms;
      valueTerms[i] = _terms(f.value);
      for (final t in terms) {
        docFreq[t] = (docFreq[t] ?? 0) + 1;
      }
    }

    final n = candidates.length;
    final scored = <ScoredFact>[];
    for (var i = 0; i < n; i++) {
      var score = 0.0;
      for (final term in queryTerms) {
        if (!candidateTerms[i]!.contains(term)) continue;
        final idf = log((n + 1) / ((docFreq[term] ?? 0) + 1)) + 1.0;
        // The value is the fact's substance; matching it is worth more than
        // matching the sentence built around it.
        score += valueTerms[i]!.contains(term) ? idf * 2.0 : idf;
      }
      if (score <= 0) continue;

      // Gentle recency preference, enough to break ties between equally
      // relevant facts without letting a recent irrelevance outrank an old
      // match.
      final ageDays = DateTime.now().difference(candidates[i].updatedAt).inDays;
      score *= 1.0 + (0.1 / (1 + ageDays / 30.0));

      if (score >= minScore) scored.add(ScoredFact(candidates[i], score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  /// Lowercased word set with stopwords and one-character tokens removed.
  static Set<String> _terms(String text) => text
      .toLowerCase()
      .split(RegExp(r"[^a-z0-9']+"))
      .where((w) => w.length > 1 && !_stopwords.contains(w))
      .map(_stem)
      .toSet();

  /// Crude suffix stripping so "coasters" matches "coaster" and "hiking"
  /// matches "hike". Not a real stemmer — it only has to make plurals and
  /// common verb forms agree, and over-stemming costs a false match rather than
  /// a wrong answer.
  ///
  /// The trailing-`e` strip at the end is what makes hike/hiking agree: `-ing`
  /// removal yields "hik", so "hike" has to lose its `e` to meet it.
  static String _stem(String w) {
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
    if (w.length > 3 && w.endsWith('e')) w = w.substring(0, w.length - 1);
    return w;
  }
}
