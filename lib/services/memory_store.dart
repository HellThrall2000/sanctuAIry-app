import 'package:sqflite/sqflite.dart';
import '../models/journal_entry.dart';
import '../models/memory_fact.dart';
import 'database_service.dart';
import 'fact_extractor.dart';
import 'fact_ranker.dart';

/// The companion's cache of durable personal facts, and the block of text it
/// injects into the system instruction.
///
/// **Always loaded, never retrieved.** This is the deliberate difference from
/// the RAG design in docs/MEMORY_GRAPH_ARCHITECTURE.md. Retrieval only surfaces
/// what a query happens to match, and "what is my name" is not reliably similar
/// to "my name is Padmanava". Personal facts are few, small and relevant to
/// every turn, so they are cheaper to carry than to search — the whole profile
/// costs a couple of hundred tokens against a 4,096-token context.
///
/// **Scope of the cache.** Facts persist across sessions; that is the point.
/// Within a session the model already has the user's own message in context, so
/// nothing needs re-injecting mid-conversation — which is what keeps this
/// lightweight, since changing the system instruction means rebuilding the
/// conversation and re-prefilling its history.
class MemoryStore {
  static final MemoryStore _instance = MemoryStore._internal();
  factory MemoryStore() => _instance;
  MemoryStore._internal();

  final DatabaseService _db = DatabaseService();

  /// Cap on facts pinned into every prompt.
  ///
  /// The pinned block competes with conversation history for context, and past
  /// roughly this many a small model starts treating the profile as the topic
  /// rather than as background.
  ///
  /// Anything over the cap is **not discarded** — it stays in the store and
  /// remains reachable through [recallFor]. An earlier version simply truncated,
  /// which meant that past twenty facts the companion silently forgot things
  /// with no way to reach them again.
  static const int maxPinnedFacts = 12;

  /// Cap on facts retrieved for a single turn.
  static const int maxRecalledFacts = 4;

  /// Stores [facts], replacing any with the same key.
  Future<void> remember(Iterable<MemoryFact> facts) async {
    if (facts.isEmpty) return;
    final db = await _db.database;
    final batch = db.batch();
    for (final f in facts) {
      batch.insert('memory_facts', f.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Extracts from a chat message and stores whatever it finds.
  ///
  /// Returns the facts learned, so the caller can tell the user something was
  /// remembered rather than doing it silently.
  Future<List<MemoryFact>> learnFromMessage(String text) async {
    final facts = FactExtractor.extract(text, source: FactSource.chat);
    await remember(facts);
    return facts;
  }

  /// Re-derives facts from [entry].
  ///
  /// **Withdrawing permission stops future sharing; it does not erase what was
  /// already learned.** Sharing an entry teaches the companion something, and
  /// once it knows, unticking a box does not make it not know — the same way
  /// telling a friend something and then asking them to forget it does not
  /// work. Pretending otherwise would be the dishonest option.
  ///
  /// So the only true erase is the deliberate one: "Forget all" in the memory
  /// panel, or deleting the entry itself, both of which go through
  /// [forgetSource]. The diary UI says exactly this rather than implying the
  /// toggle is a delete.
  ///
  /// Keeping it also makes the cache stable: derived memory stops appearing and
  /// disappearing as toggles move, which is what a retrieval layer needs.
  Future<List<MemoryFact>> syncJournal(JournalEntry entry) async {
    if (!entry.allowAiAccess) return const [];

    // Replaces this entry's previous facts rather than accumulating them, so
    // editing an entry corrects what was learned from it.
    await forgetSource(entry.id);

    final facts = FactExtractor.extract(
      '${entry.title}\n${entry.content}',
      source: FactSource.journal,
      sourceId: entry.id,
    );
    await remember(facts);
    return facts;
  }

  /// Drops every fact derived from a journal entry. Called when permission is
  /// withdrawn or the entry is deleted.
  Future<void> forgetSource(String sourceId) async {
    final db = await _db.database;
    await db.delete('memory_facts',
        where: 'sourceId = ?', whereArgs: [sourceId]);
  }

  Future<void> forget(String key) async {
    final db = await _db.database;
    await db.delete('memory_facts', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> forgetAll() async {
    final db = await _db.database;
    await db.delete('memory_facts');
  }

  /// Everything known, newest first. Backs the memory screen.
  Future<List<MemoryFact>> all() async {
    final db = await _db.database;
    final rows = await db.query('memory_facts', orderBy: 'updatedAt DESC');
    return rows.map(MemoryFact.fromMap).toList(growable: false);
  }

  /// The facts carried in every prompt: bounded kinds, highest priority first,
  /// capped at [maxPinnedFacts].
  ///
  /// Ordered by [pinnedKindPriority] rather than recency so the block reads as a
  /// description of a person rather than a changelog, and so that constraints —
  /// the ones that should override a suggestion — survive the cap.
  Future<List<MemoryFact>> pinnedFacts() async {
    final facts = await all();
    final pinnable = facts.where((f) => f.kind.isPinnable).toList()
      ..sort((a, b) {
        final byKind = pinnedKindPriority
            .indexOf(a.kind)
            .compareTo(pinnedKindPriority.indexOf(b.kind));
        return byKind != 0 ? byKind : b.updatedAt.compareTo(a.updatedAt);
      });
    return pinnable.take(maxPinnedFacts).toList(growable: false);
  }

  /// Facts relevant to [message], excluding anything already pinned.
  ///
  /// This is the half that scales. The pinned block is fixed-size, so as the
  /// store grows it is retrieval that has to surface the rest — a user two
  /// hundred facts in still gets the four that matter to what they just said.
  ///
  /// Usually returns nothing: [FactRanker.minScore] is set so that an ordinary
  /// turn retrieves nothing rather than padding the prompt with coincidence.
  Future<List<MemoryFact>> recallFor(String message) async {
    final facts = await all();
    if (facts.isEmpty) return const [];

    final pinnedKeys = (await pinnedFacts()).map((f) => f.key).toSet();
    final candidates =
        facts.where((f) => !pinnedKeys.contains(f.key)).toList(growable: false);
    if (candidates.isEmpty) return const [];

    return FactRanker.rank(message, candidates, limit: maxRecalledFacts)
        .map((s) => s.fact)
        .toList(growable: false);
  }

  /// One line per recalled fact, for injecting into a single turn, or null when
  /// nothing is relevant.
  ///
  /// Kept separate from the pinned block that `MemoryCache` renders, because it
  /// goes somewhere different: the pinned facts are part of the system
  /// instruction, fixed for the life of the conversation, while this changes
  /// every turn and so has to ride along with the user's message.
  Future<String?> recallBlock(String message) async {
    final facts = await recallFor(message);
    if (facts.isEmpty) return null;
    return '(You also remember: ${facts.map((f) => f.text).join(' ')})';
  }

}
