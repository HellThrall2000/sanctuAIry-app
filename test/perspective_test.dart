import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/perspective.dart';

String third(String s) => Perspective.toThird(s);

void main() {
  group('first person becomes third', () {
    test('the case that motivated it', () {
      expect(
        third('I have been swimming every morning at the lake before work.'),
        'They have been swimming every morning at the lake before work.',
      );
    });

    test('verbs that need agreement', () {
      expect(third('I am tired'), 'They are tired');
      expect(third('I was exhausted'), 'They were exhausted');
      expect(third("I'm not coping"), 'They are not coping');
      expect(third("I've been low"), 'They have been low');
      expect(third("I don't sleep well"), 'They do not sleep well');
      expect(third("I can't face it"), 'They cannot face it');
    });

    test('possessives and objects', () {
      expect(third('my sister called me'), 'their sister called them');
      expect(third('It helps me clear my head'),
          'It helps them clear their head');
    });

    test('keeps the original capitalisation position', () {
      // Sentence-initial stays capitalised; mid-sentence does not.
      expect(third('My head hurts'), 'Their head hurts');
      expect(third('sometimes my head hurts'), 'sometimes their head hurts');
    });
  });

  group('leaves everything else alone', () {
    test('text with no first person is unchanged', () {
      const s = 'Mornings at the lake';
      expect(third(s), s);
    });

    test('does not touch words that merely contain the pronouns', () {
      // "I" inside a word, and "me"/"my" as substrings.
      expect(third('Ill fitting timing myth'), 'Ill fitting timing myth');
      expect(third('the meeting was important'),
          'the meeting was important');
      expect(third('mystery solved'), 'mystery solved');
    });

    test('third person input is left as is', () {
      const s = 'They have been swimming every morning.';
      expect(third(s), s);
    });

    test('is idempotent', () {
      // Applied to already-converted text it must not drift.
      final once = third('I am tired and my head hurts');
      expect(third(once), once);
    });
  });

  group('the pronoun "I" is capitalised everywhere, so position decides', () {
    test('mid-sentence "I" does not become a capitalised "They"', () {
      // "my wife and I went" produced "their wife and They went": the bare
      // pronoun is always capitalised in English, so its own case says nothing
      // about where in the sentence it sits.
      expect(third('my wife and I went to the coast'),
          'their wife and they went to the coast');
      expect(third('Sarah and I argued'), 'Sarah and they argued');
      expect(third('I felt bad, and I said so'),
          'They felt bad, and they said so');
    });

    test('sentence-initial still capitalises', () {
      expect(third('I am tired'), 'They are tired');
      expect(third('I felt bad. I said so.'), 'They felt bad. They said so.');
    });

    test('a line starting after a bullet counts as a sentence start', () {
      // knowledgeBlock prefixes each line with "- ".
      expect(third('- I have been swimming'), '- They have been swimming');
    });

    test('a new line counts as a sentence start', () {
      expect(third('Mornings\nI swim early'), 'Mornings\nThey swim early');
    });
  });
}
