# Wellness companion + daily tracker — architecture

> Status: **designed, not built.** Branch: TBD off `main`.

## Context

The app today is an offline mental-health companion: Gemma 4 E2B on-device via
LiteRT-LM, a passcode diary, BM25 retrieval over past conversations, and a
per-message mood signal. The pivot keeps all of that machinery and changes what
it is *for*: a **wellness companion with a daily tracker**, where the tracker
feeds the model so it can coach against goals the user has set, notice where they
are slipping, and say something useful about it.

Three decisions frame everything below:

| Decision | Consequence |
| --- | --- |
| **Manual logging only** | Ships on the current `pubspec.yaml`. No new dependency, no new permission, no Health Connect review. Nothing leaves the device. |
| **Coach from a compact digest** | The model sees a short deterministic summary, never raw rows. ~100 tokens. |
| **Wellness-first, therapy language out** | Diary and crisis triage stay. The CBT/therapist register goes. Mood becomes one metric among several. |

### The constraint that shapes the whole design

The model has a **4,096-token window**. The system instruction already costs
~3,744 chars ≈ **1,040 tokens (25%)**. After `reserveForReply` (700),
`reserveForTemplate` (250), an assumed prompt (~667) and `minimumHistoryTokens`
(400), there are roughly **1,039 tokens of slack** — shared with any future
growth in pinned facts, digests and session summaries.

**So the tracker gets a budget, and it is small: ~350 chars / ~100 tokens.** For
scale, `RelationshipLog.promptBlock()` renders three lines in ~240 chars. The
tracker digest is the same shape and the same size. Raw rows never reach the
model.

---

## Backend

### 1. Schema — one new table, plus goals (`database_service.dart` v4 → v5)

```sql
-- What the user is working towards. Few, bounded, user-set.
-- id is a SLOT KEY, so restating a goal corrects it rather than duplicating —
-- the same trick memory_facts uses for 'relationship:wife'.
CREATE TABLE IF NOT EXISTS goals(
  id         TEXT PRIMARY KEY,   -- 'goal:sleep', 'goal:movement', 'goal:habit:meditate'
  metric     TEXT NOT NULL,      -- matches daily_metric.metric
  target     REAL NOT NULL,      -- 7.0 hours | 8000 steps | 1.0 (a boolean habit)
  cadence    TEXT NOT NULL,      -- 'daily' | 'weekly'
  label      TEXT NOT NULL,      -- the user's own words: "sleep 7 hours"
  createdAt  TEXT NOT NULL,      -- UTC ISO-8601
  archivedAt TEXT                -- NULL = active
);

-- One row per metric per LOCAL day. Upsert, never append.
CREATE TABLE IF NOT EXISTS daily_metric(
  day      TEXT NOT NULL,        -- 'yyyy-MM-dd', LOCAL — see §2
  metric   TEXT NOT NULL,        -- 'sleep' | 'water' | 'movement' | 'mood' | 'habit:<slug>'
  value    REAL NOT NULL,        -- booleans stored as 0.0 / 1.0
  loggedAt TEXT NOT NULL,        -- UTC ISO-8601
  PRIMARY KEY (day, metric)
);
CREATE INDEX IF NOT EXISTS idx_metric_day ON daily_metric(day DESC);
```

**One table for both built-in metrics and user-defined habits.** `metric` is a
string key; the four built-ins are `sleep`, `water`, `movement`, `mood`, and a
custom habit is `habit:meditate`. One mechanism, one query path, and a new habit
needs no migration.

**Migration rules — these are not optional.** `database_service.dart` documents
that a failed migration takes the whole `onUpgrade` transaction down and leaves
the app unable to open its own database. That has already happened once here,
when an FTS5 `CREATE VIRTUAL TABLE` inside `onCreate` bricked the schema. So:

- `_createTrackerTables(Database db)` contains **only** `CREATE TABLE IF NOT
  EXISTS` and `CREATE INDEX IF NOT EXISTS`. No `ALTER`, no backfill, no
  `SELECT` from a table that might not exist, no virtual table, no trigger.
- Called from **both** `_onCreate` and `_onUpgrade` (`if (oldVersion < 5)`),
  exactly as `_createMemoryTable` and `_createCompanionTables` already are.
- `IF NOT EXISTS` is what makes one helper safe on both paths.

### 2. Local day boundaries — the trap

Every other store here writes **UTC ISO-8601**. The tracker must key on the
**local** day, and there is exactly one existing primitive for it:
`UsageMetrics._keyFor`, whose doc comment states the rule:

> Local dates, deliberately, not UTC. "How long did I use this on Tuesday" means
> the user's Tuesday; a UTC key would split their evening in two for anyone west
> of Greenwich.

**Extract it** into `lib/services/day_key.dart` as `DayKey.of(DateTime)` /
`DayKey.today()` and have both `UsageMetrics` and `WellnessLog` use it. Deriving
a day key from a UTC string is the bug this prevents, and it is invisible until a
user in IST logs water at 11pm and it lands on tomorrow.

`UsageMetrics._attribute` also contains the only midnight-walk in the repo, if a
metric ever needs splitting across a day boundary.

### 3. `WellnessLog` — the service (`lib/services/wellness_log.dart`)

Modelled directly on `RelationshipLog`: a singleton over `DatabaseService`, with
caps as named constants and a `promptBlock()` that renders the digest.

```dart
enum Metric { sleep, water, movement, mood }   // built-ins; habits are free-form keys

class Goal { final String id, metric, label; final double target;
             final String cadence; final DateTime createdAt; final DateTime? archivedAt; }

class WellnessLog {
  static final WellnessLog instance = WellnessLog._();

  /// A week is the window a person can actually feel. Shorter reads as nagging,
  /// longer stops being actionable.
  static const int adherenceWindow = 7;

  /// Below this many logged days, say nothing about trends at all — the same
  /// reasoning as RelationshipLog.minReadingsForTrend: asserting a pattern off
  /// two days is exactly what makes a companion feel presumptuous.
  static const int minDaysForAssessment = 4;

  /// Hard ceiling on the rendered digest. See the token budget above.
  static const int maxDigestChars = 350;

  Future<void>          log(String metric, double value, {DateTime? when});
  Future<Map<String, double>> forDay(String day);
  Future<List<double?>> history(String metric, {int days = adherenceWindow});

  Future<void>          setGoal(Goal goal);          // upsert by slot id
  Future<List<Goal>>    activeGoals();
  Future<void>          archiveGoal(String id);

  Future<int>           streak(String metric);       // consecutive days meeting target
  Future<double>        adherence(String metric, {int days = adherenceWindow});
  Future<Goal?>         weakestGoal();               // lowest adherence, ties broken by recency

  Future<String?>       promptBlock();               // the digest — see §4
  Future<void>          clear();
}
```

**Assessment is deterministic and happens here, not in the model.** The model is
handed the conclusion ("movement is where they are slipping"), never the numbers
to derive it from. A 2B model asked to compute adherence from a table will get it
wrong and then coach confidently from the wrong answer.

### 4. The digest — the heart of the design

Follows `RelationshipLog.promptBlock()` exactly: every line conditional, the whole
block `null` when there is nothing worth saying, framed as **observation, not
instruction**. Its doc comment records why that matters:

> …the model reliably follows the *shape* of what it is given: told to be gentle
> it announces its gentleness.

Target render (~290 chars ≈ 81 tokens):

```
What they are working on:
Their goals: sleep 7 hours, move 30 minutes, drink 2 litres.
This past week they hit sleep 5 days of 7 and movement 2 of 7.
Movement is the one slipping.
They have logged something 12 days running.
```

Composition rules:

| Line | Emitted when |
| --- | --- |
| goals | any active goal exists; at most 3, by `createdAt` |
| adherence | `loggedDays >= minDaysForAssessment`; at most 2 metrics named |
| the weak spot | `weakestGoal() != null` **and** its adherence < 0.5 |
| streak | `streak >= 3` — below that it is not yet a streak |

Truncated at `maxDigestChars`, and **`null` if no line qualifies**. A user with no
goals and no logs adds zero tokens.

Numbers are rendered as words in a sentence (`"5 days of 7"`), never as a table
or a list of key/value pairs. `MemoryCache.knowledgeBlock()`'s doc records what
happens otherwise — four labelled blocks taught the model to *cite* rather than
*know*, answering "do I swim" with *"You mentioned swimming in your diary."*

### 5. Where it reaches the model

Two paths, both already built.

**a. The system instruction, via `MemoryCache`.** Add `String? _wellnessBlock`,
populate it in **both** `_reloadAll()` and `refreshProfile()` (the cheap
post-turn refresh), and emit it inside `knowledgeBlock()` between the
relationship trend and the session summaries — **with no new preamble**, under
the single existing heading. Add it to the `lines.isEmpty && trend == null &&
sessions.isEmpty` null-guard and to `reset()`.

**b. The mid-conversation rider — this is the part that is easy to miss.** The
system instruction is fixed for the life of a conversation. A user who logs their
water *while chatting* cannot reach it. `MemoryCache` already solves this exact
problem for diary entries with `_notesUnseen` / `hasUnseenNotes` /
`markNotesSeen()`, consumed in `chat_view.dart` as a rider on the next user turn.
**Reuse that mechanism**: `markWellnessChanged()` on log, and let the next turn
carry the refreshed block. Without it, "I just logged my run" gets a blank look.

### 6. Nudges

`NudgeService.compose()` is a priority ladder, most specific first. Insert
tracker branches **above** the generic fallback:

1. a goal at risk (`adherence < 0.5` and today unlogged)
2. a streak about to break (logged yesterday, not today, streak ≥ 3)
3. …existing event/topic branches…

Reuse `_respectQuietHours` and `minimumGap = 20h` unchanged. Its doc — *"Someone
who has put the app down for a fortnight should come back to one message, not
fourteen"* — applies with more force to a tracker, which has a natural pull
toward daily nagging.

**Do not add per-habit reminders in v1.** `NotificationService` has exactly one
check-in id, and the class doc warns that *"a companion that stacks up four unread
pings is not attentive, it is nagging."* A per-habit reminder set needs new ids,
new channels and a different scheduling shape (`matchDateTimeComponents`), and is
its own piece of work.

### 7. Persona — wellness-first, therapy language out

`lib/services/persona.dart`. The changes are small; the risk is not.

- `coreTraits` — drop *"You are their friend, not their therapist"*. The
  replacement is a companion who notices and encourages without managing.
- `safetyInstruction` — keep *"never claim to be human"*. Keep a no-medical-advice
  clause (a wellness app needs it more, not less) but reword out of the clinical
  register.
- `conversationStyle` — add **one** coaching clause, and phrase it as a
  prohibition.

> **⚠️ The one thing most likely to go wrong.** `persona.dart:127-139` records
> that a ceiling phrased as a permitted action becomes a **quota**: "ask at most
> one question" made the model end *every* reply with a question. A clause like
> *"point out where they are slipping"* will produce a progress report every
> single turn, which is exactly the app nobody wants. Phrase it as a
> prohibition — *"Do not bring up their goals unless they raise them or it is
> genuinely relevant to what they just said"* — and **measure it over ≥20
> consecutive turns before merging.**

### 8. Wiring the erase path

`MemoryPanel._forgetAll()` clears `MemoryStore`, `ChunkStore` and
`RelationshipLog`. **Add `WellnessLog.clear()`** or "forget everything" silently
leaves the tracker behind. (`MemoryPanel` currently has zero call sites — it is
built and unreachable. Surfacing it is nearly free and is the honest counterpart
to a tracker that now knows more about the user.)

---

## Frontend

### 1. Getting a third surface into the shells

**`FocusBloomShell` (phone) — cheap.** Add `tracker` to the private `_Sheet`
enum, one `tab(...)` in the `Row`, one `_sheet(...)` in the `Stack`. No layout
maths changes. Caveat: four `Expanded` tabs in a 58px pill at 12px Caprasimo
crowds on a small phone — drop `navLabel` to 11 or shorten labels.

**`WarmCompanionShell` (tablet) — the awkward one.** It is hardwired to two
drawers via two booleans (`_leftOpen`, `_rightOpen`). `_drawer(...)` already takes
`side` and `width` as parameters, so **only the state model changes**: replace the
two booleans with a single `_Drawer? _open` enum plus a side/width lookup, and add
a header button. ~20 lines.

### 2. `TrackerPanel` — the new surface

Follows `SettingsPanel`'s section rhythm exactly (`Organic.space4` between
sections, `space2` between a label and its content):

| Section | Built from |
| --- | --- |
| Today | `OrganicCard` per metric, `OrganicCard.onTap` to log |
| This week | 7-day strip (see §3) |
| Goals | `OrganicCard` + `OrganicButton(block: true)` to add |
| Streaks | text + dots |

`MemoryPanel` is the working template for a full-screen variant — themed custom
header (no `AppBar`), `ListView.separated`, and a `_ago(DateTime)` helper that
lifts straight out for "last logged 3d ago".

### 3. Net-new widgets — the real work

The design system has **no progress bar, ring, chart, streak indicator, calendar
or heatmap**. None of it is hard; all of it is new.

| Widget | Effort | Note |
| --- | --- | --- |
| `OrganicMeter` | ~10 lines | **Lift it.** `model_setup_screen.dart:298` already has a themed pill meter (`ClipRRect` + `LinearProgressIndicator`, `radiusPill`, `t.accentBg`). Move it into `organic/` and it is free. |
| 7-day strip | ~60 lines | A `Row` of seven `Container`s. No dependency, no `CustomPainter`. |
| `OrganicToggleRow` | ~25 lines | None exists. Wrap the `Switch` pattern from `model_setup_screen.dart:288` in `OrganicText`. |
| Numeric entry | ~4 lines | `OrganicInput` exposes no `keyboardType` and no `inputFormatters`. Shared-widget change — touch it once, carefully. |
| Log dialog | ~80 lines | Clone `_ComposeEntryDialog`. |

> **Copy the dialog pattern exactly.** `diary_panel.dart:308-320` records a real
> crash: controllers owned by the caller and disposed when the dialog future
> completed were still bound to mounted `TextField`s during the 200 ms exit fade,
> producing a `'_dependents.isEmpty': is not true` red screen. The fix — a
> `StatefulWidget` that owns its controllers and returns a plain draft object via
> `Navigator.pop(draft)` — is not optional.

**No charting dependency.** A 7-day strip, pill meters and streak dots cover a
manual tracker's needs and ship on the current `pubspec.yaml`. `fl_chart` would be
the first UI dependency in a design system hand-transcribed from a CSS handoff;
revisit only if real trend lines are wanted later.

### 4. Logging from the chat

The quick-prompt row (`_quickPromptRow`) is already a `Wrap` of tappable
`OrganicTag`s directly above the composer, already style-parameterised per shell,
already disabled while generating. Add "Log water" / "Log sleep" as
`OrganicTagVariant.accent2` tags beside the outline prompts — ~15 lines, each
opening the log dialog.

Prefer that to a leading "+" in the composer `Row`, which eats horizontal room on
the phone where the input is already narrowest.

`QuickPrompt.all` is shared with `SessionSummarizer.isSeed` so canned text is not
quoted back as the user's own words. That coupling holds for any new entries.

### 5. Copy

`MoodLabel.description` strings (`'in acute distress'`, `'low and heavy'`) go
straight into prompts and read clinically. Reword for wellness. The strapline
`'PRIVATE COMPANION & DIARY'` and the welcome screen's *"not therapy… not a crisis
service"* need revisiting — but **keep a clear not-medical-advice line**; a
wellness app that tracks sleep and movement needs it more than a journalling app
did.

---

## Sequencing

- **M0 — Foundations.** `DayKey` extracted and shared with `UsageMetrics`. v5
  migration. `WellnessLog` with logging, goals, streak/adherence maths. Tests
  only, no UI. *Ships invisibly.*
- **M1 — The digest.** `promptBlock()`, `MemoryCache` wiring (both paths,
  including the `_notesUnseen`-style rider), the budget test, and
  `WellnessLog.clear()` in the erase path. Still no UI — verify by reading the
  `assert` in `chat_view.dart:442` that prints the token split.
- **M2 — Tracker UI.** `OrganicMeter` lifted, `OrganicInput` numeric support,
  `TrackerPanel`, both shells, the log dialog.
- **M3 — Persona.** Wellness register, the coaching clause. **Gated on the
  20-turn measurement.**
- **M4 — Nudges + copy.** Tracker branches in `compose()`, `MoodLabel`
  descriptions, welcome/strapline copy.

M0 and M1 are independently shippable and carry no user-visible risk.

---

## Verification

**Automated** — `flutter analyze` clean, `flutter test` green at every milestone.
Current baseline is **248 tests**.

New tests:

- `test/day_key_test.dart` — a 23:30 local log lands on today, not tomorrow;
  correct across a UTC-offset change.
- `test/wellness_log_test.dart` — streak breaks on a missed day and survives a
  logged-but-missed-target day; adherence is hits/window; `weakestGoal()` returns
  `null` below `minDaysForAssessment`.
- `test/wellness_digest_test.dart` — never exceeds `maxDigestChars`; returns
  `null` with no goals and no logs; each line appears only under its condition;
  renders sentences, not tables.
- `test/prompt_budget_test.dart` — persona + knowledge + wellness stays under a
  new `ContextBudget.systemInstructionBudgetChars`. **Replace the hardcoded
  `3744` in `context_overflow_test.dart:43,59`** with this constructed assertion
  rather than updating the number; it goes stale on every copy edit.

**On device** (gates M3), using `D:\AndroidSDK\platform-tools\adb.exe`:

1. **Quota regression** — 20 consecutive turns with goals set and one metric
   deliberately lapsed. Fail if the companion mentions goals unprompted in more
   than a couple of them.
2. **Token split** — the `assert` at `chat_view.dart:442` prints persona and
   knowledge tokens; add a `wellness` term and confirm the total stays ≈1,150.
3. **The rider** — log a metric mid-conversation, then ask about it in the next
   message. It must know. This is the failure the `_notesUnseen` reuse prevents.
4. **Coaching quality** — set a goal, log a lapse, and check the model raises it
   *usefully* rather than reciting numbers back.
5. **Memory** — `tool/measure_memory.py`; Native Heap should be unchanged
   (~740 MB), since the model is untouched.

---

## Risks

1. **The coaching clause becomes a quota** (§7). The single most likely failure,
   with a documented precedent in the same file. Measure before merging.
2. **Nagging.** A tracker's gravity is daily reminders; this app's design notes
   repeatedly argue the other way. Keep `minimumGap = 20h`, keep one notification
   id, resist per-habit reminders in v1.
3. **Digest growth.** Every metric added is tokens taken from conversation
   history. `maxDigestChars` must be enforced by test, not by intention — the
   same discipline `maxNotesChars = 1400` already applies to diary notes.
4. **Mood has two sources now.** `mood_log` records *inferred* mood per message;
   the tracker records *self-reported* mood per day. They will disagree.
   `mood_log` has no `source` column. Decide which one the digest speaks from —
   recommendation: self-reported when present, inferred as fallback, and never
   both in the same sentence.
5. **Local-vs-UTC day keys** (§2). Silent, and only wrong for users away from
   UTC — i.e. almost everyone.
6. **`WarmCompanionShell`'s header is full.** "Open Diary" + "Sign In" + avatar
   already sit right of a `Spacer()`. A third pill fits on a tablet but crowds at
   600–700dp.
