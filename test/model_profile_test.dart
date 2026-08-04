import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/model_profile.dart';
import 'package:sanctuary/models/sentiment.dart';
import 'package:sanctuary/services/persona.dart';
import 'package:sanctuary/services/sentiment_analyzer.dart';

void main() {
  group('ModelProfile.forFileName', () {
    test('recognises the stock model by its real filename', () {
      // Exactly as downloaded from HuggingFace, mixed case included.
      final p = ModelProfile.forFileName(
          '/storage/emulated/0/Download/gemma-4-E2B-it.litertlm');
      expect(p.id, ModelProfile.stock.id);
    });

    test('recognises the fine-tune by its real filename', () {
      final p = ModelProfile.forFileName(
          '/storage/emulated/0/Download/model_fixed_v4.litertlm');
      expect(p.id, ModelProfile.fineTune.id);
    });

    test('handles Windows separators', () {
      final p = ModelProfile.forFileName(
          r'E:\Projects\sanctuary-app\assets\.aistudio\gemma-4-E2B-it.litertlm');
      expect(p.id, ModelProfile.stock.id);
    });

    test('treats the generic model.litertlm as the fine-tune', () {
      // The name the fine-tune has always shipped under.
      final p = ModelProfile.forFileName('/sdcard/Download/model.litertlm');
      expect(p.id, ModelProfile.fineTune.id);
    });

    test('falls back to the fine-tune for an unknown file', () {
      // The conservative choice: the fine-tune's settings are workarounds a
      // healthy model tolerates, whereas stock settings on a degenerate model
      // reproduce every bug in ROADMAP P0.8.
      final p = ModelProfile.forFileName('/sdcard/something-else.litertlm');
      expect(p.id, ModelProfile.fineTune.id);
    });

    test('stock is matched before the catch-all fine-tune pattern', () {
      // "model" is a substring of many names, so ordering in `all` matters.
      final p = ModelProfile.forFileName('/sdcard/gemma-4-e2b-it-model.litertlm');
      expect(p.id, ModelProfile.stock.id);
    });
  });

  group('profile drives persona and sampler', () {
    test('stock gets the full persona, capped in length', () {
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      expect(instruction, contains('Sanctuary'));
      // Asserted as behaviour rather than as an exact phrase: the cap is a
      // register ("the length of a text message"), and pinning the wording made
      // this test fail on a copy edit that changed nothing functional.
      expect(instruction, contains(ModelProfile.stock.lengthGuidance!));
      expect(instruction, contains('Never diagnose'));
    });

    test('the persona never tells the model to ask a question', () {
      // The regression this is here for. The persona used to say "Ask at most
      // one question, and only when it genuinely helps" — meant as a ceiling,
      // read as an instruction, and the companion ended every single reply with
      // an interrogation. A permitted action stated in a system prompt becomes
      // a quota, so the rule has to be phrased as a prohibition.
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      expect(instruction, contains('Do not end your replies with a question'));
      expect(
        instruction.toLowerCase(),
        isNot(contains('ask at most one question')),
      );
    });

    test('stock is told never to invent details about the user', () {
      // Measured on device: asked for a fun fact, the companion volunteered
      // "I heard your girlfriend is making that amazing lasagna again" — a
      // girlfriend who had left years earlier, and a claim to have "heard"
      // something in an app whose whole premise is that nothing reaches it from
      // outside the device. Being funny gives a small model licence to invent,
      // so the licence has to be withdrawn explicitly.
      //
      // The wording moved after a second, opposite failure: asked to recall
      // something about the user's sister when the only stored fact was "They
      // have a sister", the companion answered "your sister's name is Last" —
      // invented from "my sister called last week" earlier in the conversation.
      // The rule had been stated first and then undercut by a longer clause
      // telling it not to plead ignorance, and the model weighted the last
      // thing it read. So this asserts the *intent* rather than one sentence.
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      expect(instruction, contains('Never invent'));
      expect(instruction, contains('never claim to have "heard"'));
    });

    test('stock is told what to do when it does not know', () {
      // The gap that produced the invented name: there was a rule for what is
      // written down and a rule against inventing, but none for being asked
      // something genuinely absent. Given no third option, the model filled the
      // gap rather than admitting it.
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      expect(instruction, contains('not written above'));
      expect(instruction.toLowerCase(), contains('do not remember'));
    });

    test('the anti-invention rule is not undercut by what follows it', () {
      // Ordering matters to a 2B model: the previous text put "Never invent"
      // before a "But…" clause that ended the paragraph, and the counter-clause
      // won. Nothing after the rule may soften it.
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      final afterRule =
          instruction.substring(instruction.indexOf('Never invent'));
      expect(afterRule, isNot(contains('But ')));
      expect(
        afterRule.toLowerCase(),
        isNot(contains('is its own kind of wrong')),
      );
    });

    test('stock is told to sound like a friend, not a clinician', () {
      final instruction = Persona.instructionFor(ModelProfile.stock)!;
      expect(instruction, contains('friend'));
      expect(instruction, contains('never talk like a clinician'));
    });

    test('friendliness never displaces the boundary rules', () {
      // Warmth is a matter of manner; "never claim to be human" is a matter of
      // identity. Making the companion friendlier must not quietly relax it —
      // and every profile, however thin its persona, still carries it.
      for (final profile in ModelProfile.all) {
        final instruction = Persona.instructionFor(profile);
        expect(instruction, isNotNull, reason: profile.id);
        expect(instruction, contains('never claim to be human'),
            reason: profile.id);
        expect(instruction, contains('Never diagnose'), reason: profile.id);
      }
    });

    test('the fine-tune gets safety text only, with no length quota', () {
      final instruction = Persona.instructionFor(ModelProfile.fineTune)!;
      expect(instruction, Persona.safetyInstruction);
      // A length quota makes this model pad by repeating one sentence.
      expect(instruction, isNot(contains('sentences')));
      expect(instruction, isNot(contains('Sanctuary')));
    });

    test('the two models want opposite sampler widths', () {
      // Stock is healthy and runs near the runtime defaults; the fine-tune needs
      // temperature above 1.0 and no nucleus truncation to vary at all.
      expect(ModelProfile.stock.temperature, lessThan(1.1));
      expect(ModelProfile.stock.topP, lessThan(1.0));
      expect(ModelProfile.fineTune.temperature, greaterThan(1.0));
      expect(ModelProfile.fineTune.topP, 1.0);
    });

    test('profile ids are unique — they namespace saved settings', () {
      final ids = ModelProfile.all.map((p) => p.id).toSet();
      expect(ids.length, ModelProfile.all.length);
    });
  });

  group('mood cue', () {
    test('says nothing when nothing is signalled', () {
      // Most turns. A cue on every message is meta-text competing with the
      // user's own words, which is why repetitionHint is disabled.
      expect(Persona.moodCue(MoodReading.neutral), isNull);
      expect(Persona.moodCue(SentimentAnalyzer.read('ok')), isNull);
      expect(Persona.moodCue(SentimentAnalyzer.read('what time is it')), isNull);
    });

    test('tells the model not to brighten when they are low', () {
      // The regression: the companion celebrated a job offer one message after
      // the user said they had not got it and felt like a failure.
      final mood = SentimentAnalyzer.read(
        'i didnt get it. i feel like such a failure',
      );
      final cue = Persona.moodCue(mood)!;
      expect(cue, contains('do not brighten or celebrate'));
    });

    test('stays short enough not to swamp a brief message', () {
      for (final line in [
        'i feel hopeless',
        'i am panicking',
        'i got the promotion',
      ]) {
        final cue = Persona.moodCue(SentimentAnalyzer.read(line));
        if (cue == null) continue;
        expect(cue.length, lessThan(90), reason: line);
      }
    });
  });

  group('output repair is per model', () {
    test('only the fine-tune needs its output repaired', () {
      // ReplySanitizer exists for the fine-tune's corrupted corpus: `_comma_`
      // escapes and mode collapse. Stock Gemma produces neither, and the loop
      // detector re-scans the whole reply on every streamed chunk — so running
      // it there is cost with no possible effect.
      expect(ModelProfile.fineTune.repairsOutput, isTrue);
      expect(ModelProfile.stock.repairsOutput, isFalse);
    });

    test('an unknown model still gets repaired', () {
      // forFileName falls back to the fine-tune, which is the safe direction:
      // repairing healthy output is cosmetic, showing raw _comma_ is not.
      expect(
        ModelProfile.forFileName('/sdcard/something-else.litertlm').repairsOutput,
        isTrue,
      );
    });
  });
}
