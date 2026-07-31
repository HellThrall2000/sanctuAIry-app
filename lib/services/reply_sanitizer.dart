/// The cleaned form of a reply, plus what had to be removed to get there.
class SanitizedReply {
  final String text;

  /// Sentences dropped because the model had already said them verbatim.
  ///
  /// Non-zero means the model is looping. The caller uses this to abort
  /// generation rather than let it run to the token limit.
  final int droppedSentences;

  const SanitizedReply(this.text, this.droppedSentences);
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
    text = text.replaceAllMapped(_spaceBeforePunctuation, (m) => m[1]!);
    if (streaming) text = _withoutPartialEscape(text);

    return _dropRepeatedSentences(text, streaming: streaming);
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
