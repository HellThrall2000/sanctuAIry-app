import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/tracker_feed.dart';

void main() {
  setUp(TrackerFeed.instance.take); // drain anything a previous test left

  group('the line it posts', () {
    test('one change reads as a sentence, not a receipt', () {
      expect(TrackerFeed.messageFor(['added meditation 20 minutes']),
          'Noted — added meditation 20 minutes.');
    });

    test('two are joined with "and"', () {
      expect(
        TrackerFeed.messageFor(['added yoga', 'ticked off "call the dentist"']),
        'Noted — added yoga and ticked off "call the dentist".',
      );
    });

    test('three get an Oxford-less list', () {
      expect(
        TrackerFeed.messageFor(['added yoga', 'dropped gym', 'added reading']),
        'Noted — added yoga, dropped gym and added reading.',
      );
    });

    test('past a few, it counts instead of listing', () {
      // Someone reorganising their week can touch a dozen things. A sentence
      // naming twelve of them is not a companion noticing, it is a receipt.
      final many = List.generate(7, (i) => 'change $i');
      expect(TrackerFeed.messageFor(many),
          'Noted — 7 changes to your tracker.');
    });

    test('nothing to say means nothing is said', () {
      expect(TrackerFeed.messageFor(const []), isNull);
    });
  });

  group('the feed itself', () {
    test('records in order and drains once', () {
      final feed = TrackerFeed.instance
        ..record('added yoga')
        ..record('dropped gym');

      expect(feed.hasPending, isTrue);
      expect(feed.take(), ['added yoga', 'dropped gym']);

      // Consumed once — a change is acknowledged once, not on every rebuild.
      expect(feed.hasPending, isFalse);
      expect(feed.take(), isEmpty);
    });

    test('blank changes are ignored rather than posted as an empty line', () {
      final feed = TrackerFeed.instance
        ..record('')
        ..record('   ');
      expect(feed.hasPending, isFalse);
    });

    test('notifies so the conversation can react', () {
      var fired = 0;
      void listener() => fired++;

      TrackerFeed.instance.addListener(listener);
      addTearDown(() => TrackerFeed.instance.removeListener(listener));

      TrackerFeed.instance.record('added yoga');
      expect(fired, 1);

      // A change that was ignored must not wake anything up either.
      TrackerFeed.instance.record('  ');
      expect(fired, 1);
    });
  });
}
