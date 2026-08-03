import 'package:flutter/foundation.dart';

import '../models/journal_entry.dart';
import '../models/memory_chunk.dart';
import 'chunk_store.dart';
import 'database_service.dart';
import 'memory_store.dart';
import '../models/memory_fact.dart';
import 'note_digest.dart';
import 'perspective.dart';
import 'relationship_log.dart';
import 'session_summarizer.dart';

/// The companion's working memory, held in RAM.
///
/// Everything the model is told about the user at the start of a conversation
/// comes from here, and it is all in memory by the time the first message is
/// sent — so a turn costs no database round trips at all.
///
/// **Why a cache and not just queries.** The blocks below are read on every
/// conversation start and re-read whenever the diary changes, and building them
/// means several queries plus digesting every permitted entry. Doing that on
/// the send path put database work between the user pressing send and the model
/// starting. Here it happens once at launch, off the critical path, and each
/// write invalidates only what it actually affects.
///
/// **Consistency over persistence.** Digests are recomputed from `journals`
/// rather than stored in their own table. They are extractive and cost
/// microseconds, so caching them in memory is free, and a derived table is one
/// more thing that can silently disagree with the entry it came from.
class MemoryCache extends ChangeNotifier {
  static final MemoryCache instance = MemoryCache._();

  MemoryCache._();

  final DatabaseService _db = DatabaseService();
  final MemoryStore _facts = MemoryStore();
  final ChunkStore _chunks = ChunkStore.instance;
  final RelationshipLog _relationship = RelationshipLog.instance;

  /// Most entries rendered into the notes block.
  ///
  /// Bounded because this shares a 4096-token container with the persona, the
  /// profile, the history and room to generate. Older entries are not lost —
  /// they stay in `memory_chunk` and come back through retrieval when something
  /// in them is relevant.
  static const int maxNotesInPrompt = 6;

  /// Hard ceiling on the rendered notes block.
  static const int maxNotesChars = 1400;

  bool _warm = false;
  Future<void>? _warming;

  List<MemoryFact> _pinnedFacts = const [];
  String? _relationshipBlock;
  List<NoteDigest> _digests = const [];

  /// True when the diary changed after the current conversation was created.
  ///
  /// The system instruction is fixed for the life of a conversation, so a diary
  /// unlocked *after* the model started has no way into it — which is exactly
  /// how "the companion cannot see my notes even though I gave permission"
  /// happened. When this is set the notes block is carried on the next turn
  /// instead, and cleared once it has been.
  bool _notesUnseen = false;

  bool get isWarm => _warm;

  String? get relationshipBlock => _relationshipBlock;

  List<NoteDigest> get digests => _digests;

  bool get hasUnseenNotes => _notesUnseen && _digests.isNotEmpty;

  void markNotesSeen() => _notesUnseen = false;

  /// Loads everything, once. Safe to call from several places at startup.
  Future<void> warm({bool force = false}) {
    if (_warm && !force) return Future.value();
    return _warming ??= _warm_(force).whenComplete(() => _warming = null);
  }

  Future<void> _warm_(bool force) async {
    try {
      // Bring derived memory up to date with the diary before reading any of
      // it. Without this, permission granted to an entry written before the
      // chunk store existed never produced anything, and the toggle looked
      // like it did nothing.
      await backfillJournals();
      await _reloadAll();
      _warm = true;
    } catch (e, stack) {
      debugPrint('MemoryCache warm failed: $e\n$stack');
      // Deliberately still marked warm: a companion with no cached memory is
      // degraded, one that retries a failing load on every send is unusable.
      _warm = true;
    }
  }

  Future<void> _reloadAll() async {
    _pinnedFacts = await _facts.pinnedFacts();
    _relationshipBlock = await _relationship.promptBlock();
    _digests = await _buildDigests();
    _sessions = await _chunks.recentSessions();
    notifyListeners();
  }

  List<MemoryChunk> _sessions = const [];

  /// Condenses the session that just ended and folds it into the cache.
  Future<void> onSessionEnded() async {
    try {
      await SessionSummarizer.summariseLatest();
      _sessions = await _chunks.recentSessions();
      notifyListeners();
    } catch (e) {
      debugPrint('Session summary failed: $e');
    }
  }

  // ── Journals ────────────────────────────────────────────────────────────

  /// Re-derives facts and chunks from every entry that permits it.
  ///
  /// Idempotent: `syncJournal` replaces whatever the entry produced last time,
  /// so running this at every launch costs a few milliseconds and repairs any
  /// entry whose derived memory is missing or stale — including everything
  /// written before extraction existed, and everything whose extraction has
  /// since been fixed.
  Future<void> backfillJournals() async {
    final db = await _db.database;
    final rows = await db.query('journals');
    final entries = rows.map(JournalEntry.fromMap).toList();

    for (final entry in entries) {
      try {
        await _facts.syncJournal(entry);
        await _chunks.syncJournal(entry);
      } catch (e) {
        debugPrint('Backfill failed for "${entry.title}": $e');
      }
    }
  }

  Future<List<NoteDigest>> _buildDigests() async {
    final db = await _db.database;
    final rows = await db.query(
      'journals',
      where: 'allowAiAccess = 1',
      orderBy: 'date DESC',
    );
    return rows
        .map(JournalEntry.fromMap)
        .map(NoteDigester.digest)
        .where((d) => !d.isEmpty)
        .toList(growable: false);
  }

  /// Call after any diary write. Re-derives that entry and rebuilds the blocks.
  Future<void> onJournalChanged(JournalEntry entry) async {
    try {
      await _facts.syncJournal(entry);
      await _chunks.syncJournal(entry);
      await _reloadAll();
      _notesUnseen = true;
    } catch (e) {
      debugPrint('Journal cache refresh failed: $e');
    }
  }

  /// Call after an entry is deleted.
  Future<void> onJournalDeleted(String entryId) async {
    try {
      await _facts.forgetSource(entryId);
      await _chunks.removeSource(entryId);
      await _reloadAll();
    } catch (e) {
      debugPrint('Journal cache delete failed: $e');
    }
  }

  /// Call after the companion learns something from a message.
  Future<void> refreshProfile() async {
    try {
      _pinnedFacts = await _facts.pinnedFacts();
      _relationshipBlock = await _relationship.promptBlock();
      notifyListeners();
    } catch (e) {
      debugPrint('Profile refresh failed: $e');
    }
  }

  // ── Rendering ───────────────────────────────────────────────────────────

  /// Everything the companion knows about the user, as one block.
  ///
  /// **Why this is not four blocks any more.** It used to be: a profile block,
  /// a diary block, a relationship block and a session block, each with its own
  /// explanatory preamble. That cost four preambles' worth of tokens out of a
  /// 4096-token container, and it taught the model to *attribute* — asked "do I
  /// swim", it answered *"You mentioned swimming in your diary"*. A friend who
  /// has read your diary does not cite it; they just know. One heading, one
  /// instruction, no sources.
  ///
  /// Diary lines are converted to the third person on the way in (see
  /// [Perspective]) so the whole block reads in one consistent voice.
  String? knowledgeBlock() {
    final lines = <String>[];

    // Slot-keyed facts, already third-person.
    for (final fact in _pinnedFacts) {
      lines.add('- ${fact.text}');
    }

    // Diary content, in the user's own words but not their own voice.
    //
    // Titles are carried as well as points. People put the substance in the
    // title as often as in the body — one entry here was titled *"My girlfriend
    // broke up with me"* with a body that only said *"She was cheating on
    // someone else"*, so dropping titles would have lost the more important
    // half of it.
    var used = 0;
    final seen = <String>{};
    for (final digest in _digests.take(maxNotesInPrompt)) {
      for (final source in [digest.title, ...digest.points]) {
        if (source.trim().isEmpty) continue;
        final line = Perspective.toThird(source.trim());
        // A title is often echoed by the opening sentence; carrying both wastes
        // budget on the same fact twice.
        if (!seen.add(line.toLowerCase())) continue;
        if (used + line.length > maxNotesChars) break;
        used += line.length;
        lines.add('- ${_asSentence(line)}');
      }
    }

    final trend = _relationshipBlock;
    final sessions = _sessions;
    if (lines.isEmpty && trend == null && sessions.isEmpty) return null;

    final buffer = StringBuffer(
      'What you know about them. All of it came from them — said to you, or '
      'written down and shared with you. Treat it as things you simply know: '
      'use it naturally when it helps, never recite the list back, and never '
      'say where a detail came from. If something here answers what they are '
      'asking, answer it rather than saying you are not sure.',
    );

    if (lines.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(lines.join('\n'));
    }
    if (trend != null) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(trend);
    }
    for (final session in sessions) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(session.text);
    }
    return buffer.toString();
  }

  /// Gives a line a full stop so titles and sentences sit together evenly.
  ///
  /// A diary title has no terminal punctuation ("Mornings at the lake"), and a
  /// list mixing bare fragments with full sentences reads as two different
  /// kinds of thing — which is exactly the distinction this block exists to
  /// remove.
  static String _asSentence(String line) {
    if (line.isEmpty) return line;
    return RegExp(r'[.!?…]$').hasMatch(line) ? line : '$line.';
  }

  /// Clears the in-memory copy. Used after a sweep.
  Future<void> reset() async {
    _pinnedFacts = const [];
    _relationshipBlock = null;
    _digests = const [];
    _sessions = const [];
    _notesUnseen = false;
    _warm = false;
    notifyListeners();
  }
}
