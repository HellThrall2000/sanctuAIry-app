import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'chat_store.dart';
import 'chunk_store.dart';
import 'quick_prompts.dart';
import 'sentiment_analyzer.dart';
import 'topic_extractor.dart';

/// Condenses a finished session into the few lines worth carrying forward.
///
/// **Why sessions are summarised at all.** While the app is open the whole
/// conversation is on screen and the recent window is in the model's context,
/// which is right — someone mid-conversation should not find the companion has
/// quietly forgotten the last ten minutes. But that fidelity cannot persist:
/// the container is 4096 tokens, and a month of conversation replayed verbatim
/// exceeds it many times over. So the transcript is kept forever for the *user*
/// (see [ChatStore], which never deletes), and the *model* gets this.
///
/// **Extractive, and no model runs.** Summarising happens as the app is closing,
/// where there is no time for a 15–30 s generation and no user to wait for it.
/// These are the user's own sentences, selected — which also means a summary can
/// never invent something they did not say, the failure mode that matters most
/// for a memory the companion will later treat as true.
abstract final class SessionSummarizer {
  /// Sessions shorter than this are not worth a summary.
  ///
  /// Two exchanges is a greeting, not a conversation, and summarising it just
  /// fills retrieval with noise.
  static const int minUserTurns = 2;

  /// A gap this long means the previous session had ended.
  static const Duration sessionGap = Duration(hours: 2);

  /// Most user lines quoted in one summary.
  static const int maxQuotedLines = 3;

  /// Summarises the most recent session and stores it, if there is one worth
  /// storing.
  ///
  /// Safe to call repeatedly: the summary is keyed by the session's last
  /// message, so closing the app twice without talking produces one row.
  static Future<String?> summariseLatest() async {
    try {
      final all = await ChatStore.instance.recent(limit: 400);
      final session = _lastSession(all);
      final userTurns = session.where((m) => m.isUser).toList();
      if (userTurns.length < minUserTurns) return null;

      final summary = _render(session, userTurns);
      if (summary == null) return null;

      await ChunkStore.instance.addSessionSummary(
        text: summary,
        endedAt: session.last.createdAt,
      );
      return summary;
    } catch (e, stack) {
      debugPrint('Session summary failed: $e\n$stack');
      return null;
    }
  }

  /// The trailing run of messages with no [sessionGap] between them.
  static List<ChatMessage> _lastSession(List<ChatMessage> all) {
    if (all.isEmpty) return const [];
    var start = 0;
    for (var i = all.length - 1; i > 0; i--) {
      if (all[i].createdAt.difference(all[i - 1].createdAt) > sessionGap) {
        start = i;
        break;
      }
    }
    return all.sublist(start);
  }

  static String? _render(
    List<ChatMessage> session,
    List<ChatMessage> userTurns,
  ) {
    final topics = <String>{};
    for (final m in userTurns) {
      topics.addAll(TopicExtractor.extract(m.text));
    }

    // Mood across the session, from the readings already taken at send time
    // where they exist and re-read where they do not.
    final readings = userTurns
        .map((m) => m.mood ?? SentimentAnalyzer.read(m.text))
        .where((r) => r.isSignal)
        .toList();
    final mood = readings.isEmpty
        ? null
        : readings
            .reduce((a, b) => a.confidence >= b.confidence ? a : b)
            .label;

    // The lines that carried the session: longest user turns are a crude but
    // reliable proxy for substance, and they are quoted rather than paraphrased.
    // Unedited quick-prompt seeds are the app's words, not the user's, and
    // they are long enough to win on length every time.
    // Deduplicated first. A user who repeats themselves — or a test harness
    // that replays the same message — otherwise fills all three quote slots
    // with one sentence, and these summaries are carried in the system
    // instruction where every token is taken from the conversation.
    final seen = <String>{};
    final quoted = userTurns
        .where((m) => !QuickPrompt.isSeed(m.text))
        .where((m) => seen.add(_dedupeKey(m.text)))
        .toList()
      ..sort((a, b) => b.text.length.compareTo(a.text.length));
    final lines = quoted
        .take(maxQuotedLines)
        .where((m) => m.text.trim().length >= 15)
        .toList()
      // Back into the order they were said, so the summary reads as a session
      // rather than a ranking.
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (lines.isEmpty && topics.isEmpty && mood == null) return null;

    final when = _shortDate(session.last.createdAt);
    final buffer = StringBuffer('Earlier conversation ($when)');
    if (mood != null) {
      buffer.write(' — they were ${mood.description}');
    }
    buffer.write('.');
    if (topics.isNotEmpty) {
      buffer.writeln();
      buffer.write('About: ${topics.join(', ')}.');
    }
    for (final line in lines) {
      buffer.writeln();
      buffer.write('They said: ${_trim(line.text)}');
    }
    return buffer.toString();
  }

  /// Condenses turns being dropped from a **live** conversation that has filled
  /// the context window.
  ///
  /// **Why this is not just deletion.** When the window fills, older exchanges
  /// have to leave — but dropping them outright means the companion forgets, in
  /// the middle of a conversation, something the user said ten minutes ago.
  /// Compacting keeps the substance and pays only a few dozen tokens for it,
  /// which is what an agentic system's auto-compaction does and what this was
  /// missing.
  ///
  /// The retrieval layer is a *different* safety net: dropped turns also live in
  /// `ChunkStore` and can come back if a later message happens to match them.
  /// That is lossy in a way this is not — retrieval only fires on a lexical
  /// match, so it cannot be relied on to carry the thread of the conversation
  /// currently being had.
  ///
  /// Extractive, like the rest of this class: a generation pass to summarise
  /// would cost another 15–30 seconds in the middle of someone's sentence, and
  /// asking a 2B model to compress a conversation is where invention starts.
  ///
  /// Returns null when there is nothing worth carrying.
  static String? compact(List<String> userTurns) {
    final seen = <String>{};
    final substantive = userTurns
        .map((t) => t.trim())
        .where((t) => t.length >= 15 && !QuickPrompt.isSeed(t))
        .where((t) => seen.add(_dedupeKey(t)))
        .toList();
    if (substantive.isEmpty) return null;

    final topics = <String>{};
    for (final turn in substantive) {
      topics.addAll(TopicExtractor.extract(turn));
    }

    // Longest turns as a proxy for substance — the same crude, reliable rule
    // the session summary uses — then restored to the order they were said so
    // the result reads as a conversation rather than a ranking.
    final ranked = List<String>.from(substantive)
      ..sort((a, b) => b.length.compareTo(a.length));
    final chosen = ranked.take(maxQuotedLines).toSet();
    final lines = substantive.where(chosen.contains).toList();

    final buffer = StringBuffer('Earlier in this conversation');
    if (topics.isNotEmpty) {
      buffer.write(', they talked about ${topics.join(', ')}');
    }
    buffer.write('.');
    for (final line in lines) {
      buffer.writeln();
      buffer.write('They said: ${_trim(line)}');
    }
    return buffer.toString();
  }

  /// Comparison form for spotting a line already quoted — case and punctuation
  /// insensitive, so trailing punctuation does not make a repeat look new.
  static String _dedupeKey(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _trim(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= 160) return t;
    final cut = t.lastIndexOf(' ', 160);
    return '${t.substring(0, cut > 40 ? cut : 160)}…';
  }

  static String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}
