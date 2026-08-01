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

  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.mood,
    this.sentToModel = true,
  });

  bool get isUser => role == ChatRole.user;

  ChatMessage copyWith({String? text, MoodReading? mood}) => ChatMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        mood: mood ?? this.mood,
        sentToModel: sentToModel,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'role': role.name,
        'text': text,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'moodLabel': mood?.label.name,
        'moodScore': mood?.valence,
        'sentToModel': sentToModel ? 1 : 0,
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
    );
  }
}
