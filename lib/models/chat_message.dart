import 'sentiment.dart';

/// Who produced a turn.
enum ChatRole {
  user,

  /// The model's reply.
  companion,

  /// Text the app produced: initialisation banners, guard responses, nudges,
  /// crisis resources. On screen, but never generated and never in the model's
  /// context.
  system;

  static ChatRole fromName(String name) =>
      ChatRole.values.firstWhere((r) => r.name == name, orElse: () => system);
}

/// How far a user's message has got, shown as ticks on their own bubbles.
///
/// Borrowed from messaging apps because the wait here is long — the model takes
/// 15–30 s, and before this the screen gave no sign of whether anything was
/// happening. The three states are the three real stages, not decoration.
///
/// Not persisted. It is derived on restore from whether a reply follows, which
/// is always correct and costs no migration.
enum MessageDelivery {
  /// Written down, but the companion is not awake yet — the model is still
  /// being mapped into memory. One grey tick.
  sent,

  /// The companion has the message and is composing a reply. Two grey ticks.
  processing,

  /// A reply exists. Two blue ticks.
  read,
}

/// One line of the conversation, as stored.
///
/// Persisted in `chat_messages` and never deleted except by explicit user
/// action. Until v3 the transcript existed only in widget state, so every
/// conversation was destroyed when the process died — which for a companion
/// meant the relationship reset every time the user closed the app.
class ChatMessage {
  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;

  /// How the user sounded, on their own turns. Null on everything else.
  final MoodReading? mood;

  /// Whether the model actually saw this turn.
  ///
  /// False for banners, guard replies and nudges. [ChatRole.system] text is on
  /// screen but was never in the model's context, and replaying it as history
  /// would teach the companion to imitate the app's own voice.
  final bool sentToModel;

  /// Only meaningful on [ChatRole.user] messages.
  final MessageDelivery delivery;

  /// The [id] of the message this one answers, or null for the ordinary case.
  ///
  /// Set only on [ChatRole.companion] turns, and only when the reply is not
  /// simply an answer to the line directly above it — after a restart, or when
  /// the user sent a run of messages faster than the companion could reply. In
  /// a straight back-and-forth the target is obvious and quoting it is noise,
  /// which is why this is nullable rather than always populated.
  ///
  /// Not a foreign key. Deleting a single message is a user action and must not
  /// cascade into rewriting replies that referred to it; a dangling id simply
  /// renders without a quote.
  final String? replyToId;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.mood,
    this.sentToModel = true,
    this.delivery = MessageDelivery.read,
    this.replyToId,
  });

  bool get isUser => role == ChatRole.user;

  ChatMessage copyWith({
    String? text,
    MoodReading? mood,
    MessageDelivery? delivery,
    String? replyToId,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        mood: mood ?? this.mood,
        sentToModel: sentToModel,
        delivery: delivery ?? this.delivery,
        replyToId: replyToId ?? this.replyToId,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'role': role.name,
        'text': text,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'moodLabel': mood?.label.name,
        'moodScore': mood?.valence,
        'sentToModel': sentToModel ? 1 : 0,
        'replyToId': replyToId,
      };

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    final label = map['moodLabel'] as String?;
    final score = map['moodScore'] as num?;
    return ChatMessage(
      id: map['id'] as String,
      role: ChatRole.fromName(map['role'] as String),
      text: map['text'] as String,
      createdAt:
          DateTime.parse(map['createdAt'] as String).toLocal(),
      mood: label == null
          ? null
          : MoodReading(
              label: MoodLabel.fromName(label),
              valence: score?.toDouble() ?? 0,
            ),
      sentToModel: (map['sentToModel'] as int? ?? 1) == 1,
      // Absent on rows written before v4, and absent entirely if that migration
      // was skipped — see `DatabaseService._addReplyToColumn`.
      replyToId: map['replyToId'] as String?,
    );
  }
}
