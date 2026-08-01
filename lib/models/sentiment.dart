/// A coarse emotional register for a single message.
///
/// Six bands rather than a continuous score, because everything downstream —
/// the relationship log, the nudge composer, the prompt's mood line — needs a
/// word, not a number. The number is kept alongside as [MoodReading.valence]
/// for trend maths.
enum MoodLabel {
  /// Acute distress. Not the same as a crisis: `CrisisGuard` handles statements
  /// of intent, this is "everything is falling apart".
  distressed,

  /// Flat, heavy, sad.
  low,

  /// Worried, tense, wound up. Negative but activated, unlike [low].
  anxious,

  /// Nothing strongly signalled either way. The common case.
  neutral,

  /// Warm, settled, quietly positive.
  hopeful,

  /// Actively good news.
  bright;

  static MoodLabel fromName(String name) => MoodLabel.values
      .firstWhere((m) => m.name == name, orElse: () => MoodLabel.neutral);

  bool get isNegative =>
      this == distressed || this == low || this == anxious;

  bool get isPositive => this == hopeful || this == bright;

  /// Plain-language description used in the relationship block and in nudges.
  String get description => switch (this) {
        MoodLabel.distressed => 'in acute distress',
        MoodLabel.low => 'low and heavy',
        MoodLabel.anxious => 'anxious and wound up',
        MoodLabel.neutral => 'even',
        MoodLabel.hopeful => 'quietly hopeful',
        MoodLabel.bright => 'genuinely bright',
      };
}

/// The result of reading one message.
class MoodReading {
  final MoodLabel label;

  /// -1 (worst) to 1 (best).
  final double valence;

  /// 0 to 1 — how much evidence there was. A message with no affective words
  /// scores 0 and should not move a trend.
  final double confidence;

  const MoodReading({
    required this.label,
    required this.valence,
    this.confidence = 0,
  });

  static const neutral = MoodReading(label: MoodLabel.neutral, valence: 0);

  /// Whether this reading is strong enough to act on.
  ///
  /// Most messages are not. Treating every "ok" as a mood signal is how a
  /// companion ends up commenting on feelings the user never expressed.
  bool get isSignal => confidence >= 0.35 && label != MoodLabel.neutral;

  @override
  String toString() =>
      '${label.name}(${valence.toStringAsFixed(2)}, c=${confidence.toStringAsFixed(2)})';
}
