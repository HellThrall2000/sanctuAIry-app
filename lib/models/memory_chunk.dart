/// Where a chunk came from.
enum ChunkSource {
  /// One exchange of conversation.
  chat,

  /// A paragraph of a journal entry the user shared with the companion.
  journal,

  /// A whole past session, condensed. Written when the app closes — see
  /// `SessionSummarizer` for why the transcript cannot be replayed verbatim.
  session;

  static ChunkSource fromName(String name) =>
      ChunkSource.values.firstWhere((s) => s.name == name, orElse: () => chat);
}

/// A retrievable piece of the past, stored verbatim.
///
/// Distinct from `MemoryFact`, and the difference is the point. A fact is
/// slot-keyed and self-correcting — learning a new city replaces the old one. A
/// chunk is append-only raw text: it is what was actually said, kept so it can
/// be quoted back accurately and re-processed later if extraction improves.
class MemoryChunk {
  final String id;
  final String text;
  final ChunkSource source;

  /// The journal entry this came from, so revoking that entry's permission can
  /// delete it. Null for chat.
  final String? sourceId;

  final DateTime createdAt;

  const MemoryChunk({
    required this.id,
    required this.text,
    required this.source,
    required this.createdAt,
    this.sourceId,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'source': source.name,
        'sourceId': sourceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory MemoryChunk.fromMap(Map<String, Object?> map) => MemoryChunk(
        id: map['id'] as String,
        text: map['text'] as String,
        source: ChunkSource.fromName(map['source'] as String),
        sourceId: map['sourceId'] as String?,
        createdAt: DateTime.parse(map['createdAt'] as String).toLocal(),
      );
}

/// A chunk with its relevance to a query.
class ScoredChunk {
  final MemoryChunk chunk;
  final double score;

  const ScoredChunk(this.chunk, this.score);
}
