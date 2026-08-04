/// The cleaned form of a reply, plus what had to be removed to get there.
class SanitizedReply {
  final String text;

  /// Sentences dropped because the model had already said them verbatim.
  ///
  /// Non-zero means the model is looping. The caller uses this to abort
  /// generation rather than let it run to the token limit.
  final int droppedSentences;

  const SanitizedReply(this.text, this.droppedSentences);

  /// Whether what survived sanitising is long enough to be an answer.
  ///
  /// False means the reply was almost entirely padding that the repeat guard
  /// removed — on device this produced a companion turn reading `"I"`. The
  /// caller regenerates rather than showing the fragment.
  bool get isUsable => text.trim().length >= ReplySanitizer.minUsableLength;
}

/// Repairs text artifacts baked into the fine-tune by its training data, and
/// contains its tendency to loop.
///
/// Two defects, both from the weights rather than from anything the app does.
///
/// **Escaped punctuation.** The companion emits literal `_comma_` where a comma
/// belongs:
///
///     "Oh no_comma_ I'm sorry to hear that. What is causing you to feel that way"
///
/// That is a placeholder-escaping scheme leaking out of the CBT corpus — the
/// dataset was normalised with punctuation swapped for `_name_` tokens and never
/// un-escaped before training, so the model learnt `_comma_` *as the word for a
/// comma*.
///
/// **Degenerate repetition.** Given a prompt it has no content for, the model
/// repeats one stock sentence to fill the reply:
///
///     "I'm here to listen. I'm here to listen. I'm here to listen. I'm here to listen"
///
/// The runtime exposes no repetition penalty — `SamplerConfig` is only
/// `(topK, topP, temperature, seed)` — so this is caught after the fact instead.
///
/// Neither is fixable by prompting or sampling; the real fix is to clean the
/// corpus and retrain (ROADMAP P0.8). This class keeps both off the screen until
/// then.
class ReplySanitizer {
  const ReplySanitizer._();

  /// Only `_comma_` has actually been observed. The rest are the other outputs
  /// the same normaliser would produce, included because they cost nothing and a
  /// user typing `_semicolon_` into a journal is not a real risk.
  ///
  /// Terminal punctuation is deliberately *not* repaired — replies also come back
  /// missing their final `?`, but guessing punctuation would be inventing content
  /// the model did not produce.
  static const Map<String, String> _escapes = {
    '_comma_': ',',
    '_period_': '.',
    '_semicolon_': ';',
    '_colon_': ':',
    '_apostrophe_': "'",
    '_quote_': '"',
    '_exclamation_': '!',
    '_question_': '?',
    '_hyphen_': '-',
    '_dash_': '—',
    '_ellipsis_': '…',
    '_newline_': '\n',
  };

  /// Whitespace left stranded in front of punctuation once an escape that stood
  /// where the punctuation should be is substituted back in.
  static final RegExp _spaceBeforePunctuation = RegExp(r'\s+([,.;:!?])');

  /// The model's own control tokens, when they arrive as visible text.
  ///
  /// These are real vocabulary entries — `<|turn>`, `<turn|>`, `<|audio|>`,
  /// `<|image|>`, `<|think|>`, `<channel|>`, `<|tool_call|>` and friends — and
  /// the runtime normally consumes them. Normally. A tester's screenshot shows a
  /// chat bubble containing the literal text `<|audio>`, so a control token
  /// reaching the screen is not hypothetical, and nothing here used to stop it.
  ///
  /// Deliberately broad: it matches any `<|…>` or `<…|>` form rather than an
  /// enumerated list, because the interesting case is the token nobody thought
  /// to enumerate. Ordinary prose does not contain `<|` — a user typing an
  /// emoticon or a comparison never produces the pipe-and-angle pairing.
  static final RegExp _controlToken = RegExp(r'<\|[^<>]*\|?>|<[^<>]*\|>');

  /// Collapses whitespace left where a control token was removed.
  static final RegExp _runOfSpaces = RegExp(r'[ \t]{2,}');

  /// Markdown emphasis, unwrapped to the words inside it.
  ///
  /// The bubbles render plain text, so `*fully*` and `**I get it**` arrive on
  /// screen with their asterisks showing — both observed in the stress run. The
  /// persona already forbids headings and bullet lists; emphasis slips through
  /// because it is inline.
  ///
  /// Requires a non-space, non-asterisk character adjacent to each marker, so
  /// `2 * 3 * 4` and a lone `*` are untouched — only a genuine wrapped span
  /// matches.
  static final RegExp _emphasis =
      RegExp(r'(\*{1,2})(?!\s)([^*\n]+?)(?<!\s)\1');

  /// Shortest reply worth showing.
  ///
  /// Below this, sanitising has removed so much that what remains is not an
  /// answer — the stress run surfaced a companion turn whose entire content was
  /// `"I"`. Matches the floor `LexicalGuard` already applies for the same
  /// reason. Callers use [SanitizedReply.isUsable] to regenerate instead of
  /// showing a fragment.
  static const int minUsableLength = 15;

  /// Splits after `.`, `!` or `?` without consuming the mark.
  static final RegExp _sentenceBreak = RegExp(r'(?<=[.!?])\s+');

  /// Cleans a reply for display, discarding the diagnostics.
  static String clean(String raw, {bool streaming = false}) =>
      cleanDetailed(raw, streaming: streaming).text;

  /// The normalised sentences of [text], for comparing whole replies.
  ///
  /// Exposed so callers can tell `"I'm so glad you got promoted"` and `"Yes!
  /// I'm so glad you got promoted"` apart from genuinely different replies —
  /// they share their substantive sentence and differ only by an interjection,
  /// so comparing the raw strings treats them as distinct when they are not.
  static List<String> sentenceKeys(String text) => text
      .split(_sentenceBreak)
      .map(_key)
      .where((k) => k.isNotEmpty)
      .toList(growable: false);

  /// Cleans a reply and reports what was removed.
  ///
  /// Pass [streaming] while tokens are still arriving: a chunk boundary can land
  /// mid-escape or mid-sentence, and without this the user watches `_comm`
  /// appear and rewrite itself, or a duplicate sentence appear and vanish. Any
  /// trailing fragment that is still ambiguous is withheld until the next chunk
  /// resolves it.
  ///
  /// Idempotent, so it is safe to re-apply to the accumulated text on every
  /// chunk rather than tracking what has already been cleaned.
  static SanitizedReply cleanDetailed(String raw, {bool streaming = false}) {
    var text = raw;
    _escapes.forEach((token, replacement) {
      text = text.replaceAll(token, replacement);
    });

    // Before anything else: a control token is never content, and leaving one in
    // would let it be counted as part of a "sentence" below.
    text = text.replaceAll(_controlToken, ' ');
    text = text.replaceAllMapped(_emphasis, (m) => m[2]!);
    text = text.replaceAll(_runOfSpaces, ' ');

    text = text.replaceAllMapped(_spaceBeforePunctuation, (m) => m[1]!);
    if (streaming) text = _withoutPartialEscape(text);
    if (streaming) text = _withoutPartialControlToken(text);

    return _dropRepeatedSentences(text.trim(), streaming: streaming);
  }

  /// Keeps the first occurrence of each sentence and drops later verbatim
  /// repeats, wherever they appear rather than only when adjacent — the model
  /// alternates between two stock phrases as readily as it repeats one.
  static SanitizedReply _dropRepeatedSentences(
    String text, {
    required bool streaming,
  }) {
    if (text.isEmpty) return const SanitizedReply('', 0);

    final parts = text.split(_sentenceBreak);
    final kept = <String>[];
    final seen = <String>{};
    var dropped = 0;

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final key = _key(part);
      if (key.isEmpty) {
        kept.add(part);
        continue;
      }

      // While streaming, the last element may be an unfinished sentence. Hiding
      // it when it is the opening of something already said stops a duplicate
      // flickering into view one word at a time.
      final isTrailingFragment =
          streaming && i == parts.length - 1 && !_endsSentence(part);
      if (isTrailingFragment) {
        if (!seen.any((s) => s.startsWith(key))) kept.add(part);
        continue;
      }

      if (seen.add(key)) {
        kept.add(part);
      } else {
        dropped++;
      }
    }

    return SanitizedReply(kept.join(' ').trim(), dropped);
  }

  static bool _endsSentence(String part) {
    final t = part.trimRight();
    return t.endsWith('.') || t.endsWith('!') || t.endsWith('?');
  }

  /// Contractions expanded to a canonical two-word form before comparison.
  ///
  /// The corpus normaliser expanded these inconsistently — the same fine-tune
  /// returns both `"What's wrong"` and `"What is wrong"` — so without this a
  /// reply that alternates between the two forms of one sentence reads as two
  /// different sentences and survives the loop guard.
  static const Map<String, String> _contractions = {
    "i'm": 'i am',
    "i've": 'i have',
    "i'll": 'i will',
    "i'd": 'i would',
    "you're": 'you are',
    "you've": 'you have',
    "you'll": 'you will',
    "it's": 'it is',
    "that's": 'that is',
    "there's": 'there is',
    "what's": 'what is',
    "he's": 'he is',
    "she's": 'she is',
    "let's": 'let us',
    "don't": 'do not',
    "doesn't": 'does not',
    "didn't": 'did not',
    "isn't": 'is not',
    "aren't": 'are not',
    "wasn't": 'was not',
    "haven't": 'have not',
    "won't": 'will not',
    "can't": 'can not',
    'cannot': 'can not',
  };

  static final RegExp _contractionPattern =
      RegExp(r"\b(" + _contractions.keys.join('|') + r")\b");

  /// Comparison form: case-, punctuation- and contraction-insensitive, so
  /// `"I'm here to listen."` and `"I am here to listen"` compare equal.
  static String _key(String part) => part
      .toLowerCase()
      .replaceAllMapped(
          _contractionPattern, (m) => _contractions[m[1]] ?? m[0]!)
      .replaceAll(RegExp(r"[^a-z0-9\s]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Drops a trailing half-arrived control token, e.g. `"…thanks <|au"`.
  ///
  /// Same reasoning as [_withoutPartialEscape]: a chunk boundary can land inside
  /// a token, and without this the user watches `<|au` appear and then rewrite
  /// itself once the rest arrives.
  static String _withoutPartialControlToken(String text) {
    final start = text.lastIndexOf('<');
    if (start == -1) return text;
    // A complete token has already been removed above, so a surviving '<' with
    // no '>' after it is an unfinished one.
    return text.indexOf('>', start) == -1 ? text.substring(0, start) : text;
  }

  /// Drops a trailing `_`-prefixed fragment that is still a viable prefix of a
  /// known escape, e.g. `"Oh no_com"`. A trailing `_` on its own counts.
  static String _withoutPartialEscape(String text) {
    final start = text.lastIndexOf('_');
    if (start == -1) return text;

    final tail = text.substring(start);
    // A complete escape has already been substituted above, so anything left
    // here is either a partial escape or ordinary text containing "_".
    final viable = _escapes.keys.any((k) => k.startsWith(tail));
    return viable ? text.substring(0, start) : text;
  }
}
