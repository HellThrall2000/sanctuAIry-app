import '../models/upcoming_event.dart';

/// Finds things the user said are coming up.
///
/// **Anchored on the time expression, not the noun.** The safe way to do this
/// without a model is to require an explicit "tomorrow" / "on Friday" / "next
/// week" and take the noun phrase attached to it. Trying it the other way —
/// looking for event-shaped nouns and hoping a date is nearby — produces
/// confident nonsense from sentences like *"I hate job interviews"*.
///
/// The same discipline `FactExtractor` arrived at the hard way: a verb
/// blocklist is never complete, and *"my therapist suggested journaling"* once
/// recorded a therapist named *"suggested"*. Better to miss events than to ask
/// someone how their "hate" went.
abstract final class EventExtractor {
  /// Time expressions, and how to resolve them relative to when they were said.
  ///
  /// Resolution is deliberately coarse — a day's granularity is enough for
  /// "how did it go?" and pretending to know the hour would be false precision.
  static final _when = <RegExp, DateTime Function(DateTime, Match)>{
    RegExp(r'\btomorrow\b', caseSensitive: false): (now, _) =>
        _atEndOfDay(now.add(const Duration(days: 1))),
    RegExp(r'\b(?:later\s+)?(?:today|tonight|this\s+(?:evening|afternoon))\b',
        caseSensitive: false): (now, _) => _atEndOfDay(now),
    RegExp(r'\bthis\s+weekend\b', caseSensitive: false): (now, _) =>
        _atEndOfDay(_nextWeekday(now, DateTime.sunday)),
    RegExp(r'\bnext\s+week\b', caseSensitive: false): (now, _) =>
        _atEndOfDay(now.add(const Duration(days: 7))),
    RegExp(r'\bnext\s+month\b', caseSensitive: false): (now, _) =>
        _atEndOfDay(now.add(const Duration(days: 30))),
    RegExp(r'\bin\s+(\d{1,2})\s+days?\b', caseSensitive: false): (now, m) =>
        _atEndOfDay(now.add(Duration(days: int.parse(m.group(1)!)))),
    RegExp(r'\bin\s+(\d{1,2})\s+hours?\b', caseSensitive: false): (now, m) =>
        now.add(Duration(hours: int.parse(m.group(1)!))),
    RegExp(r'\bin\s+(?:a|1)\s+week\b', caseSensitive: false): (now, _) =>
        _atEndOfDay(now.add(const Duration(days: 7))),
    RegExp(
      r'\b(?:on\s+|next\s+|this\s+)?'
      r'(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
      caseSensitive: false,
    ): (now, m) => _atEndOfDay(_nextWeekday(now, _weekday(m.group(1)!))),
  };

  /// One combined alternation for locating *where* the time expression is.
  static final _anyWhen = RegExp(
    r'\b('
    r'tomorrow'
    r'|(?:later\s+)?(?:today|tonight|this\s+(?:evening|afternoon))'
    r'|this\s+weekend'
    r'|next\s+(?:week|month)'
    r'|in\s+\d{1,2}\s+(?:days?|hours?)'
    r'|in\s+(?:a|1)\s+week'
    r'|(?:on\s+|next\s+|this\s+)?'
    r'(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)'
    r')\b',
    caseSensitive: false,
  );

  /// The frames that introduce an event.
  ///
  /// Each captures the noun phrase in group 1. Requiring one of these — rather
  /// than accepting any noun near a date — is what keeps *"tomorrow is going to
  /// be awful"* from being filed as an event called "going".
  static final _frames = <RegExp>[
    // "I have an interview", "I've got my exam", "I have a scan"
    RegExp(
      r"\bi(?:'?ve)?\s+(?:have|have\s+got|got)\s+"
      r"(?:an?|my|the)\s+([a-z][a-z\s'-]{2,38}?)\s*(?=\b|,|\.|$)",
      caseSensitive: false,
    ),
    // "my exam is", "my interview's"
    RegExp(
      r"\bmy\s+([a-z][a-z\s'-]{2,38}?)\s+(?:is|starts|begins|happens)\b",
      caseSensitive: false,
    ),
    // "I'm seeing the consultant", "I am meeting Sara"
    //
    // The determiner is consumed rather than captured. Without that group the
    // lazy capture stops at the first word boundary it can reach, which is the
    // end of "the" — so "seeing the consultant" was recorded as an event called
    // "seeing the".
    RegExp(
      r"\bi(?:'?m|\s+am)\s+(seeing|meeting|starting|moving|flying|travelling|"
      r"traveling|visiting|presenting|performing)\s+"
      r"(?:(?:the|a|an|my|our)\s+)?([a-z][a-z\s'-]{2,30}?)\s*(?=\b|,|\.|$)",
      caseSensitive: false,
    ),
  ];

  /// Words that are never an event on their own — usually a captured fragment
  /// of the surrounding sentence rather than a thing that happens.
  static const _notEvents = {
    'lot', 'lots', 'bit', 'time', 'day', 'week', 'feeling', 'idea', 'thing',
    'things', 'go', 'going', 'been', 'no', 'none', 'nothing', 'it', 'that',
    'work', 'to do', 'a lot',
  };

  /// Events mentioned in [text].
  ///
  /// Returns empty for most messages, which is correct.
  static List<UpcomingEvent> extract(String text, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final whenMatch = _anyWhen.firstMatch(text);
    if (whenMatch == null) return const [];

    final rawWhen = whenMatch.group(0)!.trim();
    final dueAt = _resolve(rawWhen, at);

    final found = <UpcomingEvent>[];
    final seen = <String>{};

    for (final frame in _frames) {
      for (final m in frame.allMatches(text)) {
        // The third frame captures a verb in group 1 and its object in group 2.
        final phrase = (m.groupCount >= 2 && m.group(2) != null)
            ? '${m.group(1)} ${m.group(2)}'
            : m.group(1);
        final cleaned = _clean(phrase);
        if (cleaned == null || !seen.add(cleaned.toLowerCase())) continue;

        // Keyed by what the event is and which day it falls on, not by when it
        // was mentioned. Someone who brings the same interview up three times
        // has one interview, and a timestamped id gave three rows — so the
        // companion would ask how it went, mark that row asked, and then ask
        // again from the duplicate. Re-mentioning now refreshes the row.
        final day = dueAt == null
            ? 'unscheduled'
            : '${dueAt.year}-${dueAt.month}-${dueAt.day}';
        found.add(UpcomingEvent(
          id: 'event:$day:${cleaned.toLowerCase()}',
          text: cleaned,
          rawWhen: rawWhen,
          dueAt: dueAt,
          evidence: text.trim(),
          createdAt: at,
        ));
      }
    }
    return found;
  }

  /// Trims a captured phrase and rejects the ones that are not events.
  static String? _clean(String? phrase) {
    if (phrase == null) return null;
    var out = phrase.trim().toLowerCase();

    // Strip a trailing time expression the frame may have swallowed —
    // "an interview tomorrow" captures "interview tomorrow".
    out = out.replaceAll(_anyWhen, '').trim();
    // And trailing connectives left behind by that removal.
    out = out.replaceAll(RegExp(r'\s+(?:at|on|in|for|with|and)$'), '').trim();
    // A determiner the frame did not consume — "the consultant" is the event
    // "consultant", and leaving the article in makes a nudge read as
    // "how did the the consultant go?".
    out = out.replaceFirst(RegExp(r'^(?:the|a|an|my|our)\s+'), '').trim();
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ');

    if (out.length < 3 || out.length > 40) return null;
    if (_notEvents.contains(out)) return null;
    // A phrase of only stop-ish words is a capture failure, not an event.
    if (!RegExp(r'[a-z]{3,}').hasMatch(out)) return null;
    return out;
  }

  static DateTime? _resolve(String rawWhen, DateTime now) {
    for (final entry in _when.entries) {
      final m = entry.key.firstMatch(rawWhen);
      if (m != null) return entry.value(now, m);
    }
    return null;
  }

  /// End of [day], so an event is only "passed" once its whole day is over.
  static DateTime _atEndOfDay(DateTime day) =>
      DateTime(day.year, day.month, day.day, 23, 59);

  /// The next occurrence of [weekday], treating today as already gone —
  /// someone saying "on Friday" on a Friday means the next one.
  static DateTime _nextWeekday(DateTime from, int weekday) {
    var delta = (weekday - from.weekday) % 7;
    if (delta == 0) delta = 7;
    return from.add(Duration(days: delta));
  }

  static int _weekday(String name) => switch (name.toLowerCase()) {
        'monday' => DateTime.monday,
        'tuesday' => DateTime.tuesday,
        'wednesday' => DateTime.wednesday,
        'thursday' => DateTime.thursday,
        'friday' => DateTime.friday,
        'saturday' => DateTime.saturday,
        _ => DateTime.sunday,
      };
}
