import '../models/memory_fact.dart';

/// Pulls durable personal facts out of free text, deterministically.
///
/// **Why patterns and not the model.** Running an extraction pass through the
/// LLM costs another full generation — 15–30 s on this device — for every
/// message. That would double the latency of every turn to populate a cache, so
/// it is not a lightweight design by any reading. These patterns are instant and
/// free. [MemoryStore] and the profile block are deliberately agnostic about
/// where facts come from, so a model-based extractor can be added later
/// (ROADMAP P2) and write to the same table without changing anything else.
///
/// **Precision over recall, on purpose.** A profile that is always in context is
/// also always able to be wrong, and a wrong fact is worse than a missing one —
/// it makes the companion confidently misremember the user. So every pattern
/// requires an explicit declarative frame ("my name is…", "i live in…") rather
/// than guessing from loose phrasing. `"i am sad"` must never become a name.
class FactExtractor {
  const FactExtractor._();

  /// Trailing filler that turns a clean value into a run-on. `"i live in Berlin
  /// but i hate it"` should remember Berlin, not the complaint.
  static final RegExp _tail = RegExp(
    r'\s+(and|but|because|so|although|though|since|while|when|which|that|who)\b.*$',
    caseSensitive: false,
  );

  /// Values that are grammatical but meaningless as memory. Mostly the debris of
  /// `i can't …` and `i have …`, which are otherwise useful frames.
  static const _junk = {
    'do this', 'do that', 'take this', 'take it', 'go on', 'anymore',
    'do this anymore', 'take this anymore', 'it', 'this', 'that', 'them',
    'anything', 'nothing', 'something', 'a lot', 'time', 'today', 'a break',
    'sleep', 'stop', 'help', 'a problem', 'an idea', 'no idea',
  };

  /// Relations worth remembering by name. Deliberately closed — an open pattern
  /// like `my (\w+)` matches "my day", "my head", "my problem".
  static const _relations = {
    'wife', 'husband', 'partner', 'girlfriend', 'boyfriend', 'fiance',
    'fiancee', 'mother', 'mom', 'mum', 'father', 'dad', 'sister', 'brother',
    'son', 'daughter', 'friend', 'best friend', 'boss', 'manager', 'therapist',
    'doctor', 'dog', 'cat', 'roommate', 'flatmate', 'colleague',
  };

  /// Extracts every fact [text] declares. Returns an empty list for ordinary
  /// conversation, which is the common case.
  static List<MemoryFact> extract(
    String text, {
    required FactSource source,
    String? sourceId,
  }) {
    final facts = <MemoryFact>[];
    final now = DateTime.now();

    void add(FactKind kind, String key, String value, String render,
        {bool lower = true}) {
      final cleaned = _clean(value, lower: lower);
      if (cleaned == null) return;
      facts.add(MemoryFact(
        key: key,
        kind: kind,
        value: cleaned,
        text: render.replaceAll('{}', cleaned),
        source: source,
        sourceId: sourceId,
        evidence: text.trim(),
        updatedAt: now,
      ));
    }

    final t = text.toLowerCase();

    // ── identity ────────────────────────────────────────────────────────────
    // Explicit frames only. "i'm X" is not used: "i'm sad" and "i'm tired" are
    // vastly more common than "i'm Padmanava".
    for (final m in RegExp(r"\b(?:my name is|call me|i go by)\s+([a-z][\w'-]{1,30})")
        .allMatches(t)) {
      add(FactKind.name, 'name', m[1]!, 'Their name is {}.');
    }

    for (final m
        in RegExp(r"\bi(?:'m| am)\s+(\d{1,2})\s*(?:years old|yo\b)").allMatches(t)) {
      add(FactKind.age, 'age', m[1]!, 'They are {} years old.');
    }

    for (final m in RegExp(r"\bi\s+live\s+in\s+([\w\s,'-]{2,40})").allMatches(t)) {
      add(FactKind.location, 'location', m[1]!, 'They live in {}.');
    }
    for (final m in RegExp(r"\bi(?:'m| am)\s+from\s+([\w\s,'-]{2,40})").allMatches(t)) {
      add(FactKind.location, 'origin', m[1]!, 'They are from {}.');
    }

    // ── work ────────────────────────────────────────────────────────────────
    for (final m in RegExp(r"\b(?:i work as|my job is)\s+(?:an?\s+)?([\w\s-]{2,40})")
        .allMatches(t)) {
      add(FactKind.occupation, 'occupation', m[1]!, 'They work as {}.');
    }
    for (final m
        in RegExp(r"\bi\s+work\s+(?:at|for)\s+([\w\s&.,'-]{2,40})").allMatches(t)) {
      add(FactKind.occupation, 'employer', m[1]!, 'They work at {}.');
    }

    // ── relationships ───────────────────────────────────────────────────────
    // Distinguishing "my wife Sara" from "my wife left" cannot be done with a
    // blocklist of verbs — there is always another verb. Two signals are used
    // instead, both checked against the *original* text so capitalisation
    // survives:
    //
    //   1. an unambiguous naming frame — "named"/"called" — accepted in any case
    //   2. a capitalised word — "my boss is Dan", "my wife Sara"
    //
    // A lowercase bare word is treated as no name at all, so "my therapist
    // suggested journaling" records a therapist rather than one called
    // "suggested". That misses lowercase names, which is the intended trade: a
    // relation with no name is still useful, a relation with a wrong name is not.
    final relationAlt = _relations.map(RegExp.escape).join('|');

    final named = RegExp(
      "\\bmy\\s+($relationAlt)\\s+(?:is\\s+|was\\s+)?(?:named|called)\\s+"
      "([A-Za-z][A-Za-z'-]{1,20})",
      caseSensitive: false,
    );
    final capitalised = RegExp(
      "\\bmy\\s+($relationAlt)\\s+(?:is\\s+|was\\s+)?([a-z][a-z'-]{1,20})\\b",
      caseSensitive: false,
    );
    final bare = RegExp("\\bmy\\s+($relationAlt)\\b", caseSensitive: false);

    final namedRelations = <String>{};

    void takeName(String relation, String name) {
      // A relation word is not a name ("my dog cat"), and neither is a verb.
      if (_relations.contains(name.toLowerCase())) return;
      if (_isFillerAfterRelation(name.toLowerCase())) return;
      // Nor is a pronoun. "called" is both a naming frame and an ordinary verb,
      // so *"my dad called me"* was being stored as "Their dad is called me."
      if (_pronouns.contains(name.toLowerCase())) return;
      namedRelations.add(relation);
      add(FactKind.relationship, 'relationship:$relation', name,
          'Their $relation is called {}.', lower: false);
    }

    // Unambiguous frame — capitalisation not required.
    for (final m in named.allMatches(text)) {
      takeName(m[1]!.toLowerCase(), m[2]!);
    }
    // Bare apposition — only trusted when the word is capitalised. The check is
    // done here rather than in the pattern because `caseSensitive: false`
    // applies to the whole regex, so `[A-Z]` inside it would match anything.
    for (final m in capitalised.allMatches(text)) {
      final relation = m[1]!.toLowerCase();
      final name = m[2]!;
      if (namedRelations.contains(relation)) continue;
      if (name[0] != name[0].toUpperCase()) continue;
      takeName(relation, name);
    }
    for (final m in bare.allMatches(text)) {
      final relation = m[1]!.toLowerCase();
      if (namedRelations.contains(relation)) continue;

      // "my girlfriend" does not mean "has a girlfriend". Measured on device:
      // a diary entry titled *"My girlfriend broke up with me"* was stored as
      // **"They have a girlfriend."**, and the companion later volunteered
      // "I heard your girlfriend is making that amazing lasagna again" to
      // someone whose partner had left. A wrong fact is worse than a missing
      // one, and this was the worst kind — confidently contradicting the very
      // thing the user had written down.
      //
      // Unlike the name problem above, this is tractable: endings are a small,
      // high-precision closed set, where verbs in general are not.
      final ending = _endingNear(text, m.start);
      if (ending != null) {
        // Recorded as what actually happened, so the companion knows about the
        // loss rather than merely not knowing about the relationship.
        //
        // Bereavement is worded separately. "Their relationship with their dad
        // has ended" is a grotesque way to say a parent died, and this text is
        // read back to someone who is grieving.
        add(
          FactKind.event,
          'relationship_ended:$relation',
          relation,
          _isBereavement(ending)
              ? 'They have lost their {}.'
              : 'Their relationship with their {} has ended.',
        );
        continue;
      }
      add(FactKind.relationship, 'relationship:$relation', relation,
          'They have a {}.');
    }

    // ── likes and dislikes ──────────────────────────────────────────────────
    // (relationship-ending helpers live at the bottom of the class)
    for (final m in RegExp(r"\bi\s+(?:really\s+)?(?:love|like|enjoy)\s+([\w\s-]{2,40})")
        .allMatches(t)) {
      final v = _clean(m[1]!);
      if (v != null) add(FactKind.preference, 'preference:$v', v, 'They enjoy {}.');
    }
    for (final m in RegExp(
            r"\bi\s+(?:really\s+)?(?:hate|dislike|can'?t stand)\s+([\w\s-]{2,40})")
        .allMatches(t)) {
      final v = _clean(m[1]!);
      if (v != null) add(FactKind.aversion, 'aversion:$v', v, 'They dislike {}.');
    }

    // ── constraints ─────────────────────────────────────────────────────────
    // The most consequential kind: these are what should stop the companion
    // suggesting something harmful. See ROADMAP G3.
    for (final m in RegExp(r"\bi(?:'m| am)\s+allergic\s+to\s+([\w\s-]{2,40})")
        .allMatches(t)) {
      final v = _clean(m[1]!);
      if (v != null) {
        add(FactKind.constraint, 'allergy:$v', v, 'They are allergic to {}.');
      }
    }
    for (final m in RegExp(r"\bi(?:'m| am)\s+(?:afraid|scared|terrified)\s+of\s+([\w\s-]{2,40})")
        .allMatches(t)) {
      final v = _clean(m[1]!);
      if (v != null) add(FactKind.constraint, 'fear:$v', v, 'They are afraid of {}.');
    }
    for (final m in RegExp(r"\bi\s+can'?(?:no)?t\s+([\w\s-]{2,40})").allMatches(t)) {
      final v = _clean(m[1]!);
      if (v != null) add(FactKind.constraint, 'cannot:$v', v, 'They cannot {}.');
    }

    return _dedupe(facts);
  }

  /// A relation followed by a verb is not a name: "my wife left me" must not
  /// record a wife called "left".
  static bool _isFillerAfterRelation(String word) => const {
        'is', 'was', 'has', 'had', 'and', 'left', 'said', 'told', 'went',
        'broke', 'died', 'passed', 'thinks', 'wants', 'keeps', 'never',
        'always', 'really', 'just', 'also', 'still', 'does', 'did', 'gets',
        'got', 'makes', 'made', 'took', 'takes', 'calls', 'called', 'works',
        'lives', 'loves', 'hates', 'likes',
      }.contains(word);

  /// Never a person's name, however the frame reads.
  static const _pronouns = {
    'me', 'him', 'her', 'us', 'them', 'you', 'it', 'myself', 'himself',
    'herself', 'themselves', 'yourself', 'today', 'yesterday', 'tomorrow',
    'again', 'back', 'earlier', 'later', 'twice',
  };

  /// Phrases that mean a relationship is over.
  ///
  /// A small, high-precision set. The comment above the naming patterns warns
  /// that a verb blocklist is never complete — that is true when you are trying
  /// to enumerate every verb a relation can take, and false here, where only a
  /// handful of constructions actually end one. Missing an ending leaves the
  /// old behaviour (a present-tense relation), so the failure mode of an
  /// incomplete list is what we already had, not something worse.
  static final RegExp _relationshipEnded = RegExp(
    r"("
    r"\bbroke\s+up\b|\bbreaking\s+up\b|\bbroken\s+up\b|\bbreakup\b|\bbreak-up\b"
    r"|\bdumped\b|\bleft\s+me\b|\bwalked\s+out\b|\bwe\s+split\b|\bsplit\s+up\b"
    r"|\bdivorc(?:e|ed|ing)\b|\bseparated\b"
    r"|\bpassed\s+away\b|\bdied\b|\bfuneral\b"
    r"|\bex[-\s]?(?:girlfriend|boyfriend|wife|husband|partner)\b"
    r"|\bis\s+no\s+longer\b|\bused\s+to\s+be\b"
    r")",
    caseSensitive: false,
  );

  /// Whether the ending phrase describes a death rather than a separation.
  static bool _isBereavement(String ending) {
    final e = ending.toLowerCase();
    return e.contains('died') ||
        e.contains('passed away') ||
        e.contains('funeral');
  }

  /// Whether an ending phrase sits in the same sentence as the relation at
  /// [relationIndex].
  ///
  /// Scoped to the sentence rather than the whole text: a diary entry can
  /// mention a breakup in one paragraph and a living sister in another, and a
  /// document-wide check would erase the sister too.
  static String? _endingNear(String text, int relationIndex) {
    var start = 0;
    var end = text.length;
    for (final match in RegExp(r'[.!?\n]').allMatches(text)) {
      if (match.start < relationIndex) {
        start = match.end;
      } else {
        end = match.start;
        break;
      }
    }
    final sentence = text.substring(start, end);
    return _relationshipEnded.firstMatch(sentence)?.group(0);
  }

  /// Trims filler and rejects values that carry no meaning. Returns null when
  /// nothing worth storing is left.
  ///
  /// [lower] is false for names, where the user's own capitalisation is worth
  /// keeping — "Their wife is called sara" reads as a transcription error.
  static String? _clean(String raw, {bool lower = true}) {
    var v = (lower ? raw.toLowerCase() : raw).trim();
    v = v.replaceAll(_tail, '');
    v = v.replaceAll(RegExp(r'''^[\s"'`]+|[\s.,!?;:"'`]+$'''), '');
    v = v.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (v.length < 2 || v.length > 40) return null;
    if (_junk.contains(v.toLowerCase())) return null;
    if (RegExp(r'^\d+$').hasMatch(v) && v.length > 3) return null;
    return v;
  }

  /// Last write wins within a single message, so "my name is Bob, sorry, my
  /// name is Rob" keeps Rob.
  static List<MemoryFact> _dedupe(List<MemoryFact> facts) {
    final byKey = <String, MemoryFact>{};
    for (final f in facts) {
      byKey[f.key] = f;
    }
    return byKey.values.toList(growable: false);
  }
}
