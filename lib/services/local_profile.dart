// widgets.dart rather than foundation.dart: it re-exports `characters`, which
// [initial] needs to avoid splitting a multi-code-unit first letter.
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The display name and email shown in the settings panel.
///
/// The design calls this "Sign In", and its own copy is explicit about what it
/// is: *"Instant offline demo login — nothing leaves this device."* There is no
/// account, no server and no credential — this stores two strings in
/// [SharedPreferences] so the companion has something to call the user and the
/// avatar has an initial. Naming it [LocalProfile] rather than `AuthService`
/// keeps that honest at every call site.
class LocalProfile extends ChangeNotifier {
  static final LocalProfile instance = LocalProfile._();

  LocalProfile._();

  static const _nameKey = 'sanctuary_profile_name';
  static const _emailKey = 'sanctuary_profile_email';

  /// Placeholders from the prototype, used when a field is left blank.
  static const defaultName = 'Sovereign Soul';
  static const defaultEmail = 'explorer@sanctuary.private';

  String? _name;
  String? _email;
  bool _loaded = false;

  bool get signedIn => _name != null;

  /// The stored name, or the prototype's placeholder when signed out.
  String get name => _name ?? defaultName;

  String get email => _email ?? defaultEmail;

  String get initial => name.isEmpty ? 'S' : name.characters.first.toUpperCase();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString(_nameKey);
    _email = prefs.getString(_emailKey);
    notifyListeners();
  }

  /// Stores the profile, substituting the placeholders for blank fields —
  /// `doSignIn` in the prototype does the same.
  Future<void> signIn({String? name, String? email}) async {
    _name = (name?.trim().isNotEmpty ?? false) ? name!.trim() : defaultName;
    _email = (email?.trim().isNotEmpty ?? false) ? email!.trim() : defaultEmail;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, _name!);
    await prefs.setString(_emailKey, _email!);
    notifyListeners();
  }

  Future<void> signOut() async {
    _name = null;
    _email = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nameKey);
    await prefs.remove(_emailKey);
    notifyListeners();
  }
}
