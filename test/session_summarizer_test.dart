import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/session_summarizer.dart';

void main() {
  group('compacting a conversation that filled the window', () {
    test('carries the substance of the turns being dropped', () {
      final summary = SessionSummarizer.compact([
        'Work has been relentless since the restructure and I am doing the '
            'job of two people while pretending it is fine.',
        'I get home around nine and the flat is silent and I just sit on the '
            'floor with my coat still on.',
      ]);

      expect(summary, isNotNull);
      expect(summary, contains('Earlier in this conversation'));
      expect(summary, contains('restructure'));
      expect(summary, contains('They said:'));
    });

    test('quotes the user verbatim rather than paraphrasing', () {
      // Extractive by design: a generation pass to summarise would cost 15-30s
      // mid-conversation, and asking a 2B model to compress is where invention
      // starts. Selected sentences can never say something never said.
      const line =
          'My sister called last week and I let it ring out because she has '
          'her own problems.';
      final summary = SessionSummarizer.compact([line]);
      expect(summary, contains('My sister called last week'));
    });

    test('does not quote the same line twice', () {
      // Observed on device: a repeated message filled two of three quote slots
      // with one sentence. These summaries ride in the system instruction, so
      // a wasted slot is taken directly from the conversation's budget.
      const line =
          'I think what frightens me is that this has stopped feeling '
          'temporary and it has been most of a year.';
      final summary = SessionSummarizer.compact([line, line, line])!;
      expect('They said:'.allMatches(summary).length, 1);
    });

    test('treats punctuation and case differences as the same line', () {
      final summary = SessionSummarizer.compact([
        'I have not been sleeping well at all lately',
        'I have not been sleeping well at all lately.',
      ])!;
      expect('They said:'.allMatches(summary).length, 1);
    });

    test('returns nothing when there is nothing worth carrying', () {
      expect(SessionSummarizer.compact([]), isNull);
      expect(SessionSummarizer.compact(['ok', 'yeah', 'thanks']), isNull);
    });

    test('stays small enough to be worth carrying', () {
      // It buys its place in the context window by being much cheaper than the
      // turns it replaces.
      final turns = List.generate(
        30,
        (i) => 'Turn $i. Work has been difficult and I have not been sleeping, '
            'and I keep comparing myself to other people my age.',
      );
      final summary = SessionSummarizer.compact(turns)!;
      final original = turns.join(' ').length;
      expect(summary.length, lessThan(original ~/ 4));
    });
  });
}
