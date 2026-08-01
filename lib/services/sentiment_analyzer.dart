import '../models/sentiment.dart';

/// Reads the emotional register of a message.
///
/// **Why not a model.** A learned classifier would be more accurate, but every
/// generation on this device costs 15–30 s and the runtime holds one
/// conversation at a time — routing each turn through a second inference before
/// replying would double the wait on the one interaction the whole app exists
/// for. This runs in microseconds and is good enough for what it feeds:
/// a trend line, a nudge's tone, and a topic tally. Nothing here gates safety —
/// that is `Guard` and `CrisisGuard`, which are deliberately separate.
///
/// **Valence, plus activation.** "I'm exhausted" and "I'm panicking" are both
/// negative, and treating them the same produces a companion that answers
/// panic with the pacing you would use for grief. So negative terms carry an
/// activation flag and split [MoodLabel.low] from [MoodLabel.anxious].
abstract final class SentimentAnalyzer {
  /// Weight, and whether the term is *activated* (tense/agitated) rather than
  /// flat. Weights are deliberately coarse — 1 for ordinary, 2 for severe.
  static const Map<String, ({double w, bool activated})> _negative = {
    // Flat / heavy
    'sad': (w: 1, activated: false),
    'unhappy': (w: 1, activated: false),
    'down': (w: 1, activated: false),
    'low': (w: 1, activated: false),
    'empty': (w: 1.5, activated: false),
    'numb': (w: 1.5, activated: false),
    'flat': (w: 1, activated: false),
    'tired': (w: 1, activated: false),
    'exhausted': (w: 1.5, activated: false),
    'drained': (w: 1.5, activated: false),
    'lonely': (w: 1.5, activated: false),
    'alone': (w: 1, activated: false),
    'isolated': (w: 1.5, activated: false),
    'depressed': (w: 2, activated: false),
    'miserable': (w: 2, activated: false),
    'grief': (w: 2, activated: false),
    'heartbroken': (w: 2, activated: false),
    'hopeless': (w: 2, activated: false),
    'worthless': (w: 2, activated: false),
    'defeated': (w: 1.5, activated: false),
    'ashamed': (w: 1.5, activated: false),
    'guilty': (w: 1, activated: false),
    'regret': (w: 1, activated: false),
    'crying': (w: 1.5, activated: false),
    'cried': (w: 1.5, activated: false),
    'hurt': (w: 1, activated: false),
    'lost': (w: 1, activated: false),
    'stuck': (w: 1, activated: false),
    'bored': (w: 0.5, activated: false),

    // Self-criticism. Its own cluster because the first version of this list
    // had none of it, and *"i feel like such a failure"* scored a flat neutral
    // with zero confidence — so the companion had no signal and celebrated a
    // job offer the user had just said they did not get. For a mental-health
    // app this is core vocabulary, not an edge case: it is how people report
    // the thing they most need to be met on.
    //
    // All flat rather than activated. Self-criticism reads as heaviness, not
    // agitation, and pacing it like panic gets the response wrong.
    'failure': (w: 1.5, activated: false),
    'failed': (w: 1.25, activated: false),
    'failing': (w: 1.25, activated: false),
    'useless': (w: 1.75, activated: false),
    'pathetic': (w: 1.75, activated: false),
    'inadequate': (w: 1.5, activated: false),
    'unlovable': (w: 2, activated: false),
    'burden': (w: 1.75, activated: false),
    'broken': (w: 1.5, activated: false),
    'disappointment': (w: 1.5, activated: false),
    'embarrassed': (w: 1.25, activated: false),
    'humiliated': (w: 1.75, activated: false),
    'rejected': (w: 1.5, activated: false),
    'unwanted': (w: 1.5, activated: false),
    'loser': (w: 1.5, activated: false),
    'stupid': (w: 1.25, activated: false),
    'weak': (w: 1, activated: false),

    // Activated / tense
    'anxious': (w: 1.5, activated: true),
    'anxiety': (w: 1.5, activated: true),
    'panic': (w: 2, activated: true),
    'panicking': (w: 2, activated: true),
    'scared': (w: 1.5, activated: true),
    'afraid': (w: 1.5, activated: true),
    'terrified': (w: 2, activated: true),
    'worried': (w: 1, activated: true),
    'worry': (w: 1, activated: true),
    'nervous': (w: 1, activated: true),
    'stressed': (w: 1.5, activated: true),
    'stress': (w: 1.5, activated: true),
    'overwhelmed': (w: 2, activated: true),
    'angry': (w: 1.5, activated: true),
    'furious': (w: 2, activated: true),
    'frustrated': (w: 1, activated: true),
    'irritated': (w: 1, activated: true),
    'annoyed': (w: 0.5, activated: true),
    'restless': (w: 1, activated: true),
    'dread': (w: 1.5, activated: true),
    'freaking': (w: 1.5, activated: true),
    'tense': (w: 1, activated: true),
    'awful': (w: 1.5, activated: true),
    'terrible': (w: 1.5, activated: true),
    'horrible': (w: 1.5, activated: true),
    'unbearable': (w: 2, activated: true),
  };

  static const Map<String, double> _positive = {
    'happy': 1.5,
    'glad': 1,
    'good': 0.75,
    'great': 1.5,
    'wonderful': 2,
    'amazing': 2,
    'excited': 1.5,
    'exciting': 1.5,
    'grateful': 1.5,
    'thankful': 1.5,
    'proud': 1.5,
    'relieved': 1.5,
    'relief': 1.5,
    'calm': 1,
    'peaceful': 1.25,
    'settled': 1,
    'better': 1,
    'hopeful': 1.5,
    'hope': 1,
    'joy': 2,
    'lovely': 1.25,
    'enjoyed': 1.25,
    'enjoying': 1.25,
    'fun': 1,
    'laughed': 1.25,
    'laughing': 1.25,
    'love': 1.25,
    'loved': 1.25,
    'confident': 1.25,
    'accomplished': 1.5,
    'celebrating': 1.75,
    'celebrated': 1.75,
    'won': 1.25,
    'promoted': 1.75,
    'promotion': 1.75,
  };

  /// Multiply the next affective term.
  static const Map<String, double> _intensifiers = {
    'very': 1.5,
    'really': 1.4,
    'so': 1.3,
    'extremely': 1.8,
    'incredibly': 1.7,
    'completely': 1.6,
    'totally': 1.5,
    'utterly': 1.8,
    'absolutely': 1.6,
    'deeply': 1.6,
    'unbelievably': 1.7,
    'super': 1.3,
  };

  /// Damp the next affective term.
  static const Map<String, double> _dampeners = {
    'slightly': 0.5,
    'somewhat': 0.6,
    'bit': 0.6,
    'little': 0.6,
    'kind': 0.7,
    'sort': 0.7,
    'mildly': 0.5,
    'fairly': 0.8,
  };

  /// Flip the sign of the next affective term.
  ///
  /// "I'm not sad" must not score as sadness, and "not great" must not score as
  /// warmth. A three-token window is enough for the constructions people
  /// actually write and short enough not to reach across a clause boundary.
  static const Set<String> _negators = {
    'not', 'no', 'never', 'cant', 'cannot', 'dont', 'doesnt', 'didnt',
    'wasnt', 'isnt', 'arent', 'wont', 'wouldnt', 'hardly', 'barely',
    'nothing', 'without',
  };

  static const int _negationWindow = 3;

  /// Reads [text] and returns its emotional register.
  ///
  /// Returns [MoodReading.neutral] with zero confidence when nothing
  /// affective is present, which is the common case and must stay cheap.
  static MoodReading read(String text) {
    final tokens = _tokenize(text);
    if (tokens.isEmpty) return MoodReading.neutral;

    var score = 0.0;
    var evidence = 0.0;
    var activated = 0.0;
    var flat = 0.0;

    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final neg = _negative[token];
      final pos = _positive[token];
      if (neg == null && pos == null) continue;

      var weight = neg?.w ?? pos!;
      var sign = neg != null ? -1.0 : 1.0;

      // Modifiers sit immediately before the term they modify.
      if (i > 0) {
        final prev = tokens[i - 1];
        weight *= _intensifiers[prev] ?? _dampeners[prev] ?? 1.0;
      }

      // Negation reaches a little further back — "I do not feel great".
      for (var back = 1; back <= _negationWindow && i - back >= 0; back++) {
        if (_negators.contains(tokens[i - back])) {
          // Negated positives land near neutral rather than fully negative:
          // "not great" is deflation, not despair.
          sign = neg != null ? 1.0 : -1.0;
          weight *= 0.6;
          break;
        }
      }

      score += sign * weight;
      evidence += weight;
      if (sign < 0) {
        if (neg?.activated ?? false) {
          activated += weight;
        } else {
          flat += weight;
        }
      }
    }

    if (evidence == 0) return MoodReading.neutral;

    // Normalise against evidence rather than length: one strong word in a short
    // message is a real signal, and dividing by token count would erase it.
    final valence = (score / evidence).clamp(-1.0, 1.0);

    // Confidence rises with how much affective language was used, saturating
    // quickly — three strong words is as certain as this method gets.
    final confidence = (evidence / 3.0).clamp(0.0, 1.0);

    return MoodReading(
      label: _label(valence, activated: activated, flat: flat),
      valence: valence.toDouble(),
      confidence: confidence.toDouble(),
    );
  }

  static MoodLabel _label(
    double valence, {
    required double activated,
    required double flat,
  }) {
    if (valence <= -0.75) {
      // Severe either way; activation decides which kind of severe.
      return activated > flat ? MoodLabel.anxious : MoodLabel.distressed;
    }
    if (valence <= -0.25) {
      return activated > flat ? MoodLabel.anxious : MoodLabel.low;
    }
    if (valence < 0.25) return MoodLabel.neutral;
    if (valence < 0.7) return MoodLabel.hopeful;
    return MoodLabel.bright;
  }

  /// Lowercased word tokens. Apostrophes are dropped rather than split so
  /// "don't" becomes "dont" and matches [_negators].
  static List<String> _tokenize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"['’]"), '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
}
