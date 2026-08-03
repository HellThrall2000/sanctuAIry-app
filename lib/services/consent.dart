import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the user has accepted the terms, and when.
///
/// **The timestamp is the point.** A boolean records that a box was ticked; a
/// timestamp and a version record *what* was agreed to and *when*, which is what
/// a data-protection request actually asks for. Bumping [version] re-asks
/// everyone, so a material change to the terms is not silently applied to people
/// who agreed to something else.
abstract final class Consent {
  /// Raise this when the terms change materially. Everyone is asked again.
  static const int version = 1;

  static const _versionKey = 'sanctuary_terms_version';
  static const _atKey = 'sanctuary_terms_accepted_at';

  /// Whether the current terms version has been accepted.
  static Future<bool> isAccepted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_versionKey) ?? 0) >= version;
    } catch (e) {
      // Fail closed. If the record cannot be read we ask again, which is a
      // second tap; assuming acceptance would be claiming consent we do not
      // have.
      debugPrint('Could not read consent, asking again: $e');
      return false;
    }
  }

  static Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_versionKey, version);
    await prefs.setString(_atKey, DateTime.now().toUtc().toIso8601String());
  }

  /// When the terms were accepted, for the account screen and for answering a
  /// data-protection request.
  static Future<DateTime?> acceptedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_atKey);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Whether this platform requires an account before the app can be used.
  ///
  /// **Android yes, iOS no**, which is not an inconsistency — it is the two
  /// stores' rules. App Store guideline 5.1.1(v) forbids requiring account
  /// creation when the core features do not depend on it, and an offline journal
  /// that demands a Google login is close to the example in the rule. Play has
  /// no equivalent restriction.
  static bool get requiresAccount =>
      defaultTargetPlatform == TargetPlatform.android;
}
