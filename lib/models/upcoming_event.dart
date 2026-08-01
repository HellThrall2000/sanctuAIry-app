/// Something the user said was coming up.
///
/// The whole point of storing these is that a check-in can be *"how did the
/// interview go?"* rather than *"just checking in"*. The first is a companion
/// remembering; the second is a retention notification wearing its clothes.
class UpcomingEvent {
  final String id;

  /// The event itself, as a noun phrase — "an interview", "my exam".
  final String text;

  /// The time expression exactly as the user wrote it — "on Friday".
  final String? rawWhen;

  /// [rawWhen] resolved against the moment it was said. Null when it could not
  /// be resolved, which still leaves the event usable for a vaguer follow-up.
  final DateTime? dueAt;

  /// The sentence it came from, so the user can be shown why the companion
  /// thinks this.
  final String evidence;

  /// Whether the companion has already asked how it went. Asking twice is
  /// worse than not asking.
  final bool askedAfter;

  final DateTime createdAt;

  const UpcomingEvent({
    required this.id,
    required this.text,
    required this.evidence,
    required this.createdAt,
    this.rawWhen,
    this.dueAt,
    this.askedAfter = false,
  });

  /// Whether the event's moment has passed and it is fair to ask about it.
  bool hasPassed(DateTime now) => dueAt != null && now.isAfter(dueAt!);

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'rawWhen': rawWhen,
        'dueAt': dueAt?.toUtc().toIso8601String(),
        'evidence': evidence,
        'askedAfter': askedAfter ? 1 : 0,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory UpcomingEvent.fromMap(Map<String, Object?> map) {
    final due = map['dueAt'] as String?;
    return UpcomingEvent(
      id: map['id'] as String,
      text: map['text'] as String,
      rawWhen: map['rawWhen'] as String?,
      dueAt: due == null ? null : DateTime.parse(due).toLocal(),
      evidence: map['evidence'] as String,
      askedAfter: (map['askedAfter'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(map['createdAt'] as String).toLocal(),
    );
  }
}
