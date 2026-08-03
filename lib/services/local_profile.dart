// widgets.dart rather than foundation.dart: it re-exports `characters`, which
// [initial] needs to avoid splitting a multi-code-unit first letter.
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The name the companion calls the user by.
///
/// **Name only, deliberately.** This began as the prototype's fake demo login
/// and stored an email alongside the name — defaulting to a made-up
/// `explorer@sanctuary.private` whenever the field was blank, which it almost
/// always was. Once real authentication arrived, that placeholder started
/// appearing directly beneath a genuine Google display name in the settings
/// card, reading exactly like the address on the account. It was never an
/// address at all.
///
/// So the email is gone from here entirely. There is one source for it now —
/// [AuthService.email], which is null unless the user actually signed in with
/// Google — and a fiction cannot be shown in its place.
///
/// What remains is a single string in [SharedPreferences] so the companion has
/// something to call the user and the avatar has an initial. It needs no
/// account, which is why it survives at all.
class LocalProfile extends ChangeNotifier {
  static final LocalProfile instance = LocalProfile._();

  LocalProfile._();

  static const _nameKey = 'sanctuary_profile_name';

  /// Placeholder from the prototype, used when the name is left blank.
  static const defaultName = 'Sovereign Soul';

  String? _name;
  bool _loaded = false;

  bool get signedIn => _name != null;

  /// The stored name, or the prototype's placeholder when unset.
  String get name => _name ?? defaultName;

  String get initial => name.isEmpty ? 'S' : name.characters.first.toUpperCase();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString(_nameKey);
    notifyListeners();
  }

  /// Stores the name, substituting the placeholder when blank.
  Future<void> signIn({String? name}) async {
    _name = (name?.trim().isNotEmpty ?? false) ? name!.trim() : defaultName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, _name!);
    notifyListeners();
  }

  Future<void> signOut() async {
    _name = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    // The old email key is removed too, so a profile written by an earlier
    // build does not leave the placeholder behind in preferences.
    await prefs.remove('sanctuary_profile_email');
    notifyListeners();
  }
}
