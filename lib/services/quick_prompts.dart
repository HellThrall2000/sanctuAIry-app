/// The seed phrases offered above the composer.
///
/// Shared rather than private to the chat view because the summariser has to
/// recognise them: they arrive as user turns and are long, so "longest user
/// turn" picked them as the substance of a session and quoted a canned template
/// back as something the user had said.
class QuickPrompt {
  final String label;
  final String text;

  const QuickPrompt(this.label, this.text);

  static const all = <QuickPrompt>[
    QuickPrompt(
      'Deep Reflection',
      "I'd like to sit with something that's been weighing on me...",
    ),
    QuickPrompt(
      'Stream of Consciousness',
      "Let's write down my raw, unfiltered thoughts and see where they lead...",
    ),
    QuickPrompt(
      'Focus on Wonder',
      'I want to notice something small and good today...',
    ),
  ];

  /// Whether [text] is one of the seeds, sent unedited.
  ///
  /// Compared on the whole trimmed string: a user who typed *around* the seed
  /// has made it their own and it should count normally.
  static bool isSeed(String text) {
    final t = text.trim();
    return all.any((p) => p.text == t);
  }
}
