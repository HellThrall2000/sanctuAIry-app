# Sanctuary App

A privacy-first, fully offline mental-health companion built with Flutter on Google's
LiteRT-LM on-device runtime.

Sanctuary runs a custom fine-tuned Gemma 4 E2B model **entirely on the phone**. There is no
inference server, no telemetry, and no network path for conversation content. The model is
fine-tuned on CBT and mental-health counselling dialogue, so it is meant to hold a
supportive, therapist-like conversation rather than act as a general chatbot.

> **Not a medical device.** Sanctuary is a reflective journaling and conversation aid. It
> does not diagnose, treat, or provide crisis care, and it is not a substitute for a
> licensed clinician.

## Features

- **100% on-device inference** via LiteRT-LM (`flutter_litert_lm`), no cloud calls.
- **Passcode-secured diary lockbox** — journals are opened explicitly and only the entries
  the user unlocks are shared with the model, as a system instruction.
- **Streaming chat UI** so first-token latency is visible rather than looking frozen.
- **Ambient soundscapes** with local loopable audio.

## Architecture

| Layer | Location |
| --- | --- |
| Chat UI + streaming state | [lib/screens/chat_screen.dart](lib/screens/chat_screen.dart) |
| Engine lifecycle wrapper | [lib/services/litert_service.dart](lib/services/litert_service.dart) |
| CPU wakelock method channel | [android/app/src/main/kotlin/com/example/sanctuary/MainActivity.kt](android/app/src/main/kotlin/com/example/sanctuary/MainActivity.kt) |

`LiteRtService` is a singleton. It locates the model, brings up a `LiteLmEngine`, opens one
`LiteLmConversation`, and streams tokens back. Engine creation is reentrancy-guarded —
two concurrent loads would double an already-marginal memory footprint.

## On-device model

The model is **not** in this repository. It is pushed to the app's external files directory:

```bash
adb push model.litertlm /sdcard/Android/data/com.example.sanctuary/files/model.litertlm
```

`findLocalModelFile()` checks that path first, then app documents, then `/sdcard/Download`.

### What the current `.litertlm` actually contains

Measured by reading the container header and the runtime's own load log on-device:

- Container: `LITERTLM` **v1.5.0**, total **2,549,337,440 bytes (2,549 MB)**
- Sections:

  | # | Type | Size |
  | --- | --- | --- |
  | 0 | `LlmMetadataProto` | 12 KB |
  | 1 | `SP_Tokenizer` (SentencePiece) | 4.7 MB |
  | 2 | `TFLiteModel` — `tf_lite_prefill_decode` | 1.16 GB |
  | 3 | `TFLiteModel` — `tf_lite_embedder` | 204 MB |
  | 4 | `TFLiteModel` — `tf_lite_per_layer_embedder` | 1.18 GB |

- Embedder: rank 3, **1536** floats/token → embedding width 1536
- Per-layer embedder: rank 4, **8960** floats/token → **35 layers × 256** per-layer
  embedding dim, i.e. the **PLE (Per-Layer Embeddings)** architecture used by the
  Gemma 4 "E" effective-parameter models.
- Implied vocabulary ≈ **262,144**; embedder and PLE both work out to ≈ **int4** (0.5
  bytes/value).
- No vision or audio encoder sections, and **no GPU-constrained submodel**.

### Runtime engine settings (reported by the runtime at load)

```
backend: CPU          max_tokens: 4096      number_of_threads: 4
prefill_chunk_size: -1                      kv_increment_size: 16
```

`flutter_litert_lm` 0.3.0's `LiteLmEngineConfig` exposes only `modelPath`, `backend`,
`cacheDir`, `visionBackend`, `audioBackend` — there is **no way to lower `max_tokens`
from Dart**. The 4096-token KV cache is fixed at conversion time.

### Chat template — do not hand-write turn tags

The correct template is stored **inside the model**, in `LlmMetadataProto`, as a Jinja
template, and the LiteRT-LM runtime applies it automatically. The tokens are:

```
<|turn>system\n …instructions… <turn|>\n
<|turn>user\n …message… <turn|>\n
<|turn>model\n
```

plus `<bos>`, `<|think|>` and `<channel|>`/`<|channel>` for thinking, `<|tool>`,
`<|tool_call>`, `<|tool_response>` for tools, and `<|image|>` / `<|audio|>` placeholders.

**This model has no `<start_of_turn>` / `<end_of_turn>` tokens** — verified by scanning the
embedded SentencePiece vocabulary (zero occurrences). Earlier versions of the chat screen
wrapped prompts in those Gemma-2/3 tags; because they are not in the vocabulary they were
tokenized as ordinary text and corrupted every prompt. Send the user's **plain text** and
pass the persona through `LiteLmConversationConfig.systemInstruction` instead.

## RESOLVED: the app was OOM-killed on first message

**Status: fixed at conversion time on 2026-07-30 by changing one export argument.**
Kept here because the diagnosis is the useful part.

### Verified fix

Re-exported with `quantization_recipe='dynamic_wi4_afp32'` (was
`weight_only_wi4_afp32`) and measured with the LiteRT-LM Python API on Linux CPU:

| | Broken build | Re-export | Google's official E2B |
| --- | --- | --- | --- |
| Peak RSS | 6,000 – 7,400 MB | **1,543 MB** | 1,733 MB (Android CPU) |
| Anonymous memory at peak | — | **344 MB** | — |
| `DEQUANTIZE` ops | — | **0** | — |
| Output | process killed | `"I'm sorry to hear that. What is causing you to feel anxious"` | — |

`Anonymous` is the number that matters: the ~1.2 GB balance is file-backed mmap of the
model, which is evictable under pressure. Only 344 MB is the anonymous allocation that
XNNPACK repacking used to blow up to multiple GB. Peak now sits **below** Google's own
reference build for the same model.

Two further wins from the same re-export:

- `llm_model_type` changed from `generic_model` to `gemma4`, so the runtime now builds a
  `Gemma4DataProcessor` and gets the full `<turn|>` stop-token set and the `thought`
  channel, rather than three bare token IDs.
- Load time dropped from 29–56 s to a few seconds (0.1 s with a warm XNNPACK weight cache).

### Second bug: the Android runtime was too old for the fixed model

Fixing the export surfaced a completely separate failure. The re-exported model declares
`llm_model_type { gemma4 }`, but `flutter_litert_lm` 0.3.0 pins
`com.google.ai.edge.litertlm:litertlm-android:0.10.0` — a runtime built from upstream
**2026-04-11**, before Gemma 4 support. It aborted (SIGABRT, no abort message) inside
`Java_com_google_ai_edge_litertlm_LiteRtLmJni_nativeCreateEngine`. The old
`generic_model` bundle had loaded fine on that same runtime, and the same new model ran
correctly under the current `litert-lm-api` in Python — which is what isolated it.

Bumping the version in `:app` alone was not enough, and produced two successive
`NoSuchMethodError`s. Gradle packages a single (highest) version of an artifact, but each
module still **compiles** against the version it declares — so the plugin's bytecode kept
referencing 0.10.0 signatures that the shipped AAR no longer had. The fix forces the
version across every subproject, in [android/build.gradle](android/build.gradle):

```gradle
subprojects {
    configurations.all {
        resolutionStrategy {
            force 'com.google.ai.edge.litertlm:litertlm-android:0.13.1'
        }
    }
}
```

**0.13.1, not latest.** Verified by decompiling each AAR with `javap`:

| Version | `Backend$CPU` | `EngineConfig` |
| --- | --- | --- |
| 0.10.0 | `(Integer)` | `(String, Backend, Backend, Backend, Integer, String)` |
| 0.10.2 – 0.13.1 | `(Integer)` | `(…, Integer, **Integer**, String)` |
| 0.14.0 | `(Integer, **Integer**)` | — |

0.14.0 changes `Backend.CPU`'s constructor and breaks the plugin. 0.13.1 is the newest
version that keeps it. The plugin's Kotlin uses named arguments, so the parameters added
in 0.10.2+ resolve to their defaults and it compiles unchanged. **Re-check with `javap`
before bumping**, and drop the override once the plugin updates its own pin.

The unused `com.google.mediapipe:tasks-genai:latest.release` was also removed from
[android/app/build.gradle](android/app/build.gradle): no Android source referenced it (only
`ios/Runner/AppDelegate.swift`), it resolved non-reproducibly, and it ships native
libraries that overlap `liblitertlm_jni.so`.

### Verified end to end

On a OnePlus OPD2504 (Android 16, arm64, **7.8 GB RAM**) the app now holds a multi-turn
offline conversation, with RSS plateauing at **~2.06 GB** (peak 2,112 MB) and no OOM kill.

### Known cosmetic issue: terminal punctuation is stripped

Every model reply loses its final punctuation mark — `"I am here for you"`,
`"Yes, of course. I am here for you"`. Punctuation *inside* a reply is fine
(`"Oh no! I am so sorry to hear that. I know…"`), only the last character goes missing.

The cause is in the exported metadata: `stop_tokens` includes punctuation-prefixed
variants such as `".<turn|>\n"`, `"?<turn|>\n"`, `"!<turn|>\n"`. When the model emits
`anxious?<turn|>\n` the runtime matches the whole stop string and truncates it, taking the
`?` with it. To fix, edit the `LlmMetadataProto.pbtext` to drop the punctuation-prefixed
stop tokens before rebundling — but verify generation still terminates, since those
variants exist because the tokenizer merges punctuation with the turn marker.

### Historical diagnosis

Sending any message (e.g. "hello") kills the app. It is *not* a Dart exception and *not* a
native crash. Android's own process-exit record is unambiguous:

```
$ adb shell dumpsys activity exit-info com.example.sanctuary
  reason=3 (LOW_MEMORY)  importance=100  rss=6.4GB … 7.4GB
```

Ten consecutive runs, every one `reason=3 (LOW_MEMORY)`.

### The evidence that this is a conversion defect

Google's own Gemma 4 E2B `.litertlm` is **the same size as ours** and uses **a quarter of
the memory** on the same class of hardware:

| | `litert-community/gemma-4-E2B-it-litert-lm` | This model |
| --- | --- | --- |
| File size | 2,583 MB | 2,549 MB |
| **Android CPU peak RSS** | **1,733 MB** | **6,000 – 7,400 MB** |
| iOS CPU peak RSS | 607 MB | — |
| Max context | 32,000 tokens | 4,096 |
| Weights | mixture of 2-bit, 4-bit, 8-bit | uniform ≈int4 |

CPU is the correct, intended backend for `.litertlm` — the official build runs fine there.
So "use the GPU" is **not** the fix, and in any case this container has no GPU submodel:
the loader logs `TF_LITE_PREFILL_DECODE not found for backend constraints. Skipping.` and
`LiteLmEngine.create` on GPU fails with
`INTERNAL: ERROR: [llm_litert_compiled_model_executor.cc:1955]`.

Measured resident-set growth during load (Nothing Phone A059P, Android 16, 11.7 GB RAM,
arm64):

```
t=0s    0.39 GB   app idle
t=15s   1.14 GB   container mmapped, tokenizer + embedder loaded
t=25s   5.99 GB   XNNPACK delegating the prefill/decode graph
t=30s   killed
```

Freeing device memory does not help — with `MemAvailable` at 7.26 GB it still died at
~6 GB.

### Root cause: the wrong quantization recipe

The export notebook passes:

```python
quantization_recipe='weight_only_wi4_afp32'
```

**This is the bug.** `weight_only_*` stores weights at INT4 *on disk* but computes in
FP32 — so at delegate-init XNNPACK **dequantizes every weight tensor to FP32**, an **8×
expansion**. `dynamic_*` recipes instead quantize activations on the fly and feed the
integer weights straight into integer kernels, so weights stay compact in memory.

That exactly explains the otherwise paradoxical symptom — a **small file with a huge
runtime footprint**:

| | Size |
| --- | --- |
| `tf_lite_prefill_decode` on disk (INT4) | 1.16 GB |
| Same weights dequantized to FP32 | ~9.3 GB |
| Delegated to XNNPACK | 2459 / 3056 nodes (~80%) |
| Observed RSS before the kill | 6.0 – 7.4 GB |

and it matches the measured timeline precisely: RSS sits at 1.14 GB until XNNPACK starts
delegating the prefill/decode graph, then climbs past 6 GB in ten seconds.

Google's documented export command for this exact model passes **no**
`quantization_recipe` at all, taking the `dynamic_wi8_afp32` default:

```bash
litert-torch export_hf \
  --model=google/gemma-4-E2B-it \
  --output_dir=/tmp/gemma4_2b \
  --externalize_embedder \
  --jinja_chat_template_override=litert-community/gemma-4-E2B-it-litert-lm
```

The notebook matches this except for the added `quantization_recipe` and
`single_token_embedder`.

### Contributing factors

- **The 2/4/8-bit mobile scheme is not a recipe flag.** Official Gemma 4 E2B reaches
  ~0.8 GB of resident weights via a **QAT checkpoint**
  (`google/gemma-4-E2B-it-qat-mobile-transformers`, a hybrid 2-bit/8-bit "wNa8o8" scheme
  with 2-bit decode layers). No post-training recipe reaches that from the bf16 weights.
- **Unbounded prefill.** No `prefill_lengths` was passed, giving `prefill_chunk_size: -1`,
  so the prefill activation buffer is sized for the whole context. Google's example uses
  `prefill_lengths=[256, 512, 1024]`.
- **Load-bearing monkey-patches.** The notebook disables abstract-method enforcement and
  hardcodes the cache length:

  ```python
  cls.__abstractmethods__ = frozenset()
  cls.get_max_length = lambda self: 4096
  ```

  plus a patch to `importlib.metadata.version` to hide the installed `torch` version.
  These force an exporter that does not properly support this model to run anyway, and are
  the likely source of the **453 XNNPACK partitions** (a clean conversion delegates in a
  handful). [litert-torch#994](https://github.com/google-ai-edge/litert-torch/issues/994)
  reports E-series exports of this kind producing pad tokens or garbage text, so **fixing
  memory may reveal a second, output-quality problem.**

- **Embeddings were externalized correctly** — `externalize_embedder=True` was passed, and
  the container does carry separate embedder/PLE sections. This was *not* a fault.

### Plan to fix

1. **Change one word and re-export.** To keep 4-bit weights, switch the prefix rather than
   dropping the argument:

   ```python
   quantization_recipe='dynamic_wi4_afp32'   # was: weight_only_wi4_afp32
   ```

   The bit-width was never the problem — the compute path was:

   | Recipe | On disk | At runtime | Decoder resident |
   | --- | --- | --- | --- |
   | `weight_only_wi4_afp32` (current) | INT4 | dequantized to **FP32** | ~9.3 GB |
   | `dynamic_wi4_afp32` (use this) | INT4 | INT4 → integer kernels | ~1.16 GB |
   | `dynamic_wi8_afp32` (the default) | INT8 | INT8 → integer kernels | ~2.3 GB |

   XNNPACK has native `qd8-f32-qc4w` kernels that consume 4-bit weights directly, so
   nothing upconverts. Because the disk format is already INT4, **the file should stay
   ~2.5 GB while RSS drops to ~1.5–2 GB** — if the file jumps to ~3.7 GB you have landed on
   `wi8` by mistake. Cheapest possible test; everything else is secondary.
2. **Add bounded prefill and an explicit cache length**, e.g.
   `prefill_lengths=[128, 256, 512]` and `cache_length=2048`, which is ample for a
   companion chat and shrinks the KV cache from the current 4096.
3. **Remove the monkey-patches** by pinning matching `litert-torch` / `torch` versions
   rather than suppressing the version check and the abstract-method guard. If the export
   cannot run without them, the toolchain does not support this model and needs upgrading.
4. **Sanity-check the artifact before flashing it.** In the `tflite` log the partition
   count for the main subgraph should drop from 453 to single digits; on device, peak RSS
   should land near 1.7 GB.
5. **Validate output quality separately.** Given #994, confirm the model emits coherent
   text, not pad tokens — a memory fix does not guarantee a working model. If output is
   garbled, temporarily switch to `dynamic_wi8_afp32` as a *diagnostic* to isolate whether
   4-bit quantization is degrading the fine-tune or the export toolchain is at fault. That
   costs ~1 GB more RSS, which is affordable at 1.7 GB but not at 7 GB.
6. **If the footprint is still too high**, fine-tune from
   `google/gemma-4-E2B-it-qat-mobile-transformers` instead of the bf16 checkpoint to
   inherit the official 2/4/8-bit mobile scheme.

No app changes are needed; `LiteRtService` already defaults to CPU.

### Still open

1. The chat template used **during training**. The container's template was overridden with
   the official `litert-community/gemma-4-E2B-it-litert-lm` one (`<|turn>` tags). If the
   fine-tune was trained on different turn markers, the model is being served in a format
   it never saw — which would degrade responses independently of everything above.
2. Whether LoRA adapters were merged (`merge_and_unload()`) before the checkpoint was
   pushed to `Padmanava/gemma_4_mobile_project`.
3. Whether this `.litertlm` has ever emitted a coherent token on any device.

## Development

### Build and install

```bash
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### Debugging the model path

`LiteRtService.logToFile()` appends stage-by-stage progress to
`/sdcard/Download/sanctuary_crash_log.txt`. Because an OOM kill produces **no** Dart stack
trace and **no** tombstone, this file is the most reliable way to see how far
initialization got:

```bash
adb shell cat /sdcard/Download/sanctuary_crash_log.txt
```

When the app disappears, check the exit reason first — it distinguishes an OOM kill from a
real native crash:

```bash
adb shell dumpsys activity exit-info com.example.sanctuary
```

### Measuring model memory off-device

The LiteRT-LM Python API runs the same `.litertlm` on a workstation, which is a far faster
loop than a 2.5 GB push. Install with `pip install litert-lm-api`.

**Do not use `resource.getrusage().ru_maxrss` for this.** Under cgroup v2 it reports the
allocated cgroup memory rather than actual usage — on a Kaggle TPU VM it read a constant
`57784 MB` at every checkpoint while real usage went 68 → 322 → 1543 MB. Read
`/proc/self/status` (`VmRSS`, `VmHWM`) and `/proc/self/smaps_rollup` (`Anonymous`) instead.
`Anonymous` is the figure that predicts device behaviour, since file-backed mmap pages are
evictable but repacked weights are not.

To watch memory climb in real time:

```bash
adb shell "grep VmRSS /proc/$(adb shell pidof com.example.sanctuary)/status"
```

The LiteRT-LM engine logs under the `native`, `litert` and `tflite` tags. The
`Replacing N out of M node(s) … yielding P partitions` lines are the ones to watch for
conversion quality:

```bash
adb logcat -v threadtime | grep -E "native|litert|tflite"
```

### Requirements

- Flutter SDK 3.29+, Android SDK 36, NDK 28.2.13676358
- `minSdk 24`, arm64 device
- `android:largeHeap="true"` is set, but note it only raises the **Java** heap ceiling —
  it has no effect on the native allocations that dominate here.

## References

- [Blazing fast on-device GenAI with LiteRT-LM](https://developers.googleblog.com/blazing-fast-on-device-genai-with-litert-lm/) — PLE/embedding memory-mapping behaviour
- [litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) — official size and per-platform peak-memory table
- [Gemma 4 on LiteRT-LM](https://developers.google.com/edge/litert-lm/models/gemma-4) — the official `export_hf` command for this model
- [Convert PyTorch GenAI models for on-device inference](https://developers.google.com/edge/litert/conversion/pytorch/genai) — `litert-torch export_hf` flags and the `dynamic_wi8_afp32` default
- [ai-edge-quantizer](https://github.com/google-ai-edge/ai-edge-quantizer) — recipe names (`DYNAMIC_WI4_AFP32` vs `WEIGHTONLY_WI4_AFP32`)
- [google/gemma-4-E2B-it-qat-mobile-transformers](https://huggingface.co/google/gemma-4-E2B-it-qat-mobile-transformers) — QAT checkpoint behind the official 2/4/8-bit mobile footprint
- [litert-torch#994](https://github.com/google-ai-edge/litert-torch/issues/994) — E-series exports producing pad tokens / garbage
- [How to convert Gemma-4 to litertlm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/discussions/7) — merging LoRA before export
