import 'package:flutter/foundation.dart';

/// Changes made to the tracker that the companion has not spoken about yet.
///
/// **Why a feed rather than a flag.** `MemoryCache.onPlanChanged` already tells
/// the companion that *something* moved — it rebuilds the wellness block so the
/// next reply is answered from current facts. What it cannot say is *what*
/// moved, and "I see you changed something" is not worth saying out loud. This
/// carries the words.
///
/// **The text is written, not generated.** Same trade as `DailyReview`: a line
/// acknowledging a tap has to appear at the moment of the tap, and a 15–30 s
/// generation to say "noted" is the wrong place to spend the only inference
/// this device can do. The model's turn comes on the next message, by which
/// point it can see the change in its own context.
class TrackerFeed extends ChangeNotifier {
  static final TrackerFeed instance = TrackerFeed._();

  TrackerFeed._();

  final List<String> _pending = [];

  /// How many changes a single line will name before it stops naming them.
  ///
  /// Someone reorganising their week can touch a dozen things in a minute, and
  /// a sentence listing twelve of them is not a companion noticing, it is a
  /// receipt.
  static const int maxNamed = 3;

  /// Records a past-tense fragment: "added meditation 20 minutes".
  ///
  /// Fragments rather than sentences so several can be joined into one line,
  /// which is what keeps a burst of edits from becoming a burst of messages.
  void record(String change) {
    final text = change.trim();
    if (text.isEmpty) return;
    _pending.add(text);
    notifyListeners();
  }

  bool get hasPending => _pending.isNotEmpty;

  /// Drains everything waiting. Consumed once — a change is acknowledged once.
  List<String> take() {
    final all = List<String>.unmodifiable(_pending);
    _pending.clear();
    return all;
  }

  /// The line to post, or null when nothing is waiting.
  ///
  /// Deliberately one sentence and deliberately flat. This is the app speaking,
  /// not the companion improvising, and the honest register for that is a
  /// short acknowledgement — anything more enthusiastic would be the app
  /// putting words in the companion's mouth that it did not choose.
  static String? messageFor(List<String> changes) {
    if (changes.isEmpty) return null;
    if (changes.length > maxNamed) {
      return 'Noted — ${changes.length} changes to your tracker.';
    }
    return 'Noted — ${_list(changes)}.';
  }

  static String _list(List<String> items) => switch (items.length) {
        0 => '',
        1 => items.first,
        2 => '${items[0]} and ${items[1]}',
        _ => '${items.sublist(0, items.length - 1).join(', ')} '
            'and ${items.last}',
      };
}
