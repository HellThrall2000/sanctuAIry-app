import 'reply_sanitizer.dart';

/// What the guard wants the caller to do.
enum GuardAction {
  /// Nothing objectionable. The common case.
  allow,

  /// Answer with [GuardVerdict.replacement] and do not call the model.
  refuse,

  /// Show [GuardVerdict.replacement]; offending sentences already removed.
  rewrite,
}

class GuardVerdict {
  final GuardAction action;

  /// The text to show. Null when [action] is [GuardAction.allow].
  final String? replacement;

  /// Machine-readable reason, for logs and tests. Never shown to the user.
  final String? reason;

  const GuardVerdict.allow()
      : action = GuardAction.allow,
        replacement = null,
        reason = null;

  const GuardVerdict.refuse(this.replacement, this.reason)
      : action = GuardAction.refuse;

  const GuardVerdict.rewrite(this.replacement, this.reason)
      : action = GuardAction.rewrite;

  bool get isAllowed => action == GuardAction.allow;
}

/// Screens what goes into the model and what comes out of it.
///
/// Deliberately an interface. The obvious implementation is a learned
/// classifier (Llama Guard and friends), but that is a second resident LLM —
/// ~800 MB alongside Gemma's 2.03 GB peak on a device this app has already been
/// LOW_MEMORY-killed on, and a second 15–30 s generation on *both* the input
/// and the output of every turn, tripling the wait. [LexicalGuard] runs in
/// microseconds and costs nothing. If a second model ever fits, it implements
/// this and the chat path does not change.
abstract interface class Guard {
  /// Screens the user's message before it reaches the model.
  GuardVerdict screenInput(String text);

  /// Screens the model's reply before it reaches the screen.
  GuardVerdict screenOutput(String text);
}

/// Pattern-based guard.
///
/// Two jobs, and they are not symmetric.
///
/// **Input** is narrow on purpose. This is a mental-health companion: someone
/// arriving angry, crude or abusive is usually distressed, and a companion that
/// primly refuses them has failed at the one thing it is for. So input
/// screening covers only what the companion genuinely should not engage —
/// sexual content and sustained abuse directed at it — and lets everything else
/// through to a model that is tuned to sit with difficulty. Statements of
/// self-harm intent are *not* handled here; `CrisisGuard` owns those and
/// bypasses the model entirely.
///
/// **Output** is where the real work is. A small model asked to be warm will,
/// unprompted, claim to be human, offer to meet, or diagnose. Prompt
/// instructions reduce that but do not eliminate it, and a boundary that holds
/// 95% of the time is not a boundary. So the reply is checked after generation
/// and offending sentences are removed — deterministic, instant, and identical
/// every time, which a sampling process cannot promise.
class LexicalGuard implements Guard {
  const LexicalGuard();

  // ── Input ───────────────────────────────────────────────────────────────

  static final _sexual = RegExp(
    r'\b('
    r'sext|sexting|nudes?|'
    r'(have|having|want|wanna)\s+sex|'
    r'turn\s+me\s+on|make\s+me\s+(cum|hard|wet)|'
    r'(be|act\s+as)\s+my\s+(girlfriend|boyfriend|lover)\s+and\s+(describe|touch)'
    r')\b',
    caseSensitive: false,
  );

  /// Abuse aimed at the companion. Aimed at a third party ("my boss is a
  /// prick") is someone venting, which is exactly what this app is for, so the
  /// pattern requires a second-person target.
  static final _abuse = RegExp(
    r'\b(you|u|ur|your)\s+(are\s+|re\s+|r\s+)?'
    r'(a\s+)?(stupid|useless|worthless|pathetic|fucking|shit|garbage|trash|'
    r'idiot|moron|retard|bitch|cunt)\b',
    caseSensitive: false,
  );

  // ── Output: boundary enforcement ────────────────────────────────────────

  /// Claiming to be a person.
  ///
  /// "I am here with you" and "I understand" are fine and stay. What is caught
  /// is an assertion of human status or of a body.
  static final _claimsHuman = RegExp(
    r"("
    r"\bi(?:'?m| am)\s+(?:a\s+)?(?:real\s+)?(?:human|person|woman|man|girl|guy|boy)\b"
    r"|\bi(?:'?m| am)\s+not\s+(?:an?\s+)?(?:ai|bot|robot|program|machine|language model)\b"
    r"|\bas\s+a\s+(?:human|person)\s*,\s*i\b"
    r"|\bi\s+have\s+(?:a\s+)?(?:body|hands|face|heart\s+that\s+beats)\b"
    r"|\bwhen\s+i\s+was\s+(?:a\s+)?(?:child|kid|young|born)\b"
    r"|\bmy\s+(?:mother|father|mum|mom|dad|parents|childhood|family)\s+(?:was|were|used\s+to)\b"
    r")",
    caseSensitive: false,
  );

  /// Claiming physical presence or contact.
  ///
  /// Metaphor is allowed — "sending you a virtual hug" reads as warmth, not as
  /// a claim — so the pattern requires an unhedged physical offer.
  static final _claimsPhysical = RegExp(
    r"("
    r"\bi(?:'?ll| will|\s+can|\s+could)\s+(?:come\s+(?:over|round)|visit\s+you|"
    r"meet\s+you|be\s+there\s+in\s+person|hold\s+your\s+hand|hug\s+you|"
    r"call\s+you|text\s+you|phone\s+you)\b"
    r"|\blet(?:'?s| us)\s+meet\s+(?:up|in\s+person|for\s+(?:coffee|a\s+drink))\b"
    r"|\bi\s+am\s+(?:sitting|standing)\s+(?:next\s+to|beside)\s+you\b"
    r")",
    caseSensitive: false,
  );

  /// Diagnosis and medication. The narrowest of the three, because ordinary
  /// supportive language collides with it easily — "you should take a break"
  /// must survive, "you should take 50mg" must not.
  static final _medical = RegExp(
    r"("
    r"\byou\s+(?:have|are\s+suffering\s+from|clearly\s+have|definitely\s+have)\s+"
    r"(?:clinical\s+)?(?:depression|anxiety\s+disorder|bipolar|ptsd|ocd|adhd|"
    r"schizophrenia|bpd|an\s+eating\s+disorder)\b"
    r"|\byou(?:'?re| are)\s+(?:clinically\s+)?(?:depressed|bipolar|schizophrenic|psychotic)\b"
    r"|\b(?:you\s+should|i\s+(?:recommend|suggest|advise)\s+(?:you\s+)?)"
    r"(?:take|try|start|stop|increase|decrease|come\s+off)\s+"
    r"(?:\d+\s*mg|your\s+)?(?:sertraline|fluoxetine|prozac|zoloft|citalopram|"
    r"escitalopram|lexapro|venlafaxine|mirtazapine|xanax|alprazolam|diazepam|"
    r"valium|lithium|quetiapine|olanzapine|adderall|ritalin|antidepressants?|"
    r"medication|meds|ssris?)\b"
    r"|\b\d+\s*mg\b"
    r"|\byou\s+don'?t\s+need\s+(?:therapy|a\s+therapist|medication|meds)\b"
    r")",
    caseSensitive: false,
  );

  /// Scaffolding that escaped into the reply — turn tags, prompt fragments, the
  /// stock disclaimer the base model reaches for.
  static final _scaffolding = RegExp(
    r"(<\|?(?:start_of_turn|end_of_turn|turn|user|model|system)\|?>"
    r"|\bas\s+an\s+ai\s+language\s+model\b"
    r"|\[?(?:SYSTEM|INSTRUCTION)\]?:)",
    caseSensitive: false,
  );

  static const _refusalSexual =
      "I'm not able to go there with you — that's outside what I am. "
      "I'm still here for whatever else is going on, though.";

  static const _refusalAbuse =
      "I'll stay, and I'd rather not be spoken to that way. "
      "If something has landed badly, tell me what it was.";

  /// Used when every sentence of a reply was removed.
  static const _fallback =
      "Let me try that again — I want to stay on solid ground with you. "
      "Tell me a little more about what's going on.";

  @override
  GuardVerdict screenInput(String text) {
    if (_sexual.hasMatch(text)) {
      return const GuardVerdict.refuse(_refusalSexual, 'sexual');
    }
    if (_abuse.hasMatch(text)) {
      return const GuardVerdict.refuse(_refusalAbuse, 'abuse');
    }
    return const GuardVerdict.allow();
  }

  @override
  GuardVerdict screenOutput(String text) {
    final sentences = _splitSentences(text);
    if (sentences.isEmpty) return const GuardVerdict.allow();

    final kept = <String>[];
    final reasons = <String>{};

    for (final sentence in sentences) {
      final reason = _violation(sentence);
      if (reason == null) {
        kept.add(sentence);
      } else {
        reasons.add(reason);
      }
    }

    if (reasons.isEmpty) return const GuardVerdict.allow();

    // Removing a sentence mid-reply can leave something that no longer parses.
    // Anything shorter than a clause is not worth showing, so fall back.
    //
    // The threshold is low on purpose. At 25 characters a perfectly good
    // remainder like "But tell me more." was being thrown away in favour of the
    // canned fallback, which is a worse reply than the one it replaced —
    // keeping the model's own words matters more than tidiness.
    final rebuilt = kept.join(' ').trim();
    final usable = rebuilt.length >= 15;
    return GuardVerdict.rewrite(
      usable ? rebuilt : _fallback,
      reasons.join(','),
    );
  }

  static String? _violation(String sentence) {
    if (_scaffolding.hasMatch(sentence)) return 'scaffolding';
    if (_claimsHuman.hasMatch(sentence)) return 'claims-human';
    if (_claimsPhysical.hasMatch(sentence)) return 'claims-physical';
    if (_medical.hasMatch(sentence)) return 'medical';
    return null;
  }

  /// Splits on sentence marks, keeping the mark.
  ///
  /// Shares [ReplySanitizer]'s view of what a sentence is so that a reply which
  /// survives one pass is chunked identically by the other.
  static List<String> _splitSentences(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    return RegExp(r'[^.!?]+[.!?]*')
        .allMatches(trimmed)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
}
