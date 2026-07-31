/// How concerning a message is, and therefore what should happen next.
enum CrisisLevel {
  /// Nothing matched. Normal conversation.
  none,

  /// Distress worth exploring, but ambiguous. "I want to die" is said
  /// figuratively far more often than literally; "ending things" is usually a
  /// relationship. These must **not** interrupt the conversation — the companion
  /// stays in it and asks, which is how you actually find out.
  concern,

  /// An unambiguous statement of intent, plan, or active self-harm. This is the
  /// one case where guessing wrong is not survivable, so it bypasses the model.
  explicit,
}

/// Detects language suggesting the user may be in danger, and decides whether to
/// stay in the conversation or step out of it.
///
/// **Two tiers, on purpose.** An earlier version had one: any match produced a
/// fixed response with a list of helplines. That was wrong in the common case.
/// Answering "I've been thinking about ending things" with a wall of phone
/// numbers reads as *"I can't handle you, go away"* — dismissive, and backwards
/// clinically, because risk is assessed by talking, not by pattern-matching one
/// sentence. It also meant a single false positive destroyed the conversation.
///
/// So [CrisisLevel.concern] does nothing to the conversation at all. The
/// companion replies normally and, being CBT-tuned, naturally asks what is going
/// on. Only if concern **recurs** across a session does the app offer support,
/// and then as one gentle line rather than a directory — see [gentleOffer].
/// Helplines are the last step, not the first.
///
/// [CrisisLevel.explicit] still short-circuits. A 2B model at temperature 1.2 is
/// a sampling process; for every other message that variability is the feature,
/// but for "I am going to kill myself tonight" the reply must be the same
/// reviewed text every time, with no chance of the model improvising or
/// minimising. That never reaches generation, never touches memory, never uses
/// the sampler.
///
/// Nothing here is in the system prompt. The prompt stays minimal — see
/// [Persona] — because loading it with safety instructions degrades every other
/// reply and does not reliably produce safe ones.
class CrisisGuard {
  const CrisisGuard._();

  /// Unambiguous intent, plan, or active self-harm. Kept narrow: everything that
  /// can be read innocently belongs in [_concernSignals] instead.
  static final List<RegExp> _explicitSignals = [
    RegExp(r'\b(kill|killing)\s+my\s?self\b'),
    RegExp(r'\bk+\s?y+\s?s+\b'), // common obfuscation
    RegExp(r'\btake\s+my\s+own\s+life\b'),
    RegExp(r'\bend\s+my\s+life\b'),
    RegExp(r'\bsuicid(e|al)\b'),
    RegExp(r'\bhurt(ing)?\s+my\s?self\b'),
    // Inflections matter: `self[\s-]?harm\b` misses "self harming", which is how
    // people usually say it.
    RegExp(r'\bself[\s-]?harm(ing|ed|s)?\b'),
    RegExp(r'\bcut(ting)?\s+my\s?self\b'),
    RegExp(r'\boverdose\b'),
  ];

  /// Real distress, but routinely said figuratively. These are conversation
  /// starters, not interrupts — the companion should ask what is behind them.
  static final List<RegExp> _concernSignals = [
    RegExp(r'\bwant\s+to\s+die\b'),
    RegExp(r'\bdon.?t\s+want\s+to\s+(be\s+here|live|wake\s+up|be\s+alive)\b'),
    RegExp(r'\bbetter\s+off\s+(dead|without\s+me)\b'),
    RegExp(r'\bno\s+(reason|point)\s+(to\s+)?(live|living|go\s+on)\b'),
    RegExp(r'\bend(ing)?\s+(things|it\s+all)\b'),
    RegExp(r'\bcan.?t\s+(do|take)\s+this\s+any\s?more\b'),
    RegExp(r'\bwhat.?s\s+the\s+point\b'),
  ];

  /// Phrases that wrap a signal in a non-literal or past frame.
  static final List<RegExp> _softeners = [
    RegExp(r'\b(movie|film|book|song|game|show|character|joke)\b'),
    RegExp(r'\bused\s+to\s+(feel|think|want)\b'),
    RegExp(r'\bwould\s+never\b'),
    RegExp(r'\bglad\s+i\s+did\s?n.?t\b'),
  ];

  /// Classifies [text]. See [CrisisLevel].
  static CrisisLevel assess(String text) {
    final t = text.toLowerCase();
    if (_softeners.any((r) => r.hasMatch(t))) return CrisisLevel.none;
    if (_explicitSignals.any((r) => r.hasMatch(t))) return CrisisLevel.explicit;
    if (_concernSignals.any((r) => r.hasMatch(t))) return CrisisLevel.concern;
    return CrisisLevel.none;
  }

  /// Crisis resources, each verified against the operator's own site.
  ///
  /// Every entry carries [ResourceEntry.source] and [ResourceEntry.verifiedOn]
  /// so re-checking is mechanical: open the source, confirm the number, bump the
  /// date. A dead number here is worse than no number, so nothing goes in from
  /// memory — only from the operator's own page.
  ///
  /// Deliberately short. The international directories cover every country and
  /// are maintained daily by their operators, which ages far better than a long
  /// hardcoded national list that silently rots.
  ///
  /// Directories are listed first: this app has users in more than one country,
  /// and someone in Brazil should not have to scan past a US number.
  static const List<ResourceEntry> resources = [
    ResourceEntry(
      name: 'Find A Helpline',
      contact: 'findahelpline.com',
      region: 'International',
      note: 'free, verified helplines in 130+ countries',
      source: 'https://findahelpline.com/',
      verifiedOn: '2026-07-31',
    ),
    ResourceEntry(
      name: 'IASP crisis centre directory',
      contact: 'iasp.info/crisis-centres-helplines',
      region: 'International',
      note: 'International Association for Suicide Prevention',
      source: 'https://www.iasp.info/crisis-centres-helplines/',
      verifiedOn: '2026-07-31',
    ),
    ResourceEntry(
      name: 'Tele-MANAS',
      contact: '14416',
      region: 'India',
      note: '24/7, free, 20 regional languages',
      source: 'https://telemanas.mohfw.gov.in/',
      verifiedOn: '2026-07-31',
    ),
    ResourceEntry(
      name: '988 Suicide & Crisis Lifeline',
      contact: 'call or text 988',
      region: 'United States',
      note: '24/7',
      source: 'https://988lifeline.org/',
      verifiedOn: '2026-07-31',
    ),
    ResourceEntry(
      name: 'Samaritans',
      contact: '116 123',
      region: 'UK & Ireland',
      note: '24/7, free to call',
      source: 'https://www.samaritans.org/',
      verifiedOn: '2026-07-31',
    ),
  ];

  /// One line, offered after concern has recurred — never on a first signal.
  ///
  /// Deliberately not the full directory. At this point the user has not said
  /// anything unambiguous; they are talking, which is what we want. A wall of
  /// numbers would end that. This mentions one place and explicitly stays in the
  /// conversation.
  static String gentleOffer() =>
      "One thing before we carry on — if it would help to talk this through with "
      "someone trained for it, findahelpline.com lists free, confidential lines "
      "in 130+ countries. No pressure at all, and I'm still here either way.";

  /// The fixed response for [CrisisLevel.explicit]. Never generated, never
  /// sampled.
  ///
  /// Leads with emergency services and a trusted person, because those help
  /// fastest and neither depends on knowing the user's country.
  static String response() {
    final buffer = StringBuffer()
      ..writeln(
        "I'm really glad you told me, and I want to be honest with you: what "
        "you're describing sounds like more than I can hold on my own.",
      )
      ..writeln()
      ..writeln(
        "If you are in immediate danger, please contact your local emergency "
        "services now. If you can, reach out to someone you trust and tell them "
        "what you just told me — you should not have to sit with this alone.",
      );

    if (resources.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln("People who can help right now:");
      for (final r in resources) {
        final note = r.note.isEmpty ? '' : ' — ${r.note}';
        buffer.writeln("• ${r.region}: ${r.name}, ${r.contact}$note");
      }
    }

    buffer
      ..writeln()
      ..writeln(
        "I'll still be here afterwards, and we can keep talking whenever you want to.",
      );

    return buffer.toString().trim();
  }
}

/// One crisis resource, with the provenance needed to re-verify it.
class ResourceEntry {
  final String name;

  /// Phone number, shortcode or domain, as the user would act on it.
  final String contact;

  /// Where it applies — shown to the user, so they can skip lines that are not
  /// theirs.
  final String region;

  /// Hours and coverage. May be empty.
  final String note;

  /// The operator's own page. Details were read from here, not from memory.
  final String source;

  /// ISO date this entry was last checked against [source].
  final String verifiedOn;

  const ResourceEntry({
    required this.name,
    required this.contact,
    required this.region,
    required this.source,
    required this.verifiedOn,
    this.note = '',
  });
}
