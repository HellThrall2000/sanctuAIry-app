/// What kind of thing a remembered fact is.
///
/// The kind decides how the fact is rendered into the profile block and, later,
/// how it can gate behaviour — a [FactKind.constraint] is the one the diary
/// feature exists for (ROADMAP G3: never suggest a roller coaster to someone a
/// roller coaster injured).
enum FactKind {
  name,
  age,
  location,
  occupation,
  relationship,
  preference,
  aversion,
  constraint,
  event,
}

/// Where a fact came from. Shown to the user on the memory screen, because
/// "how do you know that about me" must always have an answer.
enum FactSource { chat, journal }

/// Which kinds are worth carrying in every prompt, and in what order.
///
/// The split is by whether a kind is **bounded**. A person has one name, one
/// age, one home; those never grow, so carrying them costs a fixed few tokens
/// forever. Preferences and events grow without limit as the conversation goes
/// on, so they have to be searched instead — see `MemoryStore.recallFor`.
///
/// Constraints are first because they are the ones that should override a
/// suggestion (ROADMAP G3), and being absent from the prompt is exactly how a
/// companion ends up recommending a roller coaster to someone one injured.
const List<FactKind> pinnedKindPriority = [
  FactKind.constraint,
  FactKind.name,
  FactKind.age,
  FactKind.location,
  FactKind.occupation,
  FactKind.relationship,
];

extension FactKindTier on FactKind {
  /// Whether this kind is eligible to be carried in every prompt.
  ///
  /// Eligible is not the same as guaranteed: pinning is capped, and anything
  /// that does not fit stays searchable rather than being dropped.
  bool get isPinnable => pinnedKindPriority.contains(this);
}

/// One durable thing the companion knows about the user.
///
/// Facts are small and self-contained rather than a graph. That is deliberate:
/// the always-loaded profile has to stay inside a few hundred tokens, and a
/// flat list is far cheaper to keep correct than edges are. The richer graph in
/// docs/MEMORY_GRAPH_ARCHITECTURE.md builds on top of this rather than
/// replacing it.
class MemoryFact {
  /// Stable identity for the *slot*, not the value — `relationship:wife`,
  /// `occupation`, `aversion:roller coasters`.
  ///
  /// Re-learning the same key replaces the old value, which is what makes the
  /// store self-correcting when someone changes job or city.
  final String key;

  final FactKind kind;

  /// The remembered value, e.g. `Padmanava`, `Berlin`, `roller coasters`.
  final String value;

  /// The line injected into the prompt, already phrased in the third person.
  final String text;

  final FactSource source;

  /// Journal entry id when [source] is [FactSource.journal]; null for chat.
  final String? sourceId;

  /// Verbatim text this was extracted from. Kept so the memory screen can show
  /// the user exactly what they said, rather than asking them to trust a
  /// paraphrase.
  final String evidence;

  final DateTime updatedAt;

  const MemoryFact({
    required this.key,
    required this.kind,
    required this.value,
    required this.text,
    required this.source,
    required this.evidence,
    required this.updatedAt,
    this.sourceId,
  });

  Map<String, dynamic> toMap() => {
        'key': key,
        'kind': kind.name,
        'value': value,
        'text': text,
        'source': source.name,
        'sourceId': sourceId,
        'evidence': evidence,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory MemoryFact.fromMap(Map<String, dynamic> map) => MemoryFact(
        key: map['key'] as String,
        kind: FactKind.values.byName(map['kind'] as String),
        value: map['value'] as String,
        text: map['text'] as String,
        source: FactSource.values.byName(map['source'] as String),
        sourceId: map['sourceId'] as String?,
        evidence: map['evidence'] as String? ?? '',
        updatedAt: DateTime.parse(map['updatedAt'] as String),
      );

  @override
  String toString() => '$key = $value (${source.name})';
}
