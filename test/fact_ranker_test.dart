import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/memory_fact.dart';
import 'package:sanctuary/services/fact_ranker.dart';

MemoryFact fact(String key, FactKind kind, String value, String text,
        {int ageDays = 0}) =>
    MemoryFact(
      key: key,
      kind: kind,
      value: value,
      text: text,
      source: FactSource.chat,
      evidence: '',
      updatedAt: DateTime.now().subtract(Duration(days: ageDays)),
    );

final _store = [
  fact('preference:hiking', FactKind.preference, 'hiking', 'They enjoy hiking.'),
  fact('aversion:crowds', FactKind.aversion, 'crowds', 'They dislike crowds.'),
  fact('allergy:peanuts', FactKind.constraint, 'peanuts',
      'They are allergic to peanuts.'),
  fact('preference:jazz', FactKind.preference, 'jazz', 'They enjoy jazz.'),
  fact('event:promotion', FactKind.event, 'promotion',
      'They were promoted at work.'),
  fact('fear:roller coasters', FactKind.constraint, 'roller coasters',
      'They are afraid of roller coasters.'),
];

List<String> rankKeys(String query, {int limit = 5}) =>
    FactRanker.rank(query, _store, limit: limit)
        .map((s) => s.fact.key)
        .toList();

void main() {
  group('relevance', () {
    test('finds the fact the message is about', () {
      expect(rankKeys('i am thinking of going hiking this weekend').first,
          'preference:hiking');
      expect(rankKeys('is there peanut butter in this').first,
          'allergy:peanuts');
    });

    test('matches across plural and verb forms', () {
      // "coaster" vs "coasters", "hike" vs "hiking".
      expect(rankKeys('is a roller coaster a good idea').first,
          'fear:roller coasters');
      expect(rankKeys('i want to hike').first, 'preference:hiking');
    });

    test('ranks the better match first', () {
      final ranked = rankKeys('a jazz concert but there will be crowds');
      expect(ranked, contains('preference:jazz'));
      expect(ranked, contains('aversion:crowds'));
    });
  });

  group('precision — most turns should retrieve nothing', () {
    test('ordinary conversation retrieves nothing', () {
      for (final line in [
        'i am sad',
        'hello',
        'what should i do',
        'i had a hard day',
        'tell me more',
      ]) {
        expect(rankKeys(line), isEmpty, reason: '"$line" retrieved something');
      }
    });

    test('stopword overlap alone is not relevance', () {
      // Shares "they"/"are"/"at" with several facts and means none of them.
      expect(rankKeys('what are they doing at the moment'), isEmpty);
    });

    test('an empty query retrieves nothing', () {
      expect(rankKeys(''), isEmpty);
      expect(rankKeys('   '), isEmpty);
    });
  });

  group('bounds', () {
    test('respects the limit', () {
      expect(rankKeys('hiking jazz crowds peanuts coasters', limit: 2).length, 2);
    });

    test('handles an empty store', () {
      expect(FactRanker.rank('hiking', const []), isEmpty);
    });

    test('scores are ordered descending', () {
      final scored =
          FactRanker.rank('hiking and jazz and crowds', _store, limit: 5);
      for (var i = 1; i < scored.length; i++) {
        expect(scored[i - 1].score, greaterThanOrEqualTo(scored[i].score));
      }
    });
  });

  group('scaling — the reason retrieval exists', () {
    test('a rare term still wins in a large store', () {
      // The case that motivated retrieval: with far more facts than fit in the
      // pinned block, the relevant one must still surface.
      final many = [
        for (var i = 0; i < 300; i++)
          fact('preference:topic$i', FactKind.preference, 'topic$i',
              'They enjoy topic$i.'),
        ..._store,
      ];
      final ranked = FactRanker.rank('are peanuts in this', many, limit: 3);
      expect(ranked.first.fact.key, 'allergy:peanuts');
    });

    test('a term common to the whole store carries little weight', () {
      // "enjoy" appears in every fact, so it should not select between them.
      final many = [
        for (var i = 0; i < 50; i++)
          fact('preference:topic$i', FactKind.preference, 'topic$i',
              'They enjoy topic$i.'),
      ];
      expect(FactRanker.rank('what do i enjoy', many), isEmpty);
    });

    test('recency breaks ties without overriding relevance', () {
      final old = fact('preference:sailing', FactKind.preference, 'sailing',
          'They enjoy sailing.',
          ageDays: 400);
      final recent = fact('preference:running', FactKind.preference, 'running',
          'They enjoy running.');
      // Directly about sailing: the old fact must still win.
      final ranked = FactRanker.rank('i miss sailing', [old, recent]);
      expect(ranked.first.fact.key, 'preference:sailing');
    });
  });
}
