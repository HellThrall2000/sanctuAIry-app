import 'package:shared_preferences/shared_preferences.dart';
import 'model_profile.dart';

/// Sampler settings for the on-device model, persisted so they can be tuned on
/// the phone without a rebuild.
///
/// Defaults come from the active [ModelProfile] rather than being global,
/// because the right sampler differs sharply between models. On the fine-tune,
/// temperature must be **above** 1.0 and top-P must not truncate:
///
/// * temperature divides the logits, so anything below 1.0 *sharpens* an
///   already over-confident model. The old 0.9 default was described as
///   "raised"; it was pointed the wrong way.
/// * top-P 0.95 keeps the smallest token set summing to 0.95 — and that
///   fine-tune's top token frequently exceeds 0.95 on its own, leaving a nucleus
///   of exactly one candidate. Sampling then equals greedy whatever the seed is,
///   which is why reseeding kept returning identical text.
///
/// Stock Gemma 4 E2B has neither problem and runs near the runtime defaults;
/// widening it there only costs coherence.
///
/// Saved values are namespaced per profile, so tuning one model never leaks onto
/// the other. Changes only take effect when the conversation is created, so
/// [LiteRtService.reconfigure] must be called afterwards.
class ModelSettings {
  /// Multiplier applied to [temperature] when regenerating a reply that came
  /// back repeated.
  ///
  /// A repeat means the distribution at the normal setting is too peaked to
  /// escape, so retrying at the same width tends to land in the same place.
  /// Widening only for the retry keeps ordinary replies at their tuned setting.
  static const double escapeTemperatureMultiplier = 1.5;

  /// Ceiling for the widened retry. Past roughly this point a model produces
  /// genuinely incoherent text rather than merely varied text.
  static const double maxTemperature = 2.0;

  final ModelProfile profile;
  double temperature;
  int topK;
  double topP;

  ModelSettings({
    this.profile = ModelProfile.fineTune,
    double? temperature,
    int? topK,
    double? topP,
  })  : temperature = temperature ?? profile.temperature,
        topK = topK ?? profile.topK,
        topP = topP ?? profile.topP;

  static String _key(String name, ModelProfile profile) =>
      'sanctuary_sampler_${name}_${profile.id}';

  static Future<ModelSettings> load(ModelProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    return ModelSettings(
      profile: profile,
      temperature: prefs.getDouble(_key('temperature', profile)),
      topK: prefs.getInt(_key('topk', profile)),
      topP: prefs.getDouble(_key('topp', profile)),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key('temperature', profile), temperature);
    await prefs.setInt(_key('topk', profile), topK);
    await prefs.setDouble(_key('topp', profile), topP);
  }

  /// Clears the saved overrides and returns to the profile's own values.
  Future<void> resetToDefaults() async {
    temperature = profile.temperature;
    topK = profile.topK;
    topP = profile.topP;
    await save();
  }

  ModelSettings copy() => ModelSettings(
        profile: profile,
        temperature: temperature,
        topK: topK,
        topP: topP,
      );

  @override
  String toString() =>
      'temp=${temperature.toStringAsFixed(2)} topK=$topK topP=${topP.toStringAsFixed(2)}';
}
