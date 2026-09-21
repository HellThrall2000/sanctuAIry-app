/// A set of weekdays, as `DateTime.monday`..`DateTime.sunday` (1–7).
///
/// **A set rather than a bitmask**: a bitmask saves six bytes and costs every
/// future reader ten minutes. That reasoning was already written down inside
/// `RoutineBlock`; this exists because a second thing now needs it — a habit
/// that only applies on some days — and a second copy of the parsing, the
/// sorting and the "Mon, Wed, Fri" formatting would be the point at which the
/// two quietly start disagreeing about what "Weekends" means.
abstract final class Weekdays {
  const Weekdays._();

  /// Every day, in the order a week is read.
  static const all = {1, 2, 3, 4, 5, 6, 7};

  static const monday = DateTime.monday;
  static const saturday = DateTime.saturday;

  static const shortNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const longNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', //
    'Friday', 'Saturday', 'Sunday',
  ];

  /// Whether [days] means "no restriction".
  ///
  /// Empty and all-seven are the same thing to a reader and deliberately stay
  /// distinguishable in storage: empty is what a goal created without a
  /// schedule holds, seven is what someone ticked by hand. Neither should ever
  /// render as a list of seven day names.
  static bool isEveryDay(Set<int> days) => days.isEmpty || days.length >= 7;

  /// "Every day", "Weekdays", "Weekends", "Mon, Wed, Fri".
  static String label(Set<int> days) {
    if (isEveryDay(days)) return 'Every day';
    final sorted = days.toList()..sort();
    if (sorted.length == 5 && sorted.every((d) => d <= 5)) return 'Weekdays';
    if (sorted.length == 2 && sorted.every((d) => d >= 6)) return 'Weekends';
    return sorted.map((d) => shortNames[d - 1]).join(', ');
  }

  /// `{1,3,5}` -> `'1,3,5'`. Sorted so the stored form is stable and diffable.
  static String encode(Set<int> days) => (days.toList()..sort()).join(',');

  /// Parses what [encode] wrote, discarding anything out of range.
  ///
  /// Silently lenient rather than throwing: these strings come out of SQLite,
  /// and a row written by an older or newer build must never crash a read.
  static Set<int> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    return {
      for (final part in raw.split(','))
        if (int.tryParse(part.trim()) case final d?)
          if (d >= 1 && d <= 7) d,
    };
  }

  /// The weekday [word] names, or null. Understands "mon", "monday",
  /// "tuesdays", and the two group words.
  ///
  /// Returns a *set* because "weekdays" and "weekends" are single words that
  /// mean several days — the caller should not have to special-case them.
  static Set<int>? parse(String word) {
    final w = word.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (w.isEmpty) return null;
    if (w == 'everyday' || w == 'daily' || w == 'everydays') return all;
    if (w == 'weekday' || w == 'weekdays') return const {1, 2, 3, 4, 5};
    if (w == 'weekend' || w == 'weekends') return const {6, 7};
    for (var i = 0; i < longNames.length; i++) {
      final long = longNames[i].toLowerCase();
      final short = shortNames[i].toLowerCase();
      // "tuesdays" and "tues" both land on Tuesday.
      if (w == long || w == '${long}s' || w == short || long.startsWith(w) && w.length >= 3) {
        return {i + 1};
      }
    }
    return null;
  }
}
