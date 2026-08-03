import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/memory_scorer.dart';

void main() {
  group('stemming — the two halves of retrieval must agree', () {
    test('a query verb form meets the stored one', () {
      // The bug this exists for: a diary entry said "She was cheating on
      // someone else", the user asked "did she cheat on me", the strings did
      // not match, the chunk scored zero, and the companion said it did not
      // know something it had been told.
      expect(Bm25Scorer.stem('cheat'), Bm25Scorer.stem('cheating'));
      expect(Bm25Scorer.stem('hike'), Bm25Scorer.stem('hiking'));
      expect(Bm25Scorer.stem('move'), Bm25Scorer.stem('moved'));
      expect(Bm25Scorer.stem('worry'), Bm25Scorer.stem('worries'));
      expect(Bm25Scorer.stem('coaster'), Bm25Scorer.stem('coasters'));
    });

    test('does not collapse genuinely different words', () {
      expect(Bm25Scorer.stem('work'), isNot(Bm25Scorer.stem('worry')));
      expect(Bm25Scorer.stem('sleep'), isNot(Bm25Scorer.stem('sleeve')));
    });

    test('leaves double-s words alone', () {
      // "stress" must not become "stres".
      expect(Bm25Scorer.stem('stress'), 'stress');
    });

    test('is stable under repetition', () {
      // Applied to the index and the query separately, so it has to be
      // idempotent or the two sides drift apart.
      for (final w in ['cheating', 'hiking', 'worries', 'moved', 'stress']) {
        final once = Bm25Scorer.stem(w);
        expect(Bm25Scorer.stem(once), once, reason: w);
      }
    });
  });

  group('query terms', () {
    test('drops stopwords and short words', () {
      final terms = Bm25Scorer.terms_('did she cheat on me or not');
      expect(terms, contains('cheat'));
      expect(terms, isNot(contains('did')));
      expect(terms, isNot(contains('she')));
    });

    test('is left unstemmed for the FTS5 path', () {
      // FTS5 is built with tokenize='porter', which stems the query itself.
      // Pre-stemming would hand it "hik", which porter's "hike" never matches.
      expect(Bm25Scorer.terms_('hiking'), contains('hiking'));
    });

    test('an affectless query yields nothing to search for', () {
      expect(Bm25Scorer.terms_('and the it'), isEmpty);
      expect(Bm25Scorer.terms_(''), isEmpty);
    });
  });
}
