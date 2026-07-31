import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/memory_fact.dart';
import 'package:sanctuary/services/fact_extractor.dart';

List<MemoryFact> extract(String text) =>
    FactExtractor.extract(text, source: FactSource.chat);

MemoryFact? factFor(String text, String key) {
  final matches = extract(text).where((f) => f.key == key);
  return matches.isEmpty ? null : matches.first;
}

void main() {
  group('identity', () {
    test('learns a name from an explicit frame', () {
      expect(factFor('my name is padmanava', 'name')?.value, 'padmanava');
      expect(factFor('you can call me rob', 'name')?.value, 'rob');
    });

    test('learns age only when stated as age', () {
      expect(factFor('i am 34 years old', 'age')?.value, '34');
      expect(factFor('i am 5 minutes late', 'age'), isNull);
    });

    test('learns location', () {
      expect(factFor('i live in berlin', 'location')?.value, 'berlin');
      expect(factFor('i am from kolkata', 'origin')?.value, 'kolkata');
    });
  });

  group('work', () {
    test('learns occupation and employer separately', () {
      expect(factFor('i work as a nurse', 'occupation')?.value, 'nurse');
      expect(factFor('i work at siemens', 'employer')?.value, 'siemens');
    });
  });

  group('relationships', () {
    test('learns a capitalised name', () {
      expect(factFor('my wife Sara is coming', 'relationship:wife')?.value,
          'Sara');
      expect(factFor('my boss is Dan', 'relationship:boss')?.value, 'Dan');
    });

    test('learns a lowercase name given an explicit naming frame', () {
      expect(factFor('my dog is called rex', 'relationship:dog')?.value, 'rex');
      expect(factFor('my daughter named amy', 'relationship:daughter')?.value,
          'amy');
    });

    test('records the relation even without a name', () {
      expect(factFor('my therapist suggested journaling',
              'relationship:therapist')?.value,
          'therapist');
    });

    test('a verb after the relation is not a name', () {
      // No blocklist of verbs can be complete, so an uncapitalised bare word is
      // never taken as a name. "my therapist suggested" was the case that
      // caught this.
      expect(factFor('my wife left me', 'relationship:wife')?.value, 'wife');
      expect(factFor('my dad died last year', 'relationship:dad')?.value, 'dad');
      expect(factFor('my boss wants a word', 'relationship:boss')?.value,
          'boss');
    });

    test('records one fact per relation, named winning over bare', () {
      final facts = extract('my wife Sara called and my wife is upset');
      expect(facts.where((f) => f.key == 'relationship:wife').length, 1);
      expect(factFor('my wife Sara called and my wife is upset',
              'relationship:wife')?.value,
          'Sara');
    });

    test('does not treat every "my X" as a relationship', () {
      expect(extract('my head hurts'), isEmpty);
      expect(extract('my day was long'), isEmpty);
    });
  });

  group('preferences and constraints', () {
    test('learns likes and dislikes', () {
      expect(factFor('i love hiking', 'preference:hiking')?.value, 'hiking');
      expect(factFor('i hate crowds', 'aversion:crowds')?.value, 'crowds');
    });

    test('learns constraints, which are what should gate suggestions', () {
      expect(factFor('i am allergic to peanuts', 'allergy:peanuts')?.value,
          'peanuts');
      expect(
          factFor('i am afraid of roller coasters', 'fear:roller coasters')
              ?.value,
          'roller coasters');
      expect(factFor('i cannot walk long distances', 'cannot:walk long distances')
          ?.value,
          'walk long distances');
    });
  });

  group('precision — a wrong fact is worse than a missing one', () {
    test('ordinary conversation yields nothing', () {
      for (final line in [
        'i am sad',
        'my boss fired me today',
        'hello',
        'tell me something about the moon',
        'that sounds hard',
        'i got fired',
      ]) {
        expect(extract(line).where((f) => f.kind == FactKind.name), isEmpty,
            reason: '"$line" must not produce a name');
      }
    });

    test('"i am sad" is never mistaken for a name', () {
      expect(factFor('i am sad', 'name'), isNull);
      expect(factFor("i'm exhausted", 'name'), isNull);
    });

    test('distress phrasing does not become a constraint', () {
      // "i can't do this anymore" is a crisis signal, not a fact worth caching.
      expect(extract("i can't do this anymore")
          .where((f) => f.kind == FactKind.constraint), isEmpty);
      expect(extract("i can't take it").where((f) => f.kind == FactKind.constraint),
          isEmpty);
    });

    test('trailing clauses are trimmed', () {
      expect(factFor('i live in berlin but i hate it here', 'location')?.value,
          'berlin');
      expect(factFor('i love hiking because it clears my head',
              'preference:hiking')?.value,
          'hiking');
    });
  });

  group('bookkeeping', () {
    test('last mention wins within one message', () {
      final facts = extract('my name is bob, sorry, my name is rob');
      expect(facts.where((f) => f.key == 'name').length, 1);
      expect(factFor('my name is bob, sorry, my name is rob', 'name')?.value,
          'rob');
    });

    test('keeps the evidence so the user can be shown their own words', () {
      const line = 'i live in berlin';
      expect(factFor(line, 'location')?.evidence, line);
    });

    test('renders third-person text for the prompt', () {
      expect(factFor('my name is rob', 'name')?.text, 'Their name is rob.');
      expect(factFor('i am allergic to peanuts', 'allergy:peanuts')?.text,
          'They are allergic to peanuts.');
    });

    test('carries the source through', () {
      final journal = FactExtractor.extract('i live in berlin',
          source: FactSource.journal, sourceId: 'entry-1');
      expect(journal.single.source, FactSource.journal);
      expect(journal.single.sourceId, 'entry-1');
    });
  });
}
