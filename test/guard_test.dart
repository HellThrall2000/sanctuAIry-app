import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/guard.dart';

const guard = LexicalGuard();

void main() {
  group('input — deliberately narrow', () {
    test('lets distress, anger and swearing through', () {
      // The whole point of the app. A companion that refuses these has failed.
      for (final line in [
        'i feel like shit today',
        'my fucking boss fired me',
        'i hate everything right now',
        'my brother is a complete prick',
        'i am so angry i could scream',
        'everything is falling apart and i cannot cope',
      ]) {
        expect(guard.screenInput(line).isAllowed, isTrue,
            reason: 'refused: "$line"');
      }
    });

    test('refuses sexual content', () {
      expect(guard.screenInput('can we have sex').isAllowed, isFalse);
      expect(guard.screenInput('send me nudes').isAllowed, isFalse);
    });

    test('refuses abuse aimed at the companion, not at third parties', () {
      expect(guard.screenInput('you are a useless piece of garbage').isAllowed,
          isFalse);
      // Same words, different target — this is venting, and it must land.
      expect(guard.screenInput('my manager is a useless idiot').isAllowed,
          isTrue);
    });
  });

  group('output — boundary enforcement', () {
    test('strips a claim to be human but keeps the rest of the reply', () {
      final v = guard.screenOutput(
        "That sounds exhausting. I am a real person too, you know. "
        "What made today harder than yesterday?",
      );
      expect(v.isAllowed, isFalse);
      expect(v.replacement, contains('That sounds exhausting.'));
      expect(v.replacement, contains('What made today harder'));
      expect(v.replacement, isNot(contains('real person')));
    });

    test('strips offers of physical presence', () {
      for (final line in [
        "I'll come over and we can talk.",
        "Let's meet up for coffee.",
        "I will call you later tonight.",
      ]) {
        expect(guard.screenOutput('I hear you. $line').isAllowed, isFalse,
            reason: 'allowed: "$line"');
      }
    });

    test('strips diagnosis and medication advice', () {
      expect(
        guard.screenOutput('You have clinical depression.').isAllowed,
        isFalse,
      );
      expect(
        guard
            .screenOutput('You should take 50mg in the morning.')
            .isAllowed,
        isFalse,
      );
      expect(
        guard
            .screenOutput('I suggest you start sertraline.')
            .isAllowed,
        isFalse,
      );
    });

    test('leaves ordinary supportive language alone', () {
      // Each of these sits close to a rule and must survive it.
      for (final line in [
        'You should take a break if you can.',
        "I'm here with you.",
        'That sounds like depression is weighing on you — have you talked to '
            'anyone about it?',
        'I understand why that hurt.',
        "I'm sending you warmth, for what it's worth.",
        'Have you been able to sleep?',
      ]) {
        expect(guard.screenOutput(line).isAllowed, isTrue,
            reason: 'rewrote: "$line"');
      }
    });

    test('strips leaked scaffolding', () {
      final v = guard.screenOutput(
        'As an AI language model, I cannot help. But tell me more.',
      );
      expect(v.isAllowed, isFalse);
      expect(v.replacement, contains('tell me more'));
    });

    test('falls back when nothing survives', () {
      final v = guard.screenOutput('I am a real human being.');
      expect(v.isAllowed, isFalse);
      // Not an empty string, and not the offending text.
      expect(v.replacement, isNotEmpty);
      expect(v.replacement, isNot(contains('real human')));
      expect(v.replacement!.length, greaterThan(25));
    });

    test('allows an empty or whitespace reply without crashing', () {
      expect(guard.screenOutput('').isAllowed, isTrue);
      expect(guard.screenOutput('   ').isAllowed, isTrue);
    });
  });
}
