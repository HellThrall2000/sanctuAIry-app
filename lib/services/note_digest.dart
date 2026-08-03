import '../models/journal_entry.dart';

/// A diary entry shrunk to the points worth carrying.
class NoteDigest {
  final String entryId;
  final String title;
  final DateTime date;

  /// The sentences that actually carry the entry, in the user's own words.
  final List<String> points;

  const NoteDigest({
    required this.entryId,
    required this.title,
    required this.date,
    required this.points,
  });

  bool get isEmpty => points.isEmpty && title.trim().isEmpty;

  /// One line per point, prefixed with the date and title.
  String render() {
    final buffer = StringBuffer('${_shortDate(date)} — $title');
    for (final point in points) {
      buffer.writeln();
      buffer.write('  · $point');
    }
    return buffer.toString();
  }

  static String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

/// Shrinks a diary entry to its main pointers.
///
/// **Why entries are never pasted in whole.** The system instruction used to
/// contain every permitted entry in full, which does not survive contact with a
/// real diary: the container is 4096 tokens and also has to hold the persona,
/// the profile, the relationship block and room to generate. A user with thirty
/// entries had no context left to think in — and the failure is silent, because
/// an overflowing prompt does not raise, it just quietly stops working.
///
/// **Extractive, not abstractive.** No model runs here. A generation pass costs
/// 15–30 s on this device and would have to happen while the user waits, and
/// paraphrasing someone's diary is exactly where a small model invents. These
/// are the user's own sentences, selected — so a quoted point is always
/// something they actually wrote.
abstract final class NoteDigester {
  /// Most points kept from one entry.
  ///
  /// Four is enough to carry a diary entry's substance and small enough that
  /// thirty entries still fit in the episodic budget.
  static const int maxPoints = 4;

  /// Longest a single point may be before it is trimmed.
  static const int maxPointLength = 180;

  /// Sentences shorter than this are fragments, not points.
  static const int minPointLength = 25;

  /// Words that mark a sentence as carrying the substance of an entry.
  ///
  /// Weighted rather than filtered: a sentence with none of these can still be
  /// kept if it is the only thing in the entry.
  static const _salient = {
    // feeling
    'feel', 'felt', 'feeling', 'afraid', 'scared', 'angry', 'sad', 'happy',
    'anxious', 'lonely', 'tired', 'ashamed', 'guilty', 'proud', 'relieved',
    'hurt', 'worried', 'hopeful', 'exhausted', 'overwhelmed',
    // change and event
    'started', 'stopped', 'quit', 'left', 'moved', 'died', 'broke', 'ended',
    'began', 'decided', 'realised', 'realized', 'finally', 'first', 'last',
    'happened', 'told', 'said', 'asked', 'called', 'met',
    // significance
    'never', 'always', 'again', 'because', 'but', 'still', 'important',
    'matters', 'need', 'want', 'wish', 'hope', 'cannot', 'should',
  };

  /// Shrinks [entry] to its points.
  ///
  /// Returns an empty digest for an entry with no usable content rather than
  /// inventing one.
  static NoteDigest digest(JournalEntry entry) {
    final sentences = _sentences(entry.content);

    // Score by salience, then keep the originals in their written order — a
    // digest that reorders someone's entry reads as a summary of a different
    // day.
    final scored = <({int index, String text, double score})>[];
    for (var i = 0; i < sentences.length; i++) {
      final text = sentences[i];
      scored.add((index: i, text: text, score: _score(text, i, sentences.length)));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final kept = scored.take(maxPoints).toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    return NoteDigest(
      entryId: entry.id,
      title: entry.title.trim(),
      date: DateTime.tryParse(entry.date)?.toLocal() ?? DateTime.now(),
      points: kept.map((s) => _trim(s.text)).toList(growable: false),
    );
  }

  static double _score(String sentence, int index, int total) {
    final words = sentence
        .toLowerCase()
        .replaceAll(RegExp(r"['’]"), '')
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return 0;

    var score = 0.0;
    for (final w in words) {
      if (_salient.contains(w)) score += 1.0;
    }
    // Normalise so a long rambling sentence does not win on volume alone.
    score /= (1 + words.length / 25.0);

    // People put the point at the start or the end of an entry far more often
    // than in the middle.
    if (index == 0) score += 0.6;
    if (index == total - 1 && total > 1) score += 0.4;

    return score;
  }

  static List<String> _sentences(String content) {
    return RegExp(r'[^.!?\n]+[.!?]*')
        .allMatches(content)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.length >= minPointLength)
        .toList(growable: false);
  }

  static String _trim(String sentence) {
    final s = sentence.trim();
    if (s.length <= maxPointLength) return s;
    // Cut at a word boundary so a point never ends mid-word.
    final cut = s.lastIndexOf(' ', maxPointLength);
    return '${s.substring(0, cut > 40 ? cut : maxPointLength)}…';
  }
}
