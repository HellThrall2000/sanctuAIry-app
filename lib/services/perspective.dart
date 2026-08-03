/// Rewrites what the user wrote about themselves into what the companion knows
/// about them.
///
/// **Why this is needed.** Diary text is stored in the user's own words — *"I
/// have been swimming every morning"* — and those words end up in a block
/// describing a third party. Left in the first person the model has to work out
/// whose "I" it is reading, and it gets it wrong: on device it answered good
/// news with *"Hold up, I just got that job offer?"*, having adopted the user's
/// voice as its own.
///
/// **A mechanical swap, not a paraphrase.** Only pronouns and the verbs that
/// must agree with them change; every other word is the user's. That keeps the
/// guarantee `NoteDigester` exists for — the companion can only be told things
/// the user actually wrote — while removing the ambiguity about who is
/// speaking.
abstract final class Perspective {
  /// Ordered, and the order matters: contractions and the verb forms that need
  /// agreement have to be handled before the bare pronoun, or "I am" becomes
  /// "They am".
  ///
  /// `byPosition` marks the rules built on the pronoun **I**, which English
  /// capitalises everywhere. Their own case says nothing about where they sit,
  /// so those are cased by position instead — without it, *"my wife and I
  /// went"* became *"their wife and They went"*. Every other rule
  /// (`my`, `me`, `mine`) capitalises normally and can be read directly.
  static final List<({RegExp pattern, String to, bool byPosition})> _rules = [
    // Contractions first — they contain the bare pronoun.
    //
    // The apostrophe is optional only where dropping it cannot collide with a
    // real word: "im" and "ive" are not words, but **"ill" and "id" are**, and
    // an optional apostrophe turned "Ill fitting" into "They will fitting".
    (pattern: _w(r"I['’]?m"), to: 'they are', byPosition: true),
    (pattern: _w(r"I['’]?ve"), to: 'they have', byPosition: true),
    (pattern: _w(r"I['’]ll"), to: 'they will', byPosition: true),
    (pattern: _w(r"I['’]d"), to: 'they would', byPosition: true),

    // Verbs that do not survive a straight pronoun swap.
    (pattern: _w(r'I\s+am'), to: 'they are', byPosition: true),
    (pattern: _w(r'I\s+was'), to: 'they were', byPosition: true),
    (pattern: _w(r"I\s+don['’]?t"), to: 'they do not', byPosition: true),
    (pattern: _w(r"I\s+can['’]?t"), to: 'they cannot', byPosition: true),
    (pattern: _w(r"I\s+won['’]?t"), to: 'they will not', byPosition: true),
    (pattern: _w(r"I\s+wasn['’]?t"), to: 'they were not', byPosition: true),

    // Possessives and objects.
    (pattern: _w('my'), to: 'their', byPosition: false),
    (pattern: _w('mine'), to: 'theirs', byPosition: false),
    (pattern: _w('myself'), to: 'themselves', byPosition: false),
    (pattern: _w('me'), to: 'them', byPosition: false),

    // The bare pronoun, last.
    (pattern: _w('I'), to: 'they', byPosition: true),
  ];

  static RegExp _w(String body) =>
      RegExp('\\b(?:$body)\\b', caseSensitive: false);

  /// Whether the character run ending at [index] puts a word at a sentence
  /// start.
  static bool _atSentenceStart(String text, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final c = text[i];
      if (c == ' ' || c == '\t') continue;
      if (c == '\n' || c == '\r') return true;
      // A sentence mark, or a bullet the block adds in front of a line.
      return '.!?…•-'.contains(c);
    }
    return true; // nothing before it
  }

  /// [text] as something the companion knows about the user.
  ///
  /// Text with no first-person pronouns is returned unchanged, which is the
  /// common case for a title like "Mornings at the lake".
  static String toThird(String text) {
    var out = text;
    for (final rule in _rules) {
      out = out.replaceAllMapped(rule.pattern, (m) {
        final upper = rule.byPosition
            ? _atSentenceStart(out, m.start)
            : _startsUpper(m.group(0)!);
        return upper
            ? rule.to[0].toUpperCase() + rule.to.substring(1)
            : rule.to;
      });
    }
    return out;
  }

  static bool _startsUpper(String word) {
    final first = word[0];
    return first == first.toUpperCase() &&
        first.toLowerCase() != first.toUpperCase();
  }
}
