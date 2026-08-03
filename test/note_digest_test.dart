import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/journal_entry.dart';
import 'package:sanctuary/services/note_digest.dart';

JournalEntry entry(String title, String content) => JournalEntry(
      id: 'e1',
      title: title,
      content: content,
      date: DateTime(2026, 8, 1).toUtc().toIso8601String(),
      allowAiAccess: true,
    );

void main() {
  group('shrinking an entry', () {
    test('keeps the points and drops the padding', () {
      final d = NoteDigester.digest(entry(
        'A hard week',
        'I woke up early again and made coffee. '
            'I felt completely overwhelmed by the deadline at work. '
            'The kitchen tap is still dripping. '
            'I finally told my manager I could not take on more.',
      ));
      final joined = d.points.join(' ');
      expect(joined, contains('overwhelmed'));
      expect(joined, contains('told my manager'));
    });

    test('never returns more than maxPoints', () {
      final many = List.generate(
        20,
        (i) => 'I felt genuinely anxious about the thing that happened on '
            'day number $i of this long month.',
      ).join(' ');
      expect(
        NoteDigester.digest(entry('Long', many)).points.length,
        lessThanOrEqualTo(NoteDigester.maxPoints),
      );
    });

    test('points stay in the order they were written', () {
      final d = NoteDigester.digest(entry(
        'Order',
        'First I felt afraid about the meeting that was coming up. '
            'Then I realised I had been holding my breath the whole time. '
            'Finally I decided that I would say something honest.',
      ));
      final content = 'First I felt afraid about the meeting that was coming '
          'up. Then I realised I had been holding my breath the whole time. '
          'Finally I decided that I would say something honest.';
      var last = -1;
      for (final p in d.points) {
        final at = content.indexOf(p.replaceAll('…', '').trim());
        expect(at, greaterThan(last), reason: 'out of order: $p');
        last = at;
      }
    });

    test('quotes the user rather than paraphrasing', () {
      // Extractive by design: a paraphrase is where a small model would invent,
      // and this text is later treated as true.
      const line = 'I felt completely hollow after the phone call ended.';
      final d = NoteDigester.digest(entry('Call', '$line And then I slept.'));
      expect(d.points.first, line);
    });

    test('long points are cut at a word boundary', () {
      final long = 'I felt ${'really ' * 60}tired.';
      final d = NoteDigester.digest(entry('Long line', long));
      final point = d.points.single;
      expect(point.length, lessThanOrEqualTo(NoteDigester.maxPointLength + 1));
      expect(point.endsWith('…'), isTrue);
      expect(point, isNot(contains('  ')));
    });
  });

  group('nothing to shrink', () {
    test('an empty entry produces an empty digest, not an invented one', () {
      final d = NoteDigester.digest(entry('', ''));
      expect(d.points, isEmpty);
      expect(d.isEmpty, isTrue);
    });

    test('fragments below the minimum are not points', () {
      expect(NoteDigester.digest(entry('T', 'ok. fine. yes.')).points, isEmpty);
    });
  });

  group('rendering', () {
    test('carries the date and title', () {
      final d = NoteDigester.digest(entry(
        'A hard week',
        'I felt completely overwhelmed by the deadline at work today.',
      ));
      final rendered = d.render();
      expect(rendered, contains('A hard week'));
      expect(rendered, contains('Aug 1'));
      expect(rendered, contains('overwhelmed'));
    });
  });
}
