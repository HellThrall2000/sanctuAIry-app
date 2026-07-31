# Sanctuary — Roadmap

Execution order for `feat-memory-graph`. Technical design lives in
[docs/MEMORY_GRAPH_ARCHITECTURE.md](docs/MEMORY_GRAPH_ARCHITECTURE.md); this file tracks what
is done, what is left, and which decisions should not be re-opened.

**The three goals**

| | Goal | Delivered by | Status |
| --- | --- | --- | --- |
| **G1** | Companion stops sounding robotic | P0 | **Met on stock E2B.** Blocked on the fine-tune until P0.8 |
| **G2** | Per-user knowledge base that learns | P2 + P4 | **Working in lightweight form.** Deterministic facts, pinned + retrieved |
| **G3** | Diary silently constrains behaviour | P1 + P3 | **Not started.** Constraints are stored and injected, but nothing *gates* on them |

---

## Where things stand

| Phase | State |
| --- | --- |
| **P0** — sound human | App-side **done**. P0.6 and P0.8 are model-side and blocked on a retrain |
| **P1** — memory foundations | **Partly done** — fact store, memory screen, journal permission sync. Graph tables, `ai_mode`, chunker outstanding |
| **P2** — extraction | **Lightweight version done** (deterministic). LLM extraction, worker, consolidation outstanding |
| **P3** — retrieval and gates | **Fact-level retrieval done.** Capability gates, chunk retrieval, context assembler outstanding — this is where G3 lands |
| **P4** — chat integration | **Partly done** — profile injection and chat learning. The journal dump is still there |
| **P5** — optional | Not started |

Effort: **S** ≈ under a day · **M** ≈ 1–3 days · **L** ≈ a week+.

Current test suite: **105 passing**, analyzer clean.

---

# What's left

## Blocked on a retrain (model-side, not app-side)

| ID | Task | Effort |
| --- | --- | --- |
| **P0.8** | **Clean the corpus and retrain.** Grep the dataset for `_comma_`, audit for sibling escapes, truncated response rows, and inconsistently expanded contractions | L |
| **P0.6** | Re-export without punctuation-prefixed stop tokens (`".<turn\|>\n"`) — **re-check after P0.8 first**, it may be a corpus artifact | M |

Nothing downstream waits on these: the app runs against stock Gemma 4 E2B today (see
[Dual-model support](#dual-model-support)).

## P1 — remaining foundations

| ID | Task | Effort | Notes |
| --- | --- | --- | --- |
| **P1.1** | Graph tables: `memory_chunk` (+FTS5), `memory_node`, `memory_edge`, `memory_directive`, `memory_capability`, `memory_job` | M | DB is at v2; this is v3. `memory_facts` already exists and stays |
| **P1.2** | Seed app-owned `capability_gate` and `category_member` tables | S | Policy is ours, not the model's guess |
| **P1.3** | `journals.ai_mode` (`none` / `derive` / `full`); migrate `allowAiAccess`; default new entries to `derive` | S | **The mechanism for G3** — `derive` means facts may be extracted but raw text must never be quoted |
| **P1.4** | Journal UI: three modes instead of the two-state toggle, in plain language | S | `journal_screen.dart` |
| **P1.5** | Chunker — paragraph-aware, 200–400 tokens; backfill existing journals | M | FTS5 belongs here, not on `memory_facts` |

**Acceptance:** migration runs clean on a populated v2 database with zero data loss; existing
journals appear as chunks; no raw text from a `derive` entry can reach the model.

## P2 — LLM extraction

The deterministic extractor covers explicit phrasing. This adds the model-driven layer for
everything it cannot reach — *"yeah, Kolkata, born and raised"* produces no fact today.

| ID | Task | Effort | Notes |
| --- | --- | --- | --- |
| **P2.1** | `MemoryWorker`: job queue + **mutex serialising all engine access** | M | Chat and extraction must never share a conversation |
| **P2.2** | Extractor: constrained-JSON prompt → entities, relations, **capabilities**, directives | L | Prefer capabilities over directives — design §3.1 |
| **P2.3** | Defensive parsing: strip fences, `jsonDecode` in try/catch, drop malformed records, fail after 3 attempts, **never lose the chunk** | M | Reprocessable after a model upgrade |
| **P2.4** | Consolidation: dedupe on `(kind, label_norm)`, merge aliases, reinforce salience, decay, conflict resolution | M | Never overwrite `user_edited = 1` |
| **P2.5** | Scheduling: idle/charging only, gated on `MemAvailable`, never during a turn | M | An extraction pass is a full 15–30 s generation |
| **P2.6** | Memory screen becomes **editable** — currently delete-only | S | Correcting a wrong fact matters more than deleting it |

**Risk to measure first (P2.1):** extraction needs a second `LiteLmConversation`, which
allocates its own KV cache — expect **+100–250 MB** over the ~2.0 GB baseline. Fine on the
7.8 GB test device; possibly not on a 6 GB one. Measure before building on it.

## P3 — Gates and chunk retrieval — **G3 lands here**

Constraints are already stored, pinned first, and injected. Nothing *enforces* them; the
model merely sees them and behaves sensibly. That is not the roller-coaster guarantee.

| ID | Task | Effort | Notes |
| --- | --- | --- | --- |
| **P3.1** | Intent classifier — rule-based, ~0 ms, auditable | S | `suggest_activity`, `ask_memory`, `vent`, `seek_technique` |
| **P3.2** | **Capability gates**: condition → capability → blocked categories | M | The generalising layer; one condition blocks hundreds of suggestions |
| **P3.3** | Item-level directive matching on triggers + intent | M | For what capabilities cannot express |
| **P3.4** | Episodic chunk retrieval: FTS5 BM25 + 1-hop graph expansion + recency | M | `quotable = 0` hard-kills `derive` chunks |
| **P3.5** | `ContextAssembler` with a strict token budget; **severity-3 directives never silently dropped** | M | A silent drop is a safety bug |
| **P3.6** | Post-generation guard: scan draft against blocked categories; regenerate once, then safe fallback | M | Belt and braces |

**Acceptance — the roller-coaster integration test.** Seed the journal, run extraction, ask
*"any fun ideas for the weekend?"*, assert the reply contains no term from a blocked category,
and assert the trauma text was never injected. Plus paraphrase probes (*"thinking of hitting a
theme park?"*, *"want to get out and be active?"*).

## P4 — Chat integration

| ID | Task | Effort | Notes |
| --- | --- | --- | --- |
| **P4.1** | Chat uses `ContextAssembler`; **delete the wholesale journal dump** in `_buildSystemInstruction()` | M | Every allowed entry is pasted in full today — breaks around 10 entries |
| **P4.4** | Subtle affordance when memory influenced a reply, inspectable on tap | M | |

**Acceptance:** prompt size stays within budget with 50+ journal entries.

## P5 — Optional

| ID | Task | Effort | Gate |
| --- | --- | --- | --- |
| **P5.1** | EmbeddingGemma-300m vector layer as a 4th scoring term | L | Only if measured recall is insufficient |
| **P5.2** | Export / import encrypted memory backup | M | |
| **P5.3** | Reduce `max_num_tokens` 4096 → 2048 at conversion to cut KV cache | S | Frees headroom for P2's second conversation |

**P5.1 is deliberately last**, but there is now a concrete case for it: `FactRanker` matches on
terms, so *"any ideas for the weekend?"* will not surface a guitar preference — nothing
lexically connects them. Add vectors against that measurement, not on principle.

---

# Shipped so far

## P0 — sound human *(app-side complete)*

| ID | What | Where |
| --- | --- | --- |
| P0.1 | System prompt thinned to identity + safety | `persona.dart` |
| P0.2 | Exemplar seeding (built, flagged **off** — it regressed the fine-tune) | `persona.dart` |
| P0.3 | Per-profile sampler defaults + `kDebugMode` dev panel (long-press the input) | `model_settings.dart`, `dev_settings_sheet.dart` |
| P0.4 | Repeat detection on reply *substance*, reseed-and-retry with widened sampling | `chat_screen.dart`, `litert_service.dart` |
| P0.5 | Two-tier crisis handling with verified resources | `crisis_guard.dart` |
| P0.7 | Decoding determinism diagnosed and fixed | `packages/flutter_litert_lm/` |

**Acceptance:** median reply 25–45 words *(met on stock; gated on P0.8 for the fine-tune)* ·
no opener repeats in a session *(met)* · no `_comma_` on screen *(met, unit-tested)* · replies
end with punctuation *(met on stock)* · every crisis phrase returns the fixed response *(met —
30 phrases, verified on-device that `initializeModel` is never called on a crisis turn)*.

## Memory — the lightweight fact cache

| Piece | File |
| --- | --- |
| `memory_facts` table, DB `v1 → v2` (journals untouched) | `database_service.dart` |
| Deterministic extractor | `fact_extractor.dart` |
| IDF-weighted ranker | `fact_ranker.dart` |
| Store, journal sync, pinned block + recall | `memory_store.dart` |
| Memory screen — per-fact delete, source, and the user's own words as evidence | `memory_screen.dart` |

Verified on-device across a full process kill: taught in one session, recalled in the next.

## Dual-model support

The app runs against **either** model, selected by which file is on the device:

| | `gemma-4-E2B-it.litertlm` (stock) | `model_fixed_v4.litertlm` (fine-tune) |
| --- | --- | --- |
| Persona | full | safety line only |
| Length | capped at 3–5 sentences | uncapped (a quota makes it repeat) |
| Sampler | 1.0 / 64 / 0.95 | 1.2 / 64 / 1.0 |

Everything that differs lives in one `ModelProfile`, so switching back after P0.8 is a file
swap. Saved sampler tweaks are namespaced per profile. Push with `tool/push_model.sh` and keep
the downloaded filename intact — the profile is matched from it. Both models can sit on the
device at once; `ModelPreference` pins the winner, and `findLocalModels` sorts deterministically
rather than by filesystem order.

---

# Decisions not to re-litigate

Each of these cost real diagnostic time. Re-opening them without new evidence will waste it
again.

### The fine-tune's repetition was six stacked bugs, and the seventh is the corpus

| Cause | Fix |
| --- | --- |
| Sampler seed pinned to 0 by the plugin | Vendored fork forwards `SamplerConfig.seed` |
| Top-P 0.95 collapsing to greedy (top token alone exceeded 0.95) | Top-P 1.0 |
| Temperature below 1.0 *sharpening* an over-confident model | 1.2 base, ×1.5 on a repeat retry |
| System-prompt length mandate → padding by repetition | Removed; length is per-profile |
| Reseed replaying the poisoned history it was escaping | Dedup on reply substance + cap |
| Persona framing every reply as a session opener | `PersonaMode.safetyOnly` for the fine-tune |

After all six — temperature 1.8, top-P 1.0, fresh seed, deduplicated history — *"i got fired"*
and *"my girlfriend broke up with me"* still returned an identical sentence. **That
distribution is degenerate; only P0.8 reaches it.** Stock E2B on identical app code answers
correctly, which isolates it to the weights.

### Crisis handling is two tiers: talk first, helpline last

| Tier | Trigger | Behaviour |
| --- | --- | --- |
| `concern` | ambiguous — *"want to die"*, *"ending things"*, *"what's the point"* | **Nothing.** Normal reply; the model asks what is behind it |
| `explicit` | unambiguous intent, plan, or active self-harm | Bypasses model, sampler and memory; fixed reviewed text |

A wall of phone numbers in response to ambiguous distress reads as *"I can't handle you, go
away"*, and is backwards clinically — risk is assessed by talking. Support is only *offered*
if concern recurs (3 turns/session), once, as one line naming one directory, appended after
the companion's own reply.

`CrisisGuard.resources` carries `source` + `verifiedOn` per entry, all read from the operator's
own page on **2026-07-31**. Nothing came from model memory: a dead number here is worse than no
number. Re-verifying is mechanical — open `source`, confirm, bump the date.

**Safety logic stays out of the system prompt.** A loaded prompt degrades every other reply and
does not reliably produce safe ones.

### Memory is pinned *and* retrieved, split by whether a kind is bounded

A person has one name, one home, a handful of constraints — bounded, so carried in every prompt
at fixed cost. Preferences and events grow without limit, so they are searched per-turn and
ride along with the user's message (the system instruction is fixed for a conversation's life;
rebuilding it per turn would re-prefill the history).

Constraints are pinned **first** — absence from the prompt is exactly how a companion
recommends a roller coaster to someone one injured.

An earlier version pinned everything and truncated at 20. That was a correctness bug, not a
scaling one: past twenty facts it silently forgot things with no way to reach them. Overflow
now stays searchable.

**Extraction is deterministic, not model-driven** — an LLM pass costs another 15–30 s
generation per message. The store and injection layers are agnostic about provenance, so P2.2
can write to the same table.

**Precision over recall.** An always-present profile is always able to be wrong, and a wrong
fact makes the companion confidently misremember the user. `"i am sad"` must never become a
name. Relationship names need an unambiguous frame (`named`/`called`) or a capital letter — no
verb blocklist is ever complete, which *"my therapist suggested journaling"* proved by
recording a therapist called *"suggested"*.

**Permission is enforced at the store**, not the call site: `syncJournal` deletes prior facts
then re-extracts only when access is granted, so revoking a toggle or deleting an entry erases
what was learned immediately.

### Prompt wording that has already bitten

- *"in their own words"* → the model quoted the user verbatim every reply. Now says **do not
  quote their phrasing back**.
- *"do not mention that you have it written down"* → the model denied knowing anything, and
  answered *"I don't have access to your personal information"*. Now says it is what you
  remember, use it naturally.
- When recall fails, **log `systemInstruction.length` before theorising.** It separates an
  injection bug from a prompt-wording bug in one run.

---

## Dependencies

```
P0.8 ────────────────────────────►  unblocks G1 on the fine-tune only
P1.1 ─► P1.5 ─► P2.2 ─► P2.4 ─► P3.2 ─► P3.5 ─► P4.1
P1.2 ─────────────────────────────► P3.2
P1.3 ─► P1.4 ─────────────────────► P3.4   (quotable / derive)
P2.1 ─► P2.2
P3.1 ─────────────────────────────► P3.3
P5.1 ─────────────────────────────► optional, after P3.4
```

## Standing checks (every phase)

- `adb shell dumpsys activity exit-info com.example.sanctuary` shows no `LOW_MEMORY`
- Peak RSS under ~2.5 GB (stock currently peaks ~2.03 GB)
- Model still loads on the CPU backend with the 0.13.1 runtime pin
- No raw text from an `ai_mode = 'derive'` journal ever reaches the model
- `flutter test` green — 105 and counting; the crisis and extractor suites encode safety
  behaviour, not just correctness
