/// Maps a message onto the handful of life domains people actually talk about.
///
/// **Why a fixed vocabulary rather than keyword mining.** Pulling salient nouns
/// out of a message gives topics like "thing", "today" and "bit", and the ones
/// that are real are unreadable in a prompt — *"Subjects they keep returning
/// to: monday, manager, email"* tells the model nothing useful. A closed set of
/// domains produces *"work, sleep, family"*, which is both true and legible.
///
/// The cost is that anything outside the vocabulary is invisible. That is the
/// right trade here: this feeds a single line of the system prompt and a nudge's
/// subject, and being silent is much better than being wrong.
abstract final class TopicExtractor {
  /// Domain to the words that indicate it.
  ///
  /// Words are matched on the stem-ish prefixes people actually type. Kept
  /// deliberately small — every entry is a chance for a false positive, and a
  /// misattributed preoccupation is worse than a missing one.
  static const Map<String, List<String>> _domains = {
    'work': [
      'work', 'works', 'working', 'job', 'jobs', 'boss', 'manager', 'office',
      'career', 'colleague', 'colleagues', 'coworker', 'deadline', 'meeting',
      'promotion', 'fired', 'redundant', 'interview', 'shift', 'overtime',
    ],
    'study': [
      'exam', 'exams', 'study', 'studying', 'studies', 'revision', 'revising',
      'assignment', 'dissertation', 'thesis', 'coursework', 'semester',
      'university', 'college', 'school', 'degree', 'grades',
    ],
    'family': [
      'mum', 'mom', 'mother', 'dad', 'father', 'parents', 'brother', 'sister',
      'sibling', 'son', 'daughter', 'grandma', 'grandmother', 'grandad',
      'grandfather', 'family', 'aunt', 'uncle', 'cousin',
    ],
    'relationship': [
      'girlfriend', 'boyfriend', 'partner', 'wife', 'husband', 'marriage',
      'married', 'dating', 'breakup', 'divorce', 'ex', 'relationship', 'crush',
    ],
    'friends': [
      'friend', 'friends', 'mate', 'mates', 'friendship', 'flatmate',
      'housemate', 'roommate',
    ],
    'sleep': [
      'sleep', 'sleeping', 'slept', 'insomnia', 'awake', 'nightmare',
      'nightmares', 'bed', 'rested', 'tired', 'exhausted',
    ],
    'health': [
      'doctor', 'gp', 'hospital', 'illness', 'sick', 'pain', 'diagnosis',
      'appointment', 'therapy', 'therapist', 'counsellor', 'medication',
      'symptoms', 'health',
    ],
    'money': [
      'money', 'rent', 'bills', 'debt', 'loan', 'salary', 'wage', 'afford',
      'broke', 'savings', 'budget', 'mortgage', 'overdraft',
    ],
    'loneliness': [
      'lonely', 'alone', 'isolated', 'nobody', 'friendless', 'excluded',
      'left out', 'ignored',
    ],
    'grief': [
      'died', 'death', 'funeral', 'grief', 'grieving', 'passed away', 'loss',
      'mourning', 'bereaved',
    ],
    'exercise': [
      'gym', 'run', 'running', 'ran', 'walk', 'walking', 'swim', 'swimming',
      'yoga', 'exercise', 'training', 'workout', 'cycling',
    ],
    'creativity': [
      'writing', 'painting', 'drawing', 'music', 'guitar', 'piano', 'singing',
      'photography', 'art', 'poetry', 'novel', 'craft',
    ],
    'pets': [
      'dog', 'cat', 'puppy', 'kitten', 'pet', 'hamster', 'rabbit', 'vet',
    ],
    'the future': [
      'future', 'plan', 'plans', 'planning', 'goals', 'ambition', 'someday',
      'next year', 'move out', 'moving',
    ],
    'food': [
      'eating', 'ate', 'appetite', 'cooking', 'cooked', 'meal', 'dinner',
      'breakfast', 'lunch',
    ],
  };

  /// Multi-word triggers, checked against the raw text rather than tokens.
  static final Map<String, List<String>> _phrases = {
    for (final entry in _domains.entries)
      entry.key: entry.value.where((w) => w.contains(' ')).toList(),
  };

  /// Domains present in [text].
  ///
  /// Returns an empty set for most short messages, which is correct — "ok" is
  /// not about anything.
  static Set<String> extract(String text) {
    final lower = text.toLowerCase();
    final tokens = lower
        .replaceAll(RegExp(r"['’]"), '')
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 1)
        .toSet();

    final found = <String>{};
    for (final entry in _domains.entries) {
      for (final word in entry.value) {
        if (word.contains(' ')) continue;
        if (tokens.contains(word)) {
          found.add(entry.key);
          break;
        }
      }
    }
    for (final entry in _phrases.entries) {
      if (found.contains(entry.key)) continue;
      for (final phrase in entry.value) {
        if (lower.contains(phrase)) {
          found.add(entry.key);
          break;
        }
      }
    }
    return found;
  }
}
