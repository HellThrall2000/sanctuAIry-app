import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'model_profile.dart';

/// Everything that shapes the companion's voice, in one place.
///
/// The model is fine-tuned on a large corpus of CBT therapist conversations, so
/// it already knows how a therapist talks. A long, prescriptive system prompt
/// competes with that training — it pulls the model toward generic
/// instruction-following and away from the register it was tuned for. The
/// previous prompt literally said "Keep responses brief", which is most of why
/// replies came back as one flat line.
///
/// So the instruction here is deliberately thin (identity and safety only) and
/// the *register* is set by example instead, via [exemplars]. Demonstrating the
/// depth we want costs ~150 tokens and works far better than describing it.
///
/// Tune [exemplars] first when the voice is wrong. It moves length and warmth
/// more than any sampler setting does.
/// How much of the persona to put in front of the model. See [Persona.mode] for
/// the measurements behind the default.
enum PersonaMode {
  /// No system instruction at all. Most responsive to what the user said, but
  /// nothing constrains the model's claims.
  none,

  /// Safety constraints only, no framing or voice direction.
  safetyOnly,

  /// Identity, voice direction and safety. Produces session-opener boilerplate
  /// on this fine-tune.
  full,
}

class Persona {
  const Persona._();

  // ── A/B switches ────────────────────────────────────────────────────────
  // Both of these are additions that regressed the companion into emitting one
  // identical reply regardless of input. Kept as flags so the cause can be
  // isolated without hunting through call sites, and so either can be disabled
  // quickly if it regresses again.

  /// Seed the conversation with [exemplars].
  ///
  /// Suspect: the exemplars end on a model turn, and the companion may be
  /// continuing that pattern — producing a session opener — instead of
  /// attending to the newest user turn.
  static const bool useExemplars = false;

  /// Append [repetitionHint] to the user's turn.
  ///
  /// Prime suspect: the hint is ~90 characters of meta-instruction. Against an
  /// 11-character message like "who are you" it is ~90% of the prompt, so a 2B
  /// model plausibly answers the instruction rather than the question. The
  /// observed prompt lengths (5 → 104 → 107 → 146) are almost entirely hint.
  static const bool useRepetitionHint = false;

  /// The system instruction for [profile], or null to send none.
  ///
  /// How much persona a model can take is a property of the model, so it comes
  /// from [ModelProfile.personaMode]. Measured on-device against the fine-tune,
  /// same prompts, only this varying:
  ///
  /// | prompt | [PersonaMode.full] | [PersonaMode.none] |
  /// | --- | --- | --- |
  /// | ...something about the moon | *I'm so glad you reached out today* | *I'm sorry, what's wrong with you* |
  /// | talk about moon | *I'm glad you reached out today* | *I'm sorry, I'm not sure what you mean by that* |
  ///
  /// The full persona pushed that model into session-opener boilerplate instead
  /// of attending to the newest turn — it reads as the opening frame of a
  /// therapy session and a 2B model just continues the frame. Stock Gemma 4 E2B
  /// has no such problem and takes the full persona, so this is per-profile
  /// rather than a global switch.
  ///
  /// Whatever the mode, the crisis path does not depend on it: `CrisisGuard`
  /// bypasses the model entirely.
  static String? instructionFor(ModelProfile profile) =>
      switch (profile.personaMode) {
        PersonaMode.none => null,
        PersonaMode.safetyOnly => safetyInstruction,
        PersonaMode.full => _full(profile.lengthGuidance),
      };

  /// The single line that must survive regardless of what helps the voice.
  static const String safetyInstruction =
      'Never diagnose, never give medical advice, and never claim to be a '
      'substitute for professional care.';

  /// Identity, optional length guidance, and safety.
  ///
  /// The reflection line is worded carefully. It previously read "Reflect back
  /// the specific thing the user said, **in their own words**" — intended in the
  /// therapeutic sense of honouring the user's framing, but read by the model as
  /// an instruction to quote, which it followed exactly:
  ///
  ///     user:  my boss fired me
  ///     model: You said that your boss fired you, and that must be...
  ///
  /// Reflective listening is a genuine CBT technique and is worth keeping;
  /// parroting the user's sentence back at them is not, and it makes the
  /// companion sound like a form letter. Hence "in your own words", plus an
  /// explicit instruction not to quote.
  ///
  /// [lengthGuidance] is supplied per-profile and is genuinely double-edged. On
  /// stock E2B it is necessary — unconstrained it answers a one-line prompt with
  /// ~2,300 characters. On the fine-tune it is actively harmful: asked for a
  /// sentence count it pads to the number by repeating one sentence four times,
  /// so that profile passes null.
  static String _full(String? lengthGuidance) => '''
You are Sanctuary, a private CBT-informed companion. The user is talking to you on their own device; nothing they say ever leaves it.
${lengthGuidance == null ? '' : '$lengthGuidance '}Show that you have understood what the user means before you respond, but put it in your own words — do not quote their phrasing back to them. Ask at most one question, and only when it genuinely helps.

$safetyInstruction''';

  /// Two exchanges that demonstrate the register: reflective, concrete, one
  /// question at a time, willing to sit with ambiguity instead of solving it.
  ///
  /// These are seeded as real conversation turns, so they occupy history and
  /// count against the context budget. If context pressure becomes a problem,
  /// drop to the first exchange only.
  static List<LiteLmMessage> exemplars() => !useExemplars
      ? const []
      : [
        LiteLmMessage.user("i've been feeling really flat this week"),
        LiteLmMessage.model(
          "Flat is a particular word — it sounds less like sadness and more like "
          "the colour has drained out of things. When did you first notice it "
          "settling in? I'm curious whether it arrived alongside something, or "
          "whether it just crept up on you.",
        ),
        LiteLmMessage.user("i don't know, work maybe"),
        LiteLmMessage.model(
          "Maybe is worth sitting with rather than rushing to solve. If you "
          "picture a work day this week, is there a moment where the flatness is "
          "sharpest — walking in, a particular meeting, the journey home?",
        ),
      ];

  /// Whether the conversation should be seeded at all.
  static bool get hasExemplars => useExemplars;

  /// The opening fragment of a reply, normalised for comparison.
  ///
  /// Used to stop the companion reaching for the same phrase every turn — the
  /// runtime exposes no repetition penalty, so [repetitionHint] handles it in
  /// the prompt instead.
  static String? openerOf(String reply) {
    final cleaned = reply.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    if (cleaned.isEmpty) return null;
    final words = cleaned.split(RegExp(r'\s+')).take(5);
    return words.join(' ');
  }

  /// A one-line nudge appended to the user's turn when the companion has been
  /// repeating itself. Returns null when there is nothing to avoid, so we don't
  /// pay the tokens for it on every turn.
  static String? repetitionHint(Iterable<String> recentOpeners) {
    if (!useRepetitionHint) return null;
    final unique = recentOpeners.where((o) => o.trim().isNotEmpty).toSet();
    if (unique.isEmpty) return null;
    // Kept deliberately terse. The first version quoted every recent opener and
    // ran to ~90 characters, which swamped short user messages.
    return '(Open differently this time.)';
  }
}
