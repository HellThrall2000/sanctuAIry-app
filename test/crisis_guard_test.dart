import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/crisis_guard.dart';

void main() {
  group('explicit — bypasses the model', () {
    // Unambiguous intent, plan, or active self-harm. Guessing wrong here is not
    // survivable, so these never reach a sampling process.
    const mustBeExplicit = [
      'i want to kill myself',
      'im going to kill my self',
      'kys',
      'i want to take my own life',
      'i want to end my life',
      'i have been feeling suicidal',
      'i want to hurt myself',
      'i have been self harming again',
      'i started cutting myself',
      'i took an overdose',
    ];

    for (final phrase in mustBeExplicit) {
      test('"$phrase"', () {
        expect(CrisisGuard.assess(phrase), CrisisLevel.explicit);
      });
    }

    test('is case-insensitive', () {
      expect(CrisisGuard.assess('I WANT TO KILL MYSELF'), CrisisLevel.explicit);
    });

    test('matches mid-sentence', () {
      expect(
        CrisisGuard.assess('honestly some days i just want to kill myself'),
        CrisisLevel.explicit,
      );
    });
  });

  group('concern — stays in the conversation', () {
    // These are said figuratively far more often than literally. Interrupting
    // them with a helpline list reads as "go away" and ends the conversation
    // that would actually establish what is going on.
    const mustBeConcern = [
      'i just want to die',
      "i don't want to be here anymore",
      'i dont want to wake up',
      "i don't want to be alive",
      'everyone would be better off without me',
      'there is no point living',
      'no reason to go on',
      'thinking about ending things',
      'i think i should end it all',
      "i can't do this anymore",
      "what's the point",
    ];

    for (final phrase in mustBeConcern) {
      test('"$phrase"', () {
        expect(CrisisGuard.assess(phrase), CrisisLevel.concern);
      });
    }

    test('concern must never short-circuit — that is the whole point', () {
      for (final phrase in mustBeConcern) {
        expect(CrisisGuard.assess(phrase), isNot(CrisisLevel.explicit),
            reason: '"$phrase" would interrupt the conversation');
      }
    });
  });

  group('none', () {
    const mustBeNone = [
      'this deadline is killing me',
      'my feet are killing me',
      'i am sad',
      'my girlfriend broke up with me',
      'i got fired today and feel awful',
      'tell me something about the moon',
      'i want to eat sweet',
    ];

    for (final phrase in mustBeNone) {
      test('"$phrase"', () {
        expect(CrisisGuard.assess(phrase), CrisisLevel.none);
      });
    }

    group('softeners defuse even explicit wording', () {
      test('a film plot', () {
        expect(
          CrisisGuard.assess(
              'i watched a movie where the character wanted to kill himself'),
          CrisisLevel.none,
        );
      });

      test('past tense, resolved', () {
        expect(CrisisGuard.assess('i used to want to die but not anymore'),
            CrisisLevel.none);
      });

      test('explicit disavowal', () {
        expect(CrisisGuard.assess('i would never hurt myself'),
            CrisisLevel.none);
      });
    });
  });

  group('gentleOffer', () {
    final offer = CrisisGuard.gentleOffer();

    test('is short — it must not read as a wall of numbers', () {
      expect(offer.length, lessThan(320));
    });

    test('names one place, not the whole directory', () {
      expect(offer, contains('findahelpline.com'));
      for (final r in CrisisGuard.resources.where((r) => r.region != 'International')) {
        expect(offer, isNot(contains(r.contact)),
            reason: '${r.name} belongs in the explicit response, not the offer');
      }
    });

    test('stays in the conversation rather than handing off', () {
      expect(offer.toLowerCase(), contains('still here'));
      expect(offer.toLowerCase(), contains('no pressure'));
    });
  });

  group('response — explicit only', () {
    final response = CrisisGuard.response();

    test('is deterministic, which is why it bypasses the model', () {
      expect(CrisisGuard.response(), response);
    });

    test('leads with emergency services, which need no country lookup', () {
      expect(response, contains('local emergency services'));
    });

    test('names a trusted person as well as a service', () {
      expect(response, contains('someone you trust'));
    });

    test('lists every resource with its region', () {
      for (final r in CrisisGuard.resources) {
        expect(response, contains(r.name));
        expect(response, contains(r.contact));
        expect(response, contains(r.region));
      }
    });

    test('does not abandon the user at the end', () {
      expect(response, contains("I'll still be here"));
    });

    test('makes no clinical claim', () {
      // Shown unreviewed at the worst possible moment; it must not diagnose or
      // promise an outcome.
      for (final banned in ['diagnos', 'you have ', 'disorder', 'guarantee']) {
        expect(response.toLowerCase(), isNot(contains(banned)));
      }
    });
  });

  group('resources', () {
    test('is not empty — an empty list ships a response with no help in it', () {
      expect(CrisisGuard.resources, isNotEmpty);
    });

    test('leads with international directories, not a single country', () {
      expect(CrisisGuard.resources.first.region, 'International');
    });

    test('every entry carries provenance for re-verification', () {
      for (final r in CrisisGuard.resources) {
        expect(r.source, startsWith('https://'), reason: '${r.name} source');
        expect(r.verifiedOn, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
            reason: '${r.name} verifiedOn');
        expect(r.contact, isNotEmpty, reason: '${r.name} contact');
      }
    });
  });
}
