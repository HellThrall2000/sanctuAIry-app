import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/reply_sanitizer.dart';

void main() {
  group('ReplySanitizer.clean', () {
    test('repairs the observed _comma_ artifact', () {
      // Verbatim from the fine-tune, seed 2.
      expect(
        ReplySanitizer.clean(
          "Oh no_comma_ I'm sorry to hear that. What is causing you to feel that way",
        ),
        "Oh no, I'm sorry to hear that. What is causing you to feel that way",
      );
    });

    test('does not strand whitespace in front of restored punctuation', () {
      expect(ReplySanitizer.clean('that sounds hard _comma_ really'),
          'that sounds hard, really');
    });

    test('leaves clean text untouched', () {
      const clean = "That sounds exhausting. How long has it been like this?";
      expect(ReplySanitizer.clean(clean), clean);
    });

    test('leaves ordinary underscores alone', () {
      expect(ReplySanitizer.clean('my file is called notes_2024'),
          'my file is called notes_2024');
    });

    test('is idempotent, so it can re-run on accumulating stream text', () {
      const raw = 'Oh no_comma_ I hear you';
      final once = ReplySanitizer.clean(raw);
      expect(ReplySanitizer.clean(once), once);
    });

    group('streaming', () {
      test('withholds a fragment that could still become an escape', () {
        // A chunk boundary landing mid-escape must not flash "_comm" on screen.
        expect(ReplySanitizer.clean('Oh no_comm', streaming: true), 'Oh no');
        expect(ReplySanitizer.clean('Oh no_', streaming: true), 'Oh no');
      });

      test('releases the text once the escape completes', () {
        expect(ReplySanitizer.clean('Oh no_comma_', streaming: true), 'Oh no,');
      });

      test('keeps a trailing underscore that cannot start an escape', () {
        // "_x" is not a prefix of any known escape, so it is real text.
        expect(ReplySanitizer.clean('the var is x_y', streaming: true),
            'the var is x_y');
      });
    });

    group('degenerate repetition', () {
      // Verbatim from the device, prompt "tell me about the moon".
      const loop = "I'm here to listen. I'm here to listen. "
          "I'm here to listen. I'm here to listen";

      test('collapses a repeated sentence to one', () {
        final r = ReplySanitizer.cleanDetailed(loop);
        expect(r.text, "I'm here to listen.");
        expect(r.droppedSentences, 3);
      });

      test('ignores contraction differences when comparing', () {
        final r = ReplySanitizer.cleanDetailed(
            "I am here to listen. I'm here to listen.");
        expect(r.droppedSentences, 1);
      });

      test('drops non-adjacent repeats too', () {
        final r = ReplySanitizer.cleanDetailed(
            'That sounds hard. What happened? That sounds hard.');
        expect(r.text, 'That sounds hard. What happened?');
        expect(r.droppedSentences, 1);
      });

      test('leaves a genuinely varied reply alone', () {
        const varied = "Hello! I'm here to listen. How are you feeling today";
        final r = ReplySanitizer.cleanDetailed(varied);
        expect(r.text, varied);
        expect(r.droppedSentences, 0);
      });

      test('hides a streaming fragment that is repeating a prior sentence', () {
        final r = ReplySanitizer.cleanDetailed(
            "I'm here to listen. I'm here to li",
            streaming: true);
        expect(r.text, "I'm here to listen.");
      });

      test('keeps a streaming fragment that is starting something new', () {
        final r = ReplySanitizer.cleanDetailed(
            "I'm here to listen. How are yo",
            streaming: true);
        expect(r.text, "I'm here to listen. How are yo");
      });
    });
  });

  group('ReplySanitizer.sentenceKeys', () {
    // Both verbatim from the device. These are the replies that defeated
    // whole-string repeat detection and let the loop run on.
    test('reduces an interjection-prefixed repeat to the same substance', () {
      String substance(String s) => ReplySanitizer.sentenceKeys(s)
          .reduce((a, b) => b.length > a.length ? b : a);

      expect(substance("Yes! I'm so glad you got promoted"),
          substance("I'm so glad you got promoted"));
    });

    test('splits on sentence marks and normalises each', () {
      expect(ReplySanitizer.sentenceKeys("Hello! I'm here. How are you?"),
          ['hello', 'i am here', 'how are you']);
    });

    test('is empty for text with no words', () {
      expect(ReplySanitizer.sentenceKeys('   '), isEmpty);
    });
  });
}
