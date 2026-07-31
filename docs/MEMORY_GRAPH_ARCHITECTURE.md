# Sanctuary — Memory Graph Architecture

Design for `feat-memory-graph`. Covers three goals:

1. **Voice** — stop the companion sounding robotic.
2. **Knowledge base** — a per-user memory that grows, using a light RAG.
3. **Diary-driven behaviour** — the AI reads the diary *indirectly*, and lets it
   constrain what it says, without the user having to bring it up.

Everything runs on-device. Nothing leaves the phone.

---

## 0. The central insight

The obvious design is "embed the diary, retrieve by similarity, paste into the prompt."
That works for goal 2. **It is not sufficient for goal 3**, and it is worth being precise
about why, because the naive statement of the argument is wrong.

Semantic search works fine when the topic is **in the query**:

| User says | Topic appears in | Vector search |
| --- | --- | --- |
| "should I go to the theme park this weekend?" | the **query** | ✅ retrieves the entry |
| "any fun ideas for the weekend?" | only the **reply the model is about to write** | ❌ nothing to match on |

Retrieval is query-driven. In the second row the query contains no roller-coaster signal at
all — the danger exists only in a response that has not been generated yet.

And the similarity is not literally zero (an amusement park genuinely *is* a fun weekend
activity, so expect ~0.2-0.3). The problem is that it loses **top-k competition**: for
"fun ideas for the weekend", chunks about hobbies and things the user enjoys will outrank a
chunk whose vocabulary is dominated by injury and trauma. This is a recall-at-k problem,
not a zero-similarity one.

That is disqualifying because **the cost is asymmetric**. A missed recall ("what do I know
about my ex") produces a slightly worse reply. A missed trauma constraint produces real
harm. A safety constraint cannot sit behind probabilistic top-k ranking.

So Sanctuary keeps **three** memory types with different retrieval rules:

| Type | Example | When retrieved | Injected as |
| --- | --- | --- | --- |
| **Episodic** | "Broke up with Rahul in March" | Query-driven (BM25 / graph / vectors) | Quoted context |
| **Profile** | "Name is Ana, has a dog called Pepper" | Always (it is small) | Persona preamble |
| **Directive** | "Blocks physical recreation" | **Always evaluated**, fires on *intent* | Hard rule |

Goal 2 is served by episodic + profile. **Goal 3 is served by directives.** Conflating
them is the single most likely way this feature fails.

### 0.1 Constraints attach to conditions, not to items

Banning the string `"roller coaster"` is brittle — it still permits go-karting, skiing,
trampolining, hiking. The constraint belongs one level up, on the **capability** the
condition affects:

```
journal   →  condition: spinal injury
          →  capability: mobility = severely_limited
          →  gate:      BLOCK category = physical_recreation
                        CAUTION category = travel, crowds
```

The roller coaster is then blocked as a *member of a blocked category*, and so is every
activity we never explicitly enumerated. One extracted condition generalises to hundreds of
suggestions, and the extractor has far less to get right.

Item-level directives still exist, for things that are not capability-derived — a specific
person to avoid mentioning, a place with bad associations. So there are two granularities:

| Granularity | Source | Example |
| --- | --- | --- |
| **Capability gate** | condition → capability → category | mobility limited ⇒ block physical recreation |
| **Item directive** | a specific named subject | never bring up the ex unprompted |

Categories are a small fixed taxonomy the app owns (`physical_recreation`, `thrill_seeking`,
`travel`, `crowds`, `alcohol`, `food_restriction`, `social`, `quiet`, `outdoor`), so the
model only has to classify into a closed set rather than invent trigger words.

---

## 1. Goal 1 — Fixing the robotic voice

Observed today on-device:

```
You:  can we talk?
AI:   Yes, of course. I am here for you
You:  I need someone to love me
AI:   I am here for you
You:  what do you know about my ex
AI:   I am sorry to hear that. I know you must feel terrible
```

Short, repetitive, evasive. Four separate causes, in order of impact:

### 1.1 The system prompt literally demands it

```dart
"Keep responses brief, supportive, and helpful."   // chat_screen.dart
```

We are *instructing* terseness and getting it. This one line is the largest single cause.

**But the fix is a shorter prompt, not a longer one.** The model is fine-tuned on a large
corpus of CBT therapist conversations — it already knows how a therapist talks. A long,
prescriptive list of rules competes with that training: it pulls the model into generic
instruction-following mode and *away* from the register it was tuned for. Describing the
voice we want is strictly worse than letting the fine-tune produce it.

So the system instruction stays deliberately thin — identity and safety only, no style
lecture:

```
You are Sanctuary, a private CBT-informed companion. The user is talking to you
on their own device; nothing they say leaves it.

Respond as a therapist would in conversation: reflective, specific, unhurried.
Never diagnose or give medical advice. If the user is in danger, surface real help.
```

### 1.1b Demonstrate the register instead of describing it

The stronger lever is `LiteLmConversationConfig.initialMessages`, which the plugin already
supports (`Message.user` / `Message.model`). Seeding two exemplar exchanges *written in the
fine-tune's own register* sets length, depth and rhythm by example:

```dart
initialMessages: [
  LiteLmMessage.user("i've been feeling really flat this week"),
  LiteLmMessage.model(
    "Flat is a heavy word — it sounds less like sadness and more like the colour "
    "has drained out of things. When did you first notice it settling in? I'm "
    "curious whether it arrived with something, or just crept up."),
  LiteLmMessage.user("i don't know, work maybe"),
  LiteLmMessage.model(
    "Maybe is worth sitting with rather than solving. If you picture a work day "
    "this week, is there a moment where the flatness is sharpest — walking in, "
    "a particular meeting, the drive home?"),
],
```

This costs ~150 tokens of context, requires no prompt engineering, and leverages the
fine-tune rather than fighting it. **Tune this before touching anything else** — exemplars
move length and warmth far more than sampler settings do.

Trade-off to measure: these messages occupy the conversation history permanently and count
against the 4096-token budget (§3.4). If context pressure becomes a problem, drop to a
single exchange.

### 1.2 Sampler settings are conservative

`LiteRtService.initializeModel` already plumbs these through; only the defaults change.

| Param | Now | Proposed | Why |
| --- | --- | --- | --- |
| `temperature` | 0.7 | **0.9** | Main lever against canned phrasing |
| `topK` | 40 | **64** | Widens the candidate pool |
| `topP` | 0.95 | 0.95 | Already fine |

Expose these in a hidden developer panel so they can be tuned on-device without a rebuild.

### 1.3 Repetition has nothing suppressing it

The runtime exposes no repetition penalty, so do it in the prompt. Keep the last 3
assistant openers in memory and append:

```
You have recently opened replies with: "I am here for you", "I'm sorry to hear that".
Do not open this reply in any of those ways.
```

Cheap, and it directly attacks the observed failure.

### 1.4 Terminal punctuation is being eaten

Documented in the main README: exported `stop_tokens` include `".<turn|>\n"`,
`"?<turn|>\n"`, so the runtime swallows the final punctuation mark with the turn marker.
Every reply ends mid-breath, which reads as curt. Fix at conversion time by dropping the
punctuation-prefixed stop variants, then verify generation still terminates.

---

## 2. Storage design

One SQLite database (existing `sanctuary_secure_diaries.db`, migrated `v1 → v2`).
No new native dependencies — see §6 for why that is deliberate.

```sql
-- ── Episodic text, chunked ────────────────────────────────────────────
CREATE TABLE memory_chunk (
  id           TEXT PRIMARY KEY,
  source_kind  TEXT NOT NULL,        -- 'journal' | 'chat'
  source_id    TEXT NOT NULL,        -- journals.id, or session id
  text         TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  sensitivity  INTEGER NOT NULL DEFAULT 0,  -- 0 normal | 1 sensitive | 2 trauma
  quotable     INTEGER NOT NULL DEFAULT 1   -- 0 = derive directives only, never quote
);

-- Lexical retrieval. FTS5 ships with SQLite and gives BM25 ranking for free.
CREATE VIRTUAL TABLE memory_chunk_fts USING fts5(
  text, content='memory_chunk', content_rowid='rowid', tokenize='porter unicode61'
);

-- ── The graph ─────────────────────────────────────────────────────────
CREATE TABLE memory_node (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,   -- person|place|activity|event|emotion|value|condition|topic
  label      TEXT NOT NULL,   -- canonical: 'roller coaster'
  label_norm TEXT NOT NULL,   -- lowercased, stripped — the match key
  aliases    TEXT,            -- JSON: ["rollercoaster","theme park ride"]
  salience   REAL NOT NULL DEFAULT 0.5,
  mentions   INTEGER NOT NULL DEFAULT 1,
  first_seen TEXT NOT NULL,
  last_seen  TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_node_norm ON memory_node(kind, label_norm);

CREATE TABLE memory_edge (
  id         TEXT PRIMARY KEY,
  src_id     TEXT NOT NULL REFERENCES memory_node(id) ON DELETE CASCADE,
  dst_id     TEXT NOT NULL REFERENCES memory_node(id) ON DELETE CASCADE,
  relation   TEXT NOT NULL,   -- caused|fears|avoids|loves|linked_to|happened_at|involves
  weight     REAL NOT NULL DEFAULT 0.5,
  chunk_id   TEXT REFERENCES memory_chunk(id) ON DELETE SET NULL,  -- evidence
  created_at TEXT NOT NULL
);

-- ── Capabilities: the generalising layer (§0.1) ───────────────────────
-- One row per affected capability. This is what makes a single condition
-- gate an entire category of suggestions.
CREATE TABLE memory_capability (
  id          TEXT PRIMARY KEY,
  capability  TEXT NOT NULL,   -- mobility|stamina|vision|hearing|alcohol|diet|crowds|travel
  level       TEXT NOT NULL,   -- unaffected|mild|moderate|severely_limited|none
  condition   TEXT,            -- 'spinal injury' — the cause, for the Memory screen
  chunk_id    TEXT REFERENCES memory_chunk(id) ON DELETE SET NULL,
  confidence  REAL NOT NULL DEFAULT 0.7,
  user_edited INTEGER NOT NULL DEFAULT 0,
  updated_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_capability ON memory_capability(capability);

-- Static app-owned table, seeded at migration. NOT model-generated:
-- the mapping from capability to blocked category is our policy, not the
-- model's guess.
CREATE TABLE capability_gate (
  capability TEXT NOT NULL,
  level      TEXT NOT NULL,
  category   TEXT NOT NULL,   -- physical_recreation|thrill_seeking|travel|crowds|alcohol|...
  action     TEXT NOT NULL,   -- block|caution
  PRIMARY KEY (capability, level, category)
);
-- e.g. ('mobility','severely_limited','physical_recreation','block')
--      ('mobility','severely_limited','thrill_seeking','block')
--      ('mobility','moderate','physical_recreation','caution')

-- ── Directives: item-level behavioural rules ──────────────────────────
CREATE TABLE memory_directive (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,   -- avoid|prefer|handle_with_care|never_mention
  subject      TEXT NOT NULL,   -- 'roller coasters' | 'the ex'
  category     TEXT,            -- membership in the fixed taxonomy, nullable
  triggers     TEXT NOT NULL,   -- JSON array of match terms
  intents      TEXT,            -- JSON: ['suggest_activity'] — intent classes that arm it
  instruction  TEXT NOT NULL,   -- verbatim text handed to the model
  reason       TEXT,            -- PRIVATE. Never injected unless reveal_reason = 1
  reveal_reason INTEGER NOT NULL DEFAULT 0,
  severity     INTEGER NOT NULL DEFAULT 2,  -- 1 soft .. 3 absolute
  chunk_id     TEXT REFERENCES memory_chunk(id) ON DELETE SET NULL,
  active       INTEGER NOT NULL DEFAULT 1,
  user_edited  INTEGER NOT NULL DEFAULT 0,  -- 1 = never auto-overwrite
  created_at   TEXT NOT NULL
);

-- Category membership, so a blocked category resolves to concrete nouns the
-- post-guard (§3/§4) can scan a draft reply for.
CREATE TABLE category_member (
  category TEXT NOT NULL,
  term     TEXT NOT NULL,       -- 'roller coaster','hiking','trampoline park'
  PRIMARY KEY (category, term)
);

-- ── Stable profile ────────────────────────────────────────────────────
CREATE TABLE memory_profile (
  key        TEXT PRIMARY KEY,   -- 'name','pronouns','pet','occupation'
  value      TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.6,
  updated_at TEXT NOT NULL
);

-- ── Extraction work queue ─────────────────────────────────────────────
CREATE TABLE memory_job (
  id         TEXT PRIMARY KEY,
  chunk_id   TEXT NOT NULL,
  state      TEXT NOT NULL,      -- pending|running|done|failed
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL
);

-- ── Phase 2 only: vectors ─────────────────────────────────────────────
CREATE TABLE memory_vector (
  chunk_id TEXT PRIMARY KEY REFERENCES memory_chunk(id) ON DELETE CASCADE,
  dim      INTEGER NOT NULL,
  vec      BLOB NOT NULL        -- Float32List, L2-normalised
);
```

`journals` also gains a column:

```sql
ALTER TABLE journals ADD COLUMN ai_mode TEXT NOT NULL DEFAULT 'derive';
-- 'none'   → invisible to the AI entirely
-- 'derive' → directives/graph extracted, raw text NEVER quoted   ← default
-- 'full'   → may also be quoted verbatim
```

`ai_mode = 'derive'` is the literal implementation of goal 3: *the user does not share it
directly; the AI absorbs its consequences without ever repeating it back.* The existing
boolean `allowAiAccess` maps to `none`/`full` during migration; new entries default to
`derive`.

---

## 3. Pipelines

```
   Journal save / chat turn
             │
             ▼
     ┌───────────────┐
     │ 1. Chunker    │  paragraph-aware, ~200-400 tokens
     └───────┬───────┘
             ▼
     ┌───────────────┐
     │ 2. memory_job │  queued, never blocks the UI
     └───────┬───────┘
             ▼
     ┌───────────────────────────────┐
     │ 3. Extractor (on-device LLM)  │  → nodes, edges, directives, profile
     └───────┬───────────────────────┘
             ▼
     ┌───────────────┐
     │ 4. Consolidate│  dedupe, merge aliases, decay, resolve conflicts
     └───────────────┘

   User sends a message
             │
             ▼
   ┌─────────────────────┐
   │ 5. Intent classify  │  cheap, local
   └──────────┬──────────┘
              ▼
   ┌──────────────────────────────────────────┐
   │ 6. Retrieve                              │
   │    a. Directives  ← intent + triggers    │  ALWAYS
   │    b. Profile     ← all (small)          │  ALWAYS
   │    c. Episodic    ← FTS5 + graph 1-hop   │  query-driven
   └──────────┬───────────────────────────────┘
              ▼
   ┌─────────────────────┐
   │ 7. Assemble context │  strict token budget
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │ 8. Generate         │
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │ 9. Post-guard       │  scan draft against avoid-list; regenerate once
   └─────────────────────┘
```

### 3.1 Extractor prompt

Runs on the same Gemma 4 model, on a **separate short-lived conversation** (see §6.2).
Constrained to JSON:

```
Extract durable facts from this diary entry. Output ONLY JSON.

{
  "entities":     [{"kind":"activity","label":"roller coaster","aliases":["rollercoaster"]}],
  "relations":    [{"src":"roller coaster","relation":"caused","dst":"spinal injury"}],
  "capabilities": [{"capability":"mobility","level":"severely_limited",
                    "condition":"spinal injury"}],
  "directives":   [{"kind":"avoid","subject":"roller coasters",
                    "category":"thrill_seeking",
                    "triggers":["roller coaster","theme park","amusement park"],
                    "intents":["suggest_activity"],
                    "instruction":"Never suggest roller coasters or amusement parks.",
                    "reason":"The user was seriously injured on one.",
                    "severity":3}],
  "profile":      [{"key":"mobility","value":"limited since spinal injury"}]
}

capability ∈ {mobility, stamina, vision, hearing, alcohol, diet, crowds, travel}
level      ∈ {unaffected, mild, moderate, severely_limited, none}
category   ∈ {physical_recreation, thrill_seeking, travel, crowds, alcohol,
              food_restriction, social, quiet, outdoor}

Rules:
- Prefer a capability over a directive. Capabilities generalise; directives do not.
  A spinal injury is a mobility capability, not a list of banned activities.
- Only emit a directive for something that a capability cannot express
  (a specific person, place, or memory to avoid raising).
- Only facts that stay true for months. No moods, no one-off events.
- "reason" is private and will never be shown to the user.
ENTRY:
<<<{chunk}>>>
```

The "prefer a capability" rule matters: it is what stops the extractor emitting a
brittle list of banned nouns and pushes it toward the one durable fact that generalises.

Parse defensively: strip markdown fences, `jsonDecode` in a try/catch, drop malformed
records, mark the job `failed` after 3 attempts. **A failed extraction must never lose the
chunk** — the raw text stays in `memory_chunk` and can be reprocessed after a model upgrade.

### 3.2 Intent classification (step 5)

Directives fire on *intent*, so we need one. Start with a keyword/regex classifier — no
model call, ~0 ms:

| Intent | Signals |
| --- | --- |
| `suggest_activity` | "what should i do", "fun", "weekend", "bored", "ideas", "plans" |
| `ask_memory` | "remember", "did i tell you", "what do you know about" |
| `vent` | first-person affect with no question mark |
| `seek_technique` | "how do i", "help me stop", "technique", "cope" |
| `crisis` | self-harm / suicidal ideation lexicon → **bypasses everything**, §7 |

Rule-based is deliberate: it is auditable, instant, and testable. Upgrade to a model call
only if measured recall is poor.

### 3.3 Retrieval scoring

```
score(chunk) = 0.55 · bm25_norm          (FTS5)
             + 0.30 · graph_proximity     (1-hop from matched entities)
             + 0.15 · recency_decay       (exp, 90-day half-life)
             × quotable                   (0 hard-kills 'derive' chunks)
```

Take top-k (k = 4). Directives bypass scoring entirely — they are matched, not ranked.

### 3.4 Context assembly and budget

Container is `max_num_tokens: 4096`. Fixed allocation:

| Slot | Budget | Overflow rule |
| --- | --- | --- |
| Persona | ~250 | fixed |
| Directives | ~400 | severity desc, then recency; **never dropped silently** |
| Profile | ~150 | confidence desc |
| Episodic | ~700 | score desc, whole chunks only |
| History | ~1200 | sliding window |
| Generation headroom | ~1400 | — |

If directives exceed budget, drop lower-severity ones **and log it** — a silently dropped
severity-3 directive is a safety bug, not a UX detail.

---

## 4. Worked example — the roller coaster

The acceptance test for this whole feature.

**Step 1 — Journal saved** (`ai_mode = 'derive'`, sensitivity 2):
> *"Last summer at the amusement park the roller coaster derailed. I broke my spine and
> still can't walk properly. I don't like talking about it."*

**Step 2 — Extraction:**
```
nodes:      roller coaster (activity) · amusement park (place) · spinal injury (condition)
edges:      roller coaster --caused--> spinal injury
capability: mobility = severely_limited   (condition: spinal injury)   ← the generalising fact
directive:  kind=avoid subject="roller coasters" category=thrill_seeking severity=3
            reason="User was seriously injured on one."   ← private, reveal_reason=0
profile:    mobility = limited since spinal injury
```

The capability is doing the heavy lifting. Via `capability_gate` it resolves to:

```
BLOCK physical_recreation · BLOCK thrill_seeking · CAUTION travel · CAUTION crowds
```

so hiking, go-karting, trampolining and skiing are all blocked too — **none of which the
extractor ever had to enumerate.**

**Step 3 — Months later:** *"any fun ideas for the weekend?"*

- Vector similarity to the journal chunk: ~0.2-0.3, and it loses top-k to chunks about
  things the user enjoys. **Naive RAG does not surface it.**
- Intent classifier: `suggest_activity`.
- Capability gate: `mobility=severely_limited` → blocked categories resolved. **Hit**,
  with no dependence on query wording.
- Chunk is `quotable=0`, so the trauma text is **never** injected.

**Step 4 — Assembled context:**
```
[Standing instructions]
- Do not suggest physical recreation or thrill-seeking activities.
- The user has severely limited mobility. Be careful with travel and crowds.
Do not explain why you are avoiding a topic unless they raise it.
```

Note what is *absent*: the accident, the spine, the amusement park. The model receives the
**consequence** without the memory — which is precisely goal 3.

**Step 5 — Output:** suggests a quiet café, a film, a friend visit. Never mentions the
accident. The user never had to say it.

**Step 6 — Post-guard:** draft scanned against every `avoid` subject and alias. On a hit,
regenerate once with the directive escalated; if it hits again, fall back to a safe
templated reply. Cheap insurance, and in a mental-health app the right kind of paranoia.

---

## 5. Learning loop (goal 2)

**Write path.** After each chat session, queue the transcript for the same extractor. Chat
facts land with `confidence = 0.6` (vs `0.8` for journals — deliberate speech is stronger
evidence than chat).

**Consolidation.**
- *Dedupe*: match on `(kind, label_norm)`; merge alias sets.
- *Reinforce*: on re-mention, `mentions += 1`, `salience = min(1, salience + 0.1)`, bump `last_seen`.
- *Decay*: weekly, `salience *= 0.98`; below 0.15 and `mentions <= 1`, archive.
- *Conflict*: newer wins for `memory_profile`; the old value is kept in an audit table.
  **Never auto-overwrite a row with `user_edited = 1`.**

**The Memory screen — non-negotiable.** A privacy-first app that silently accumulates a
psychological profile is a contradiction. Ship a screen that lists every node, directive
and profile fact, showing what it learned, from which entry, and when — with edit, delete,
and "forget everything from this journal". Deleting a journal cascades to its chunks,
edges and directives.

---

## 6. Technology choices

### 6.1 Why FTS5 + graph before vectors

`sqflite` already bundles FTS5 with BM25 ranking. Zero new dependencies.

The interesting objection is that lexical search cannot connect *"my ex"* to a journal that
only says *"Rahul"*. True — **and the graph solves it**, because the extractor already
recorded `Rahul --former_partner--> user`. An LLM-built graph *is* a semantic index; for a
few hundred journal entries it substitutes for embeddings almost entirely.

Add vectors in Phase 2 only if measured recall justifies it:
[EmbeddingGemma-300m](https://huggingface.co/litert-community/embeddinggemma-300m) is
768-dim (Matryoshka-truncatable to 128), <15 ms inference. At a few thousand chunks,
brute-force cosine over a `Float32List` in Dart is sub-millisecond — **no HNSW, no
`sqlite-vec`, no ObjectBox needed.** Score it as a fourth term and re-tune weights.

Deliberately **not** using [`ai_edge_rag`](https://pub.dev/packages/ai_edge_rag) /
`localagents-rag`: it pulls the MediaPipe GenAI stack, whose native libraries overlap
`liblitertlm_jni.so`. We removed `tasks-genai` for exactly that reason, and the
LiteRT-LM runtime pin (0.13.1) is hard-won. Reintroducing an overlapping native stack is
the single most likely way to break a working build.

### 6.2 Concurrency — the real constraint

`LiteRtService` is a singleton holding **one** `LiteLmConversation`. Extraction cannot
share it: interleaving extraction turns into the chat conversation would poison its KV
cache and its history.

- Add a `MemoryWorker` with a `Mutex` serialising **all** engine access.
- Extraction uses a **second, short-lived** conversation from the same engine, disposed
  immediately after each batch.
- **Measure first.** A second conversation allocates its own KV cache; at
  `max_num_tokens: 4096` expect ~100-250 MB on top of the ~2.06 GB baseline. On the 7.8 GB
  OnePlus that is fine; on a 6 GB device it may not be. Gate extraction on
  `MemAvailable` and defer when the app is foregrounded.
- Extraction runs when idle/charging, never during an active chat turn.

### 6.3 New files

```
lib/models/     memory_node.dart · memory_edge.dart · memory_chunk.dart
                memory_directive.dart · retrieval_result.dart
lib/services/   memory_database_service.dart   schema, migration, DAO
                memory_extractor.dart          LLM → JSON → graph
                memory_retriever.dart          intent + FTS5 + graph + scoring
                context_assembler.dart         budgeting, prompt building
                memory_worker.dart             queue, mutex, scheduling
                response_guard.dart            post-generation avoid-list scan
lib/screens/    memory_screen.dart             user-facing memory inspector
```

`chat_screen.dart` loses its prompt-building responsibility entirely — it calls
`ContextAssembler` and renders. The current `_buildSystemInstruction()` (which dumps every
allowed journal into the system prompt) is deleted; it does not scale past ~10 entries and
is the thing goal 3 is replacing.

---

## 7. Safety

- **Crisis intent outranks everything.** Self-harm signals bypass memory retrieval, persona
  and sampler settings, and return a fixed, reviewed response with real-world resources.
  Never generated, never sampled.
- **Directives are never silently dropped** (§3.4).
- **`reason` is private by default.** The model may act on a constraint without being told
  why — that is the point of `ai_mode = 'derive'`.
- **Extraction failures are logged, not swallowed**, and surfaced on the Memory screen.
- The companion still must not diagnose or treat; the disclaimer in the README stands.

---

## 8. Phasing

| Phase | Scope | Ships |
| --- | --- | --- |
| **1a** | Delete "keep responses brief"; thin the system prompt; **add `initialMessages` exemplars**; temperature 0.9 / topK 64 | Immediately, no schema change |
| **1b** | Anti-repetition opener list | Small follow-up |
| **2** | Schema + migration + seeded `capability_gate` / `category_member` + Memory screen (read-only) | Foundations, user-visible |
| **3** | Extractor + worker + consolidation | Graph and capabilities start filling |
| **4** | Retriever + assembler + **capability gates** + directives + post-guard | **Goal 3 lands** |
| **5** | Chat integration; delete `_buildSystemInstruction()` | Goal 2 complete |
| **6** | *Optional* EmbeddingGemma vector layer | Only if measured recall demands it |

**Phase 1a is the highest value-per-line work in this document** and is worth shipping on
its own — it is a handful of lines against the most visible complaint, and it needs no
schema, no worker and no migration. Tune the exemplars until the voice is right *before*
building any of the memory machinery, because every later phase spends context budget that
competes with those exemplars.

## 9. How we know it works

- **Unit**: chunker boundaries; JSON parsing against malformed model output; scoring;
  budget overflow; alias dedupe; decay.
- **The roller-coaster scenario as an automated integration test**: seed the journal,
  run extraction, assert a severity-3 directive exists, ask "fun ideas for the weekend?",
  and assert the response contains no avoid-term. This is the acceptance test for the
  whole branch.
- **Adversarial**: paraphrase probes ("thinking of hitting a theme park?"), and confirm
  `derive` chunks are never quoted verbatim.
- **Regression**: peak RSS stays under ~2.5 GB with the worker running; no LOW_MEMORY
  exits (`adb shell dumpsys activity exit-info`).
- **Voice**: fixed prompt set before/after, checking reply length and opener variety.
