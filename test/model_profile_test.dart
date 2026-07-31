import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/model_profile.dart';
import 'package:sanctuary/services/persona.dart';

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
      expect(instruction, contains('3 to 5 sentences'));
      expect(instruction, contains('Never diagnose'));
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
}
