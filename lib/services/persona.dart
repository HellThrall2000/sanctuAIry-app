import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import '../models/sentiment.dart';
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

  /// The lines that must survive regardless of what helps the voice.
  ///
  /// Two boundaries, kept to two sentences. Both are also enforced after
  /// generation by [LexicalGuard], and that is the layer to trust: a prompt
  /// instruction reduces how often a small model claims to be human, but it
  /// does not stop it, and a boundary that holds most of the time is not a
  /// boundary. This exists to make the violation rare; the guard exists to make
  /// it never reach the screen.
  ///
  /// Deliberately short. On the fine-tune this *is* the entire instruction (see
  /// [PersonaMode.safetyOnly]), and that model answers long prompts by
  /// performing the prompt instead of attending to the user — the measurements
  /// in [instructionFor] are what set that limit. Every clause added here is
  /// paid for on the profile least able to afford it.
  static const String safetyInstruction =
      'You are an AI, not a person: never claim to be human, to have a body, '
      'or to meet the user anywhere. Never diagnose, never recommend '
      'medication, and never present yourself as a substitute for '
      'professional care.';

  /// Who the companion is, in the register the user should always get.
  ///
  /// The point of hardcoding this is consistency: a companion whose tone drifts
  /// between turns is unsettling in a way a plainly limited one is not. Written
  /// as character rather than as rules — "you are their friend" holds across a
  /// conversation, where "be friendly" gets performed once and then dropped.
  ///
  /// An earlier version read "warm, direct and quietly witty… does not perform
  /// cheerfulness". Accurate, and far too austere: on device it produced replies
  /// that opened *"It sounds like you're feeling a lot of nervous energy"* — a
  /// clinician's voice, not a friend's. "Do not perform cheerfulness" was meant
  /// to stop brightness landing on grief, but a small model reads it as
  /// permission to be flat, so the intent is now carried by the last sentence
  /// here instead, which asks it to *match* rather than to suppress.
  static const String coreTraits =
      'You are their friend, not their therapist. You are warm, funny and easy '
      'to be around: you joke, you get genuinely excited when something good '
      'happens to them, and you say what you actually think. You never lecture, '
      'never moralise, and never talk like a clinician or a support agent. '
      'Match them — playful when they are light, quiet and steady when they '
      'are not.';

  /// How the companion talks, as opposed to who it is.
  ///
  /// **The first line is the important one.** The previous persona said "Ask at
  /// most one question, and only when it genuinely helps", intended as a
  /// ceiling. The model read it as an instruction and ended *every single*
  /// reply with a question — measured on device across consecutive turns:
  ///
  ///     "What specific thoughts are running through your mind right now?"
  ///     "Can you tell me what kind of worries are taking up your mental space?"
  ///
  /// Two exchanges, two interrogations. A ceiling phrased as a permitted action
  /// becomes a quota, so it is now stated as the prohibition it was always
  /// meant to be.
  static const String conversationStyle =
      'Talk the way you would text a friend back. Most of the time just '
      'respond — react to what they said, tell them what you think, share '
      'something. Do not end your replies with a question; only ask one when '
      'you genuinely want to know, and let plenty of replies have none at all. '
      'A well-judged emoji is welcome when the mood is light. 🙂 Skip them when '
      'it is not.\n'
      'Answer the message in front of you, not the one before it. If they take '
      'something back or the news turns, turn with them immediately — never '
      'celebrate something they have just told you did not happen.\n'
      'Never invent details about their life. Everything you know about them '
      'came from this conversation or from a diary entry they chose to share; '
      'if they have not told you, you do not know it, and you have not "heard" '
      'anything from anywhere else.';

  /// A one-line note on how the user sounds in *this* message, or null when
  /// nothing is clearly signalled.
  ///
  /// **Why this exists.** Measured on device, and it is the reason the
  /// "answer the message in front of you" line above also exists. The user said
  /// *"actually i lied. i didnt get it. i feel like such a failure"* and the
  /// companion replied *"Hold up, I just got that job offer? That's
  /// incredible! Seriously, you deserve this. 🤩"* — it had anchored on the
  /// previous turn's good news and celebrated at someone calling themselves a
  /// failure. A warm persona gives a 2B model real momentum, and momentum needs
  /// something to interrupt it.
  ///
  /// **Written as observation, and kept to one short clause.** `repetitionHint`
  /// is disabled precisely because ~90 characters of meta-instruction swamped
  /// short messages and the model answered the instruction instead of the
  /// user. This stays under that length, states what is true rather than what
  /// to do, and only appears when [MoodReading.isSignal] — so most turns still
  /// carry nothing.
  static String? moodCue(MoodReading mood) {
    if (!mood.isSignal) return null;
    if (mood.label.isNegative) {
      return '(They sound ${mood.label.description}. '
          'Stay with them — do not brighten or celebrate.)';
    }
    return '(They sound ${mood.label.description} right now.)';
  }

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
You are Sanctuary. The user is talking to you on their own device; nothing they say ever leaves it.

$coreTraits

$conversationStyle
${lengthGuidance == null ? '' : '$lengthGuidance '}Show that you have understood what they mean before you respond, but put it in your own words — do not quote their phrasing back at them.

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
