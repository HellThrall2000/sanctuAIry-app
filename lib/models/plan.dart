import 'package:flutter/foundation.dart';

/// How much a to-do matters. Three levels, not five — a scale nobody can use
/// consistently is a scale that means nothing.
enum TodoPriority {
  low,
  normal,
  high;

  static TodoPriority fromName(String name) => TodoPriority.values.firstWhere(
        (p) => p.name == name,
        orElse: () => TodoPriority.normal,
      );
}

/// One item on the list.
///
/// Deliberately separate from `upcoming_events`, which look similar and are not:
/// an event is something that *happens to you* at a time, extracted from what
/// you said, and retired once it has passed. A to-do is something *you decide to
/// do*, has no natural expiry, and is only ever finished by you ticking it.
/// Folding them together would mean either events you have to tick off or
/// to-dos that silently disappear.
@immutable
class Todo {
  final String id;
  final String text;

  /// Null until it is ticked. A timestamp rather than a bool so a "done today"
  /// list is possible without a second column.
  final DateTime? completedAt;

  /// Optional. Most to-dos never get one, which is why it is not a deadline.
  final DateTime? dueAt;

  final TodoPriority priority;
  final DateTime createdAt;

  const Todo({
    required this.id,
    required this.text,
    required this.createdAt,
    this.completedAt,
    this.dueAt,
    this.priority = TodoPriority.normal,
  });

  bool get isDone => completedAt != null;

  /// Overdue only counts for something not yet done — a task finished late is
  /// finished, and colouring it red afterwards is just scolding.
  bool isOverdue([DateTime? now]) {
    final due = dueAt;
    if (due == null || isDone) return false;
    return due.isBefore(now ?? DateTime.now());
  }

  Todo toggled({DateTime? at}) => copyWith(
        completedAt: isDone ? null : (at ?? DateTime.now()),
        clearCompletedAt: isDone,
      );

  Todo copyWith({
    String? text,
    DateTime? completedAt,
    DateTime? dueAt,
    TodoPriority? priority,
    bool clearCompletedAt = false,
    bool clearDueAt = false,
  }) =>
      Todo(
        id: id,
        text: text ?? this.text,
        createdAt: createdAt,
        completedAt:
            clearCompletedAt ? null : (completedAt ?? this.completedAt),
        dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
        priority: priority ?? this.priority,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'text': text,
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'dueAt': dueAt?.toUtc().toIso8601String(),
        'priority': priority.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory Todo.fromMap(Map<String, Object?> map) {
    DateTime? at(Object? v) =>
        v == null ? null : DateTime.parse(v as String).toLocal();
    return Todo(
      id: map['id'] as String,
      text: map['text'] as String,
      completedAt: at(map['completedAt']),
      dueAt: at(map['dueAt']),
      priority: TodoPriority.fromName(map['priority'] as String? ?? 'normal'),
      createdAt: at(map['createdAt'])!,
    );
  }
}

/// A recurring block in the day — "Gym, 18:00–19:00, Mon/Wed/Fri".
///
/// A *routine*, not a calendar. The app has no calendar integration and should
/// not pretend to: this is the shape of a normal week, which is what a companion
/// can actually be useful about ("you usually run on Wednesdays"). One-off
/// commitments belong in `upcoming_events`, which already extracts them from
/// what the user says.
@immutable
class RoutineBlock {
  final String id;
  final String label;

  /// Minutes after local midnight. An int rather than a `TimeOfDay` because it
  /// has to survive a database round trip, sort, and compare without a Flutter
  /// import in the model layer.
  final int startMinute;

  /// Null for a moment rather than a span — "take meds at 9" has no end.
  final int? endMinute;

  /// Days this repeats on, as `DateTime.monday`..`DateTime.sunday` (1–7).
  ///
  /// A set rather than a bitmask: a bitmask saves six bytes and costs every
  /// future reader ten minutes.
  final Set<int> weekdays;

  final DateTime createdAt;

  const RoutineBlock({
    required this.id,
    required this.label,
    required this.startMinute,
    required this.weekdays,
    required this.createdAt,
    this.endMinute,
  });

  bool get isEveryDay => weekdays.length == 7;

  bool occursOn(DateTime day) => weekdays.contains(day.weekday);

  /// `540` -> `'09:00'`.
  static String formatMinute(int minute) {
    final h = (minute ~/ 60) % 24;
    final m = minute % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String get timeLabel => endMinute == null
      ? formatMinute(startMinute)
      : '${formatMinute(startMinute)}–${formatMinute(endMinute!)}';

  /// "Every day", "Weekdays", "Mon, Wed, Fri".
  String get repeatLabel {
    if (isEveryDay) return 'Every day';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final sorted = weekdays.toList()..sort();
    if (sorted.length == 5 && sorted.every((d) => d <= 5)) return 'Weekdays';
    if (sorted.length == 2 && sorted.every((d) => d >= 6)) return 'Weekends';
    return sorted.map((d) => names[d - 1]).join(', ');
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'label': label,
        'startMinute': startMinute,
        'endMinute': endMinute,
        // Sorted and comma-joined so the stored form is stable and diffable.
        'weekdays': (weekdays.toList()..sort()).join(','),
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory RoutineBlock.fromMap(Map<String, Object?> map) {
    final raw = (map['weekdays'] as String? ?? '').split(',');
    final days = <int>{
      for (final part in raw)
        if (int.tryParse(part.trim()) case final d?)
          if (d >= 1 && d <= 7) d,
    };
    return RoutineBlock(
      id: map['id'] as String,
      label: map['label'] as String,
      startMinute: (map['startMinute'] as num).toInt(),
      endMinute: (map['endMinute'] as num?)?.toInt(),
      // An empty set would make a block that never occurs and can never be
      // found again; fall back to every day so it stays visible and fixable.
      weekdays: days.isEmpty ? {1, 2, 3, 4, 5, 6, 7} : days,
      createdAt: DateTime.parse(map['createdAt'] as String).toLocal(),
    );
  }
}
