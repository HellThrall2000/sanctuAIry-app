import 'persona.dart';

/// Everything that has to change when the underlying model changes.
///
/// Sanctuary is developed against Google's stock Gemma 4 E2B and ships against a
/// CBT fine-tune of it. The two need *opposite* settings in almost every
/// respect, all of it measured rather than assumed:
///
/// | | stock E2B | Sanctuary fine-tune |
/// | --- | --- | --- |
/// | reply length, same prompt | ~2,300 chars | 19 chars |
/// | needs length **capped** | yes | no — a length quota makes it repeat |
/// | follows a full persona | yes | no — emits session-opener boilerplate |
/// | distribution | normal | degenerate; needs wide sampling to vary at all |
///
/// So the profile carries the sampler, the persona mode and the length guidance
/// together. Switching models is then a one-line change (or automatic, by
/// filename) rather than a hunt through five files for the settings that have to
/// move in step.
class ModelProfile {
  /// Stable key. Used to namespace saved sampler settings, so tuning one model
  /// never leaks onto the other.
  final String id;

  /// Shown in the dev panel.
  final String label;

  /// Basename fragments that identify this model on disk, lower-cased. Matched
  /// as substrings so `gemma-4-E2B-it.litertlm` and `gemma4_e2b_it_q4.litertlm`
  /// both resolve.
  final List<String> fileNamePatterns;

  final PersonaMode personaMode;

  /// Appended to the persona when non-null. Only useful on a model that has
  /// enough to say to fill a length target — on the fine-tune a quota is filled
  /// by repeating one sentence, so this stays null there. See
  /// [Persona.instructionFor].
  final String? lengthGuidance;

  final double temperature;
  final int topK;
  final double topP;

  const ModelProfile({
    required this.id,
    required this.label,
    required this.fileNamePatterns,
    required this.personaMode,
    required this.lengthGuidance,
    required this.temperature,
    required this.topK,
    required this.topP,
  });

  /// Google's stock `gemma-4-E2B-it.litertlm`.
  ///
  /// Instruction-following is intact, so it gets the full persona — and it needs
  /// the length *capped*, because left alone it answers a one-line prompt with
  /// ~2,300 characters, which is unreadable in a chat bubble.
  ///
  /// Sampler is left near the runtime's own defaults. This model is not
  /// degenerate, so it does not need the wide sampling the fine-tune does, and
  /// widening it only costs coherence.
  static const stock = ModelProfile(
    id: 'stock-gemma4-e2b',
    label: 'Gemma 4 E2B (stock)',
    fileNamePatterns: ['gemma-4-e2b', 'gemma4-e2b', 'gemma_4_e2b'],
    personaMode: PersonaMode.full,
    lengthGuidance:
        'Keep replies to 3 to 5 sentences. Do not use headings or bullet lists.',
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
  );

  /// The Sanctuary CBT fine-tune.
  ///
  /// Every value here is a workaround for a measured defect — see ROADMAP P0.8.
  /// [PersonaMode.safetyOnly] because the full persona makes it answer
  /// substantive prompts with session-opener boilerplate; no [lengthGuidance]
  /// because a quota makes it repeat one sentence to fill the count; and wide
  /// sampling because its distribution is peaked enough that top-P 0.95 collapses
  /// to greedy.
  static const fineTune = ModelProfile(
    id: 'sanctuary-finetune',
    label: 'Sanctuary CBT fine-tune',
    fileNamePatterns: ['model_fixed', 'sanctuary', 'model'],
    personaMode: PersonaMode.safetyOnly,
    lengthGuidance: null,
    temperature: 1.2,
    topK: 64,
    topP: 1.0,
  );

  /// Order matters twice over.
  ///
  /// [forFileName] matches in this order, so the catch-all `model` pattern must
  /// come last or it swallows `gemma-4-e2b-it-model.litertlm`. And when several
  /// models are on the device at once, `LiteRtService.findLocalModels` sorts by
  /// this index to decide which loads by default — currently [stock], because
  /// development runs against it while the fine-tune is retrained (ROADMAP P0.8).
  /// Override per-device with `ModelPreference`.
  static const List<ModelProfile> all = [stock, fineTune];

  /// The profile for a model file, by name.
  ///
  /// Falls back to [fineTune] for an unrecognised file: it is the conservative
  /// choice, since its settings are workarounds that a healthy model tolerates,
  /// whereas the stock settings on a degenerate model reproduce every bug in
  /// ROADMAP P0.8.
  static ModelProfile forFileName(String path) {
    final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
    for (final profile in all) {
      if (profile.fileNamePatterns.any(name.contains)) return profile;
    }
    return fineTune;
  }

  static ModelProfile byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => fineTune);

  @override
  String toString() => '$label (temp=$temperature topK=$topK topP=$topP, '
      'persona=${personaMode.name})';
}

/// A model file found on the device, with the profile it should run under.
class LocatedModel {
  final String path;
  final ModelProfile profile;

  const LocatedModel(this.path, this.profile);

  @override
  String toString() => '$path [${profile.label}]';
}
