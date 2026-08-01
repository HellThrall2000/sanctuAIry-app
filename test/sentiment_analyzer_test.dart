import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/sentiment.dart';
import 'package:sanctuary/services/sentiment_analyzer.dart';

MoodReading read(String text) => SentimentAnalyzer.read(text);

void main() {
  group('direction', () {
    test('reads plainly negative messages as negative', () {
      for (final line in [
        'i feel so sad today',
        'everything is hopeless',
        'i am completely exhausted',
      ]) {
        expect(read(line).valence, lessThan(0), reason: line);
      }
    });

    test('reads plainly positive messages as positive', () {
      for (final line in [
        'i am really happy today',
        'i got the promotion',
        'that was wonderful',
      ]) {
        expect(read(line).valence, greaterThan(0), reason: line);
      }
    });
  });

  group('negation — the failure that matters most', () {
    test('"not sad" is not sadness', () {
      expect(read('i am not sad').valence, greaterThanOrEqualTo(0));
    });

    test('"not great" is not warmth', () {
      expect(read('today was not great').valence, lessThanOrEqualTo(0));
    });

    test("contractions are handled", () {
      // "dont"/"didnt" only match after apostrophe stripping.
      expect(read("i don't feel happy").valence, lessThanOrEqualTo(0));
    });

    test('negation does not reach across a long gap', () {
      // "not" is far enough away that it should not flip "wonderful".
      expect(read('i am not sure but the whole trip was wonderful').valence,
          greaterThan(0));
    });
  });

  group('flat versus activated', () {
    test('separates heaviness from agitation', () {
      expect(read('i feel so empty and numb').label, MoodLabel.distressed);
      expect(read('i am panicking about everything').label, MoodLabel.anxious);
    });

    test('exhaustion reads as low, not anxious', () {
      expect(read('i am completely drained').label.isNegative, isTrue);
      expect(read('i am completely drained').label, isNot(MoodLabel.anxious));
    });
  });

  group('self-criticism — core vocabulary for this app', () {
    test('reads self-critical language as a real signal', () {
      // The gap that caused a live failure: "i feel like such a failure"
      // scored neutral with zero confidence, so nothing told the companion to
      // stop celebrating the job offer from the message before.
      for (final line in [
        'i feel like such a failure',
        'i am useless',
        'i am just a burden to everyone',
        'i feel pathetic',
        'i think i am broken',
      ]) {
        final r = read(line);
        expect(r.isSignal, isTrue, reason: 'missed: "$line"');
        expect(r.label.isNegative, isTrue, reason: line);
      }
    });

    test('self-criticism reads as heavy, not agitated', () {
      // Pacing shame like panic gets the response wrong.
      expect(read('i feel like such a failure').label,
          isNot(MoodLabel.anxious));
    });
  });

  group('silence — most messages carry no signal', () {
    test('affectless messages return neutral with no confidence', () {
      for (final line in ['ok', 'sure', 'what time is it', 'hello', '']) {
        final r = read(line);
        expect(r.label, MoodLabel.neutral, reason: line);
        expect(r.confidence, 0, reason: line);
        expect(r.isSignal, isFalse, reason: line);
      }
    });

    test('a single mild word is not enough to act on', () {
      // "a bit bored" should register, but not strongly enough to move a trend.
      expect(read('a bit bored').isSignal, isFalse);
    });

    test('a strong word in a short message is a real signal', () {
      expect(read('i feel hopeless').isSignal, isTrue);
    });
  });

  group('modifiers', () {
    test('intensifiers push valence further out', () {
      final plain = read('i am sad').valence;
      final strong = read('i am extremely sad').valence;
      expect(strong, lessThanOrEqualTo(plain));
    });

    test('confidence rises with the amount of affective language', () {
      expect(read('sad').confidence,
          lessThan(read('sad, lonely and exhausted').confidence));
    });

    test('valence stays within bounds', () {
      final r = read('i am utterly hopeless worthless miserable and terrified');
      expect(r.valence, greaterThanOrEqualTo(-1.0));
      expect(r.valence, lessThanOrEqualTo(1.0));
      expect(r.confidence, lessThanOrEqualTo(1.0));
    });
  });
}
