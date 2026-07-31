import 'package:shared_preferences/shared_preferences.dart';
import 'model_profile.dart';

/// Which [ModelProfile] to prefer when more than one model is on the device.
///
/// Development runs against stock Gemma 4 E2B while the fine-tune is retrained
/// (ROADMAP P0.8), and both files can sit on the device at once. This pins the
/// choice so it survives an app restart; without it the winner is whichever
/// directory happens to be scanned first.
///
/// Unset means "use whatever is found", which is the right behaviour in a
/// release build where only one model ships.
class ModelPreference {
  const ModelPreference._();

  static const _key = 'sanctuary_preferred_model_profile';

  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> save(ModelProfile? profile) async {
    final prefs = await SharedPreferences.getInstance();
    if (profile == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, profile.id);
    }
  }
}
