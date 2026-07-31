# Vendored fork of `flutter_litert_lm`

Forked from pub.dev **`flutter_litert_lm 0.3.0`**
(upstream: <https://github.com/songhieu/flutter_litert_lm>).

Vendored rather than patched via `dependency_overrides` because the changes are
in Kotlin and Dart source, not just versions. The `example/` directory is not
carried over; everything else is upstream verbatim except the changes below.
Each change is marked in-place with a `VENDORED CHANGE` comment.

## Why

Sanctuary's companion returned the *same reply every time*. Measured on a Kaggle
CPU box against both our fine-tune and Google's stock `gemma-4-E2B-it.litertlm`:
five conversations created from one engine, same prompt, same sampler settings →
**1/5 unique replies, byte-identical**. Temperature *was* being honoured (0.8 and
1.2 produced different text), which ruled out the plugin dropping the sampler.

`javap` on `litertlm-android-0.13.1.aar` explained it:

```
public final class com.google.ai.edge.litertlm.SamplerConfig {
  public SamplerConfig(int, double, double, int);
  public final int getTopK();
  public final double getTopP();
  public final double getTemperature();
  public final int getSeed();          <-- fourth field
```

and the synthetic constructor defaults it to zero:

```
2: bipush 8      // bit for param index 3 (seed)
8: iconst_0      // default -> 0
```

Upstream's `LiteLmSamplerConfig` has only three fields and its Kotlin bridge
passes only three arguments, so `seed` was always 0 and sampling was
reproducible. Supplying a fresh seed per conversation moves the same test from
**1/5 to 4/5 unique**.

## Changes

| File | Change |
|---|---|
| `lib/src/sampler_config.dart` | Added nullable `seed` field; emitted in `toMap()` only when non-null. |
| `android/src/main/kotlin/.../FlutterLitertLmPlugin.kt` | `parseConversationConfig` forwards `seed` to `SamplerConfig`, defaulting to 0 when absent. |
| `android/build.gradle.kts` | `litertlm-android` 0.10.0 → 0.13.1. |

The gradle bump is separate from the seed work. 0.10.0 does not recognise the
`gemma4` model type and aborts in `nativeCreateEngine` (SIGABRT). Gradle compiles
each module against its *declared* dependency version while packaging only the
highest across the build, so leaving the plugin at 0.10.0 while the app asked for
0.13.1 produced a runtime `NoSuchMethodError` on `EngineConfig`. The app's
`android/build.gradle` still carries a `subprojects { … force … }` block as a
belt-and-braces guard; with this pin corrected it should no longer be doing any
work, but it is harmless and protects against a future transitive re-introduction.

## Not changed (deliberately)

`Conversation` exposes **no** setter for `SamplerConfig` — it is fixed at
conversation creation:

```
public final class com.google.ai.edge.litertlm.Conversation {
  public final Message sendMessage(String, Map<String, Object>);
  ...  // no setSamplerConfig, no per-call sampler override
```

So a new seed requires a new `Conversation`, which means replaying history via
`initialMessages` and re-prefilling it. Sanctuary does that only when it detects
a repeated reply — see `LiteRtService.reseed`.

## Rebasing onto a newer upstream

1. `dart pub cache download flutter_litert_lm-<version>` (or fetch the tag).
2. Diff upstream against this tree; the only expected conflicts are the three
   files above.
3. Re-run `javap -cp classes.jar com.google.ai.edge.litertlm.SamplerConfig` on
   the AAR that the new version pins. If upstream has adopted `seed` natively,
   drop the vendored fork and go back to the pub.dev dependency.
