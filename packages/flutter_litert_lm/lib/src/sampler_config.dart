/// Configuration for the token sampling strategy.
class LiteLmSamplerConfig {
  final int topK;
  final double topP;
  final double temperature;

  /// RNG seed for sampling.
  ///
  /// VENDORED CHANGE — upstream 0.3.0 omits this field entirely, so the native
  /// `SamplerConfig(topK, topP, temperature, seed)` always received its Kotlin
  /// default of 0. Sampling was therefore reproducible: five conversations
  /// created from one engine with identical settings returned byte-identical
  /// text, on Google's own Gemma 4 E2B build as well as ours. Passing a fresh
  /// seed per conversation takes that from 1/5 unique replies to 4/5.
  ///
  /// Leave null to keep the native default (0, i.e. reproducible).
  final int? seed;

  const LiteLmSamplerConfig({
    this.topK = 40,
    this.topP = 0.95,
    this.temperature = 0.8,
    this.seed,
  });

  Map<String, dynamic> toMap() => {
        'topK': topK,
        'topP': topP,
        'temperature': temperature,
        if (seed != null) 'seed': seed,
      };
}
