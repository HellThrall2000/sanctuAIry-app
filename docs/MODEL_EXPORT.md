# Re-exporting the model to cut memory

Goal: reduce the **Native Heap**, which is the anonymous allocation the kernel
cannot reclaim — repacked weights, the KV cache, and prefill activation buffers.

## Read the right number

| Figure | Meaning |
| --- | --- |
| **Native Heap** | Anonymous. Weights repacked by XNNPACK + KV cache + activations. **This is what a re-export moves.** |
| Private Dirty | Real pressure. What gets the app killed |
| Private Clean | Mostly the model `mmap` — file-backed and **evictable**, re-read from disk |
| RSS | Includes the evictable part. Misleading on its own |

Measured baseline, Nothing A059P (Android 16, 11.7 GB), current export:

```
Native Heap    790 MB
Private Dirty  880 MB
Private Clean  829 MB
RSS Total     1818 MB
PSS Total     1761 MB
```

For comparison, Google publishes **1,733 MB** peak CPU memory for their own
prebuilt E2B on Android. **We are already within 2% of the reference build**, so
expect modest gains here, not a halving. There is no smaller Gemma 4 — the
family is E2B and E4B only.

## What is actually worth changing

Two defects in the current export, both recorded in the README:

1. **Unbounded prefill.** No `prefill_lengths` was passed, so the runtime reports
   `prefill_chunk_size: -1` and sizes the prefill activation buffer for the whole
   4096-token context. Google's own example passes explicit lengths.
2. **Oversized KV cache.** `max_tokens: 4096`, fixed at conversion.

### Measured: the KV cache is not worth re-exporting for

`tool/kv_probe.py` drove ten long messages through a warm process on the OnePlus
Pad, sampling Native Heap ~10s after each reply settled — idle, so activation
buffers are not counted:

```
turn  1   830 MB   << compaction fired
turn  2   785 MB   << compaction fired
turn  3   740 MB
turn  4-10 740-745 MB      (flat, +-5 MB)
```

**Growth with conversation length: zero.** Eight consecutive turns of long
messages moved Native Heap by less than the sampling noise. The cache does not
grow into the context — it is allocated up front, and `kv_increment_size: 16`
produces nothing observable at this scale.

The only movement was *downward*: **~90 MB released** across the two compaction
events. That is the entire heap cost of the live context. Halving the cache
could reclaim at most a fraction of it, against a 2.1 GB PSS.

**So do not re-export for `cache_length`.** The pre-committed rule was "under
30 MB of growth and it is not worth it"; the measurement came in at 0.

### Where the memory actually is

The flat floor is the answer. Native Heap never falls below ~740 MB no matter
what the conversation does — and on disk:

```
/data/data/com.sanctuairy.app/cache/
    gemma-4-E2B-it.litertlm.xnnpack_cache_1785777696_2588147712   788 MB
```

That file and the immovable 740 MB are the same thing: **XNNPACK's repacked
weights**. It is also the whole of the ~1.1 GB Android-versus-iOS gap below. No
export flag reaches it, because it is not a property of the export — it is what
the Android CPU backend does with any weights it is given.

Cutting 2 GB to 1 GB therefore means changing the weights, not the container:
the QAT checkpoint or a smaller model, both under *If that is not enough*.

(A side effect worth knowing: that 788 MB cache is why a warm engine load takes
2.1 s instead of a full repack. Android may evict it under storage pressure, and
the next launch then pays full price. Real on-device footprint is ~3.4 GB, not
the 2.4 GB of the model file.)

## Where to run it

The bf16 checkpoint is ~10 GB, so the export needs a machine with real memory —
Colab **High-RAM**, or a Linux box with 32 GB+. It will not run on the phone or a
laptop with 16 GB.

Gemma is a gated repository: accept the licence on Hugging Face first, then
authenticate.

```bash
pip install -U litert-torch huggingface_hub
hf auth login          # accept the Gemma licence on huggingface.co first
```

## Confirm the flag names before a long run

The official Gemma 4 page documents `export_hf` but **does not list
`prefill_lengths` or `cache_length`** — those come from the LiteRT conversion
docs and this project's own notes. An export takes a long time and fails at the
end on a bad flag, so check first:

```bash
litert-torch export_hf --help
```

If a flag is missing or spelled differently, take the name from `--help` rather
than from this file.

## The export

```bash
litert-torch export_hf \
  --model=google/gemma-4-E2B-it \
  --output_dir=/tmp/gemma4_e2b \
  --externalize_embedder \
  --jinja_chat_template_override=litert-community/gemma-4-E2B-it-litert-lm \
  --quantization_recipe=dynamic_wi4_afp32 \
  --prefill_lengths=128,256,512 \
  --cache_length=2048
```

**`dynamic_`, never `weight_only_`.** `weight_only_wi4_afp32` stores INT4 on disk
but computes in FP32, so XNNPACK dequantises every weight tensor at delegate-init
— an 8× expansion that took peak RSS to 6–7 GB and got the app OOM-killed. That
was the original bug; do not reintroduce it.

**`--jinja_chat_template_override` is not optional.** The chat template lives
inside the container, and this model uses `<|turn>` markers with no
`<start_of_turn>` tokens in its vocabulary. Dropping the override produces a
model that is served in a format it never saw.

### Sanity-check the artifact before pushing it

- **File size should stay ~2.5 GB.** The disk format is already INT4, so a jump
  to ~3.7 GB means you landed on `wi8` by mistake.
- In the conversion log, the XNNPACK partition count for the main subgraph should
  be small. The original broken export produced **453** partitions; a clean one is
  in the single digits.

## Measure the result

```bash
adb push gemma-4-E2B-it.litertlm \
  /sdcard/Android/data/com.sanctuairy.app/files/models/gemma-4-E2B-it.litertlm

python tool/measure_memory.py     # then send a message in the app
```

**Judge it on Native Heap.** If that falls from 790 MB toward 400–500 MB, the
bounded prefill and smaller cache did their job. If only RSS moves, nothing real
changed — RSS includes the evictable mmap and will wander on its own.

Then update `ModelCatalog` with the new size and SHA-256 and re-upload, or the
free-space check and the integrity check will both be wrong:

```bash
stat -c%s gemma-4-E2B-it.litertlm
sha256sum gemma-4-E2B-it.litertlm
```

## If that is not enough

In order of increasing cost:

1. **QAT checkpoint** — `google/gemma-4-E2B-it-qat-mobile-transformers`, a hybrid
   2/4/8-bit scheme with 2-bit decode layers. Quantisation-aware training, so no
   post-training recipe reaches the same footprint from bf16. Requires
   re-fine-tuning from that checkpoint. The ~0.8 GB figure in this project's notes
   is **unverified** — Google's public page does not corroborate it, so measure
   before planning around it.
2. **A smaller model** — Gemma 3 1B, Qwen 2.5 1.5B, Llama 3.2 1B, SmolLM2 1.7B.
   All free and open, all roughly 0.6–1.0 GB of weights, and all **a real step
   down in reply quality**. Halving memory and keeping E2B's replies are not both
   available.

## What a re-export cannot fix

The same file, on Google's own numbers:

```
iOS (iPhone 17 Pro)   607 MB
macOS (M4)            736 MB
Android (S26 Ultra) 1733 MB
```

Identical weights. The ~1.1 GB gap is the **Android XNNPACK CPU backend**
repacking weights into anonymous memory rather than mapping them from the file —
which matches the 790 MB of Native Heap measured here. No export flag and no Dart
code reaches that.
