import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanctuary/services/consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('acceptance is recorded, not assumed', () {
    test('nothing is accepted on a fresh install', () async {
      expect(await Consent.isAccepted(), isFalse);
    });

    test('accepting sticks', () async {
      await Consent.accept();
      expect(await Consent.isAccepted(), isTrue);
    });

    test('the time of acceptance is kept, not just the fact', () async {
      // A boolean says a box was ticked. A data-protection request asks when.
      final before = DateTime.now().toUtc();
      await Consent.accept();
      final at = await Consent.acceptedAt();

      expect(at, isNotNull);
      expect(
        at!.isBefore(before.subtract(const Duration(seconds: 5))),
        isFalse,
      );
    });

    test('no timestamp before anything is accepted', () async {
      expect(await Consent.acceptedAt(), isNull);
    });
  });

  group('a new terms version asks again', () {
    test('acceptance of an older version does not carry forward', () async {
      // Simulates someone who agreed to version 0 of the terms. Bumping
      // Consent.version must re-ask rather than silently applying new terms to
      // an old agreement.
      SharedPreferences.setMockInitialValues({
        'sanctuary_terms_version': Consent.version - 1,
      });
      expect(await Consent.isAccepted(), isFalse);
    });

    test('a future version still counts as accepted', () async {
      // Downgrading the app should not re-prompt someone who has already agreed
      // to something newer.
      SharedPreferences.setMockInitialValues({
        'sanctuary_terms_version': Consent.version + 1,
      });
      expect(await Consent.isAccepted(), isTrue);
    });
  });

  group('which platforms require an account', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Android requires one', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(Consent.requiresAccount, isTrue);
    });

    test('iOS does not — App Store guideline 5.1.1(v)', () {
      // Requiring account creation for features that do not depend on it is
      // grounds for rejection on iOS. It is not on Play.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(Consent.requiresAccount, isFalse);
    });
  });
}
