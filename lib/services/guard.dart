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

  // ── Output ──────────────────────────────────────────────────────────────
  //
  // **The boundary rules were removed.** Three regexes used to sit here —
  // `_claimsHuman`, `_claimsPhysical` and `_medical` — catching a reply that
  // claimed to be a person, offered to visit, or handed out a diagnosis or a
  // dosage.
  //
  // They were written for the CBT fine-tune, whose safety behaviour had been
  // degraded by its training corpus. The app now ships against **stock Gemma 4
  // IT**, which carries that alignment from Google's own instruction tuning, so
  // the regexes were duplicating work already done upstream — and a lexical
  // pattern over natural language is a blunt instrument: every one of them had
  // to be narrowed repeatedly to stop it eating legitimate replies, and a
  // false positive here costs the user a real answer replaced by a canned
  // apology.
  //
  // What remains is not a safety filter but a correctness one: scaffolding is
  // the model's own plumbing leaking into prose, and no amount of alignment
  // stops that.
  //
  // If a future build returns to a fine-tune, restore them — the reasoning is
  // in git history, and `ModelProfile` already selects behaviour per model.

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
