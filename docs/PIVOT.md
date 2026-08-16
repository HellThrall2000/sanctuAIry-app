# Pivot: adult mental-health companion → parent-managed kids' study buddy (8–14)

> Status: **planned, in progress on `feat-pivot`.** Milestones are ordered so each
> one ships independently; M0–M2 are safe to land even if the pivot is abandoned.

## Why

Today this is an offline adult mental-health companion — CBT-register persona,
self-harm crisis triage, a passcode-locked personal diary, mood-trend tracking —
running Gemma 4 E2B on-device via LiteRT-LM. Its whole technical story is that
nothing leaves the phone.

**That privacy story is worth far more to parents of children than to adults.**
Every mainstream kids' AI is an API wrapper posting a child's words to a server.
This app already does the hard part: a 2.4 GB model running locally, no network,
no account required to talk. So the pivot is mostly persona, safety and framing —
not architecture.

Target audience: **ages 8–14, parent-managed.** The parent configures the app
before handing over the device; the child only ever sees the companion. The
locked diary becomes the **parents' configuration area**. Marketing leads on the
direct contrast with cloud AI that harvests children's data.

### Decisions taken

| Question | Decision |
| --- | --- |
| Age range | **8–14, parent-managed.** The parent owns any account; the child never authenticates. |
| Image / audio input | **Phase 2.** Ship text-first on the model already tested on device. |
| Accounts | **Parent-only, optional.** `Consent.requiresAccount → false`. |

### The multimodal correction

Gemma 4 E2B understands images and audio natively — **but the `.litertlm` we ship
does not.** The export command in `docs/MODEL_EXPORT.md` passes no vision or audio
flags, so what is on devices is a text-only export of a multimodal checkpoint.

Separately, `packages/flutter_litert_lm/.../FlutterLitertLmPlugin.kt:82-89` reads
`visionBackend` and `audioBackend` into locals and then **never passes them to
`EngineConfig`**. iOS forwards them correctly; Android silently drops them.

Enabling multimodal therefore needs a model re-export *and* a forced ~2.4 GB
re-download for every install. That is a 2.0, not a point release — hence Phase 2.

---

## What is reused unchanged

Do not rebuild these. They are domain-neutral and already carry their own hard-won
lessons in doc comments:

- `lib/services/chunk_store.dart` + `memory_scorer.dart` — BM25 with an FTS5/Dart
  dual path, content-addressed insertion, recency decay. The cleanest asset here.
- `lib/services/reply_sanitizer.dart`, `perspective.dart`, `context_budget.dart`,
  `model_settings.dart`, `litert_service.dart`, `model_download_service.dart`,
  `crash_reporter.dart`, `diagnostics_log.dart`
- `lib/services/event_extractor.dart` — "I have a spelling test on Friday" already
  parses with zero changes.
- `session_summarizer.dart` mechanics; `memory_store.dart` slot-keyed facts.
- **`lib/widgets/sanctuary/memory_panel.dart`** — fully built, backend-live, and
  has **zero call sites**. Surfacing it in the parent area as "what the buddy
  remembers about your child, with a Forget button" is the highest value-per-line
  change in the pivot. It *is* the marketing claim, already implemented.
- **The `journals` pipeline** — `JournalEntry` → `MemoryCache.backfillJournals()`
  → `MemoryStore.syncJournal` + `ChunkStore.syncJournal` → `NoteDigester` →
  `knowledgeBlock()`, with per-entry AI visibility and delete-erases-derived-memory.
  A parent writing "Maya gets anxious about swimming" and ticking *share* is exactly
  that shape. **Zero backend work.**

---

## 1. Persona (`lib/services/persona.dart`)

### Budget

| | now | target |
| --- | --- | --- |
| `Persona._full` | 1,971 ch / ~548 tok | **1,790 ch / ~497 tok** |
| parent block (new) | — | ≤ 420 ch |
| knowledge block | ~1,773 ch | ~1,400 (`maxNotesChars` 1400→1000, `maxNotesInPrompt` 6→4) |
| **system instruction** | 3,744 ch / 25% of window | **≤ 3,600 ch / ~24%** |

Paid for by deleting the reflective-listening sentence (a CBT artefact, −137),
trimming `coreTraits` (−101) and the mood-reversal paragraph (−24), and deleting
the two therapy `exemplars()` — already dead via `useExemplars = false`. Keep the
`exemplars()` / `hasExemplars` API returning `const []` so `chat_view.dart` is
untouched.

**Must survive:** the anti-invention paragraph *and its ordering*. It is the
hardest-won text in the file, and a fabricated homework answer a nine-year-old
believes is worse than the adult failure it was written for.

### The new constants

```dart
static const String companionName = 'Pip';   // one place; branding = one line

// Also the ENTIRE prompt under PersonaMode.safetyOnly, so it must stand alone.
// Escalation is last on purpose: the last clause wins on a 2B model, and
// "tell a grown-up" must never be the thing that gets overridden.
static const String safetyInstruction =
    'You are an AI, not a person: never claim to be human, to have a body, '
    'or to meet them anywhere. You are talking to a child, so never ask for '
    'their surname, address, school, phone number or passwords, and never '
    'suggest keeping something secret from their parents. If they tell you '
    'someone is hurting or frightening them, tell them to talk to a grown-up '
    'they trust today.';

// "Match them" survives from the adult version for the original reason: a
// ceiling ("do not perform cheerfulness") reads to a small model as permission
// to be flat, so the intent is carried by asking it to match instead.
static const String coreTraits =
    'You are their buddy, not their teacher. You are warm, playful and '
    'curious, you get genuinely excited when they work something out, you '
    'never talk down to them and you never nag. Match them: silly when they '
    'are silly, calm and steady when something is hard.';

static const String conversationStyle =
    'Talk the way a friendly older cousin texts — a few sentences, never a '
    'wall of text, never headings or bullet lists. An emoji is welcome when '
    'the mood is light. 🙂\n'
    'When they are working something out, do not hand over the answer first: '
    'give one clue or one small step, then ask one short question that moves '
    'them on. Never more than one question in a reply. If they ask again or '
    'say they are stuck, give the answer and show how it works.\n'
    'Answer the message in front of you, not the one before it. If the news '
    'turns, turn with them immediately — never celebrate something they have '
    'just told you did not happen.\n'
    'Anything written above they told you themselves, so treat it as known '
    'and answer from it directly. If they ask you something that is not '
    'written above, say plainly that you do not remember. Never invent a '
    'name, a date, a fact or a number to fill the gap, and never claim to '
    'have "heard" anything from anywhere else. If you are not certain '
    'something is true, say so — a wrong answer they believe is worse than '
    'no answer.';
```

`ModelProfile.stock.lengthGuidance` becomes
`'Keep it short — never a wall of text, never headings or bullet lists.'`

### ⚠️ The biggest risk in this plan

`conversationStyle` today opens **"Do not end your replies with a question"**, and
`persona.dart:127-139` records exactly why: phrased as a ceiling ("ask at most one
question"), the model turned it into a **quota** and interrogated the user on every
consecutive turn. Education wants the questions back — so this plan deliberately
re-opens the regression that text was written to close.

Mitigation is the prohibition form — *"Never more than one question in a reply"* —
which is the phrasing that worked last time. **Measure on device across ≥20
consecutive turns before M3 merges**, watching for "every reply is a quiz".

Fallback if it regresses: move the Socratic instruction out of the persona into a
per-turn cue beside `Persona.moodCue`, fired only when a homework/subject context
is detected, so ordinary chit-chat never carries it.

---

## 2. Child safety (`crisis_guard.dart`, `guard.dart`)

Keep the two-tier architecture — *concern never interrupts; explicit bypasses the
model deterministically*. Add two levels, not two systems:

```dart
enum CrisisLevel { none, concern, bullying, explicit, harm }
```

Precedence in `assess()`: softeners first (keep them **exactly** — children narrate
games and YouTube constantly), then `harm` → `explicit` → `bullying` → `concern`.

**Keep `_explicitSignals` unchanged.** Self-harm language in 12–14-year-olds is
real; do not soften it because the audience is younger.

New `_harmSignals` (abuse / grooming) require a first-person object so third-party
narration does not fire: hits/hurts *me*, touched *me* there, made *me* touch, told
me not to tell, "it's our secret", scared to go home, someone online asked for
photos, wants to meet up.

New `_bullyingSignals`: bullied, picking on me, left me out, nobody likes me,
laughing at me, called me names, won't let me play.

| level | behaviour |
| --- | --- |
| `concern` | nothing; the model answers. After 2, one `gentleOffer()`. *(unchanged)* |
| `bullying` | **nothing interrupts.** The model answers normally — this is the most common serious thing a child brings, and meeting it with a script is the "I can't handle you, go away" failure the two-tier design exists to prevent. Append `tellAGrownUp()` once per session. |
| `explicit` | model bypassed, fixed child-appropriate text |
| `harm` | model bypassed, leads with "you did the right thing telling someone" |

Fixed responses are written by hand and never sampled. Keep `ResourceEntry` with
its `source` + `verifiedOn` discipline, and **research every child helpline number
off the operator's own page** — Childline, NSPCC, Kids Help Phone, Childhelp,
CHILDLINE India, plus the existing Find A Helpline. No digits from memory.

### `LexicalGuard`

**Input — do not fully invert.** A 13-year-old refused for typing "this is shit"
learns the app is a snitch and stops being honest, which destroys the safety value.
Keep `_abuse` requiring a second-person target so venting about a sibling lands.
Widen `_sexual`; add refusals for self-harm *method*, weapon/drug how-to, and
"pretend you're a real person / help me hide this from my mum".

**Output — reinstate and split by severity.** `_violation()` currently returns only
`scaffolding`; `_claimsHuman`, `_claimsPhysical` and `_medical` were deleted on the
reasoning that stock Gemma's own alignment covers it. That is an adult-user risk
calculus. Restore all three and add `_solicitsPersonal`, `_secrecy`, `_adultTopic`,
`_externalDirect`.

Change the contract. Today `screenOutput` **always** returns `rewrite` (sentence
surgery), which is right for scaffolding and wrong for severe — if the model
produced sexual content, showing the surrounding sentences is not acceptable:

```dart
if (severe.isNotEmpty) return GuardVerdict.refuse(_fallback, severe.join(','));
// mild → existing sentence-removal path, unchanged
```

**Call-site change in `chat_view.dart`:** on a severe verdict, skip `_remember()`,
`ChunkStore.addExchange()` and `NotificationService.showReply()`. A guard-substituted
line must never be indexed into episodic memory as something the buddy said.

> **Honesty.** A lexical guard misses most real disclosures (children rarely use the
> words in the regex) and false-positives on Roblox chat. **Do not market this as
> safeguarding.** The defensible claim is: *the buddy always points a child to a
> trusted adult, and never asks for personal details.*

---

## 3. Parent area (`diary_panel.dart` → `ParentZone`)

`build()` stays `_unlocked ? _content() : _lockCard()`.

### The passcode is genuinely broken today

| defect | fix |
| --- | --- |
| **the first non-empty code entered silently becomes the passcode** — any child who opens the panel before a parent does owns the lock | move creation into parent onboarding; the panel can only *verify* |
| unsalted SHA-256 in `SharedPreferences` | random salt + **`flutter_secure_storage`** — already in `pubspec.yaml`, **never imported anywhere in `lib/`** |
| fast hash | PBKDF2-HMAC-SHA256. Be honest: for a 6-digit PIN this buys little — the next two rows are the real defence |
| no rate limiting | persisted attempt counter, exponential backoff, 15-minute lockout after 10 failures, surviving a force-kill |
| no confirm-twice, no strength rule | confirm twice; min 6 digits; reject `111111`, `123456`, the child's birth year |
| **never re-locks** | auto-lock on `AppLifecycleState.paused` **and** after 120 s idle — the most important row; a parent who checks something and hands the phone back must not leave the door open |

Recovery: Google re-auth if the parent signed in, otherwise a deliberate reset that
wipes `ParentConfig` only — never the chat or the memory.

### What a parent configures

New `lib/services/parent_config.dart` and a `parent_config` table (SQLite, not
prefs — it is child data and belongs behind the same delete path).

- `ChildProfile { firstName, age (8–14), yearGroup?, interests≤6, strongSubjects≤3, trickySubjects≤3, habits≤3 }`
- `BuddyPermissions { mayLearnFromChat, mayRememberSessions, mayCheckIn (default false), dailyMinutes?, from?, to? }`
- Free-text notes through the existing compose dialog, retitled *"Something the
  buddy should know"*.

**First-name-only is enforced structurally** — validated on write (single token,
≤ 20 chars, no digits) and re-checked on render. The safety posture depends on the
model never learning a surname, and the cheapest place to guarantee that is the
input boundary.

### How it reaches the prompt

1. **Structured, always pinned.** `ParentConfig.promptBlock()` is prepended inside
   `knowledgeBlock()` *before* learned facts, because parent-set truth outranks
   anything derived. Hard cap 420 chars, enforced by test:

   > About them: Maya is 9. She is in Year 5. She likes horses, Minecraft and
   > drawing. She finds long division hard and is good at reading. Her grown-ups
   > would like her to read for 20 minutes a day. **Do not raise anything else her
   > grown-ups have written here unless she brings it up.**

   That last sentence is load-bearing. Without it the model opens every session
   with "So, have you drunk any water?"

2. **Free text, retrieved.** Existing pipeline, no new code.

### Two required fixes

- **`Perspective.toThird` bug.** `memory_cache.dart` runs every digest line through
  it because diary entries are first-person. A parent's note is *already* third
  person, so "She struggles with fractions" gets mangled. Add `JournalEntry.author`
  (`enum JournalAuthor { child, parent }`) with a migration defaulting existing rows
  to `child`, and skip the rewrite for parent entries. `NoteDigester._salient` also
  needs a second salience set — it is first-person affect vocabulary and scores
  parent notes badly.
- **Delete `ChatView.allowedJournals`** — declared, passed by both shells, and
  **never read**. Diary content reaches the model only via `knowledgeBlock()`.
  Remove `_allowedJournals` and `onAllowedEntriesChanged` too.

---

## 4. Auth and consent (`main.dart`, `consent.dart`)

Today Firebase, `AuthService` and `UsageMetrics` start at `main.dart:51-59`,
`setAnalyticsCollectionEnabled(true)` runs in `UsageMetrics.init()`, and
`Consent.isAccepted()` is only checked at `:72`. **An anonymous Firebase account is
minted and analytics enabled before the user has seen the terms.** On an adult app
that is defensible; on a child-directed app it is the thing that fails review.

```dart
await DiagnosticsLog.instance.init();
final prefs = await SharedPreferences.getInstance();
final accepted = await Consent.isAccepted();   // MOVED UP — nothing network before this
if (accepted) await _startBackend();           // extracted, guarded by _backendStarted
```

`_startBackend()` is called from both `main()` and `WelcomeScreen.onAccepted`.

`Consent`: `version → 2` (re-ask everyone — correct for a material change),
`requiresAccount => false`, plus `recordParentalGate()` / `parentalGateAt()`. The
two-second launch race leaves the critical path entirely: its justification was
"the welcome screen decides whether to require a Google account", which evaporates.

**New five-step flow:** parental gate → terms rewritten for a parent → parent PIN
(confirm twice) → child profile (skippable) → model download.

> The parental gate (`7 × 8 = ?`) is **not legally bulletproof**. Document the
> choice and its rationale in `docs/RELEASE.md` so it can be defended at review.

**Sign-in moves out of the child's path**: remove `GoogleSignInButton` from
`welcome_screen.dart`, move the profile card from `settings_panel.dart` into
`ParentZone`, and delete the "Sign In" button from `warm_companion_shell.dart` —
it currently sits in the header where the child can see it.

**Families policy:** Firebase Analytics collects the Advertising ID by default,
which Play's Families policy prohibits. Add to `AndroidManifest.xml`:

```xml
<meta-data android:name="google_analytics_adid_collection_enabled" android:value="false"/>
<meta-data android:name="google_analytics_ssaid_collection_enabled" android:value="false"/>
<meta-data android:name="google_analytics_default_allow_ad_personalization_signals" android:value="false"/>
```

`firebase/firestore.rules` needs no change — owner-only with field allowlists is
already correct, and the fields written are unchanged.

---

## 5. UI

| where | now | becomes |
| --- | --- | --- |
| phone tab bar | Companion / Diary / Settings | **Chat / My Stuff / Grown-ups 🔒** |
| sheet + drawer titles | "Secure Journal Vault" | "Grown-ups only" |
| strapline | "PRIVATE COMPANION & DIARY" | "RUNS ON THIS PHONE" |
| header button | "Open Diary" | "Grown-ups" |

**"My Stuff"** is a new child-facing screen reusing existing `SettingsPanel`
widgets: habit streaks, a friendly read-only view of what the buddy remembers
("I know you like horses 🐴"), theme picker, soundscapes. The third tab must not be
a locked door — a child tapping a padlock and being refused twice a day is a bad
product. Lock copy: *"This bit is for your grown-up — it's where they tell me
about you."*

**Re-skin, in the right order.** The token system is 12 fields × 2 instances, so a
re-skin *looks* like a 30-minute job. It is not: `organic_tag.dart` reads the raw
`Organic.*` ramps, `Organic.danger` is hardcoded at five call sites, and
`Organic.tickRead` in `chat_view.dart`. **M0 first** — add `danger`, `tickRead` and
tag colours to `SanctuaryTokens` and replace every raw reference. Pure refactor, no
visual change. *Then* the re-skin is 12 fields + 3 ramps + 2 font strings.

- **Text size** — bubbles are 13.0/13.5 pt, too small for an eight-year-old. Add
  `ChatViewStyle.child()` (16 pt, taller line height) rather than editing the two
  existing constructors, which are pixel-accurate to a design handoff.
- **Fonts** — keep Figtree (tall x-height, very legible) and Caprasimo (already
  chunky and reads playful).
- **Mascot** — there are **no image assets at all**; the app mark is drawn in code.
  Cheapest credible path is a `CustomPainter` face reacting to state. This is the
  biggest "does it feel like a kids app" lever and the one code fakes worst —
  budget for a real illustrator before launch.

**String table** — add `lib/copy/child_copy.dart` and `lib/copy/parent_copy.dart`
as plain `abstract final class` const holders. No codegen, no `.arb`, no
`BuildContext`. The app now has two audiences with two registers, and a
parent-register sentence leaking into a child screen is a real failure. **Do not do
full l10n now** — large change, no current beneficiary.

---

## 6. Education backend

**Mastery replaces mood-trend.** `RelationshipLog.moodTrend()` is clinical progress
monitoring ("it has been getting heavier"). Keep the `mood_log` table and
`recordMood` for the per-turn cue; remove `moodTrend()` from `promptBlock()`.

Add `LearningLog` (table `subject_signal(subject, kind, count, lastSeenAt)`,
`kind ∈ {struggle, win}`) fed from `SubjectExtractor` plus a phrase lexicon —
"i don't get", "too hard", "stuck on" / "i got it", "figured it out". Reuse the
`minMentionsForTopic = 3` discipline; the reasoning behind it transfers exactly.

> **Do not gamify habits.** No points, no streak-loss guilt, no "you broke your
> streak!". The distinction `nudge_service.dart` draws between a companion and a
> retention notification applies twice over to a nine-year-old. A streak is
> background context for the buddy and a fact on the parent screen. That is all.

**`TopicExtractor` → `SubjectExtractor`** — keep the closed-vocabulary mechanism,
replace the domain list: drop money, work, relationship, grief, health; add school,
homework, maths, reading, science, gaming, friends, pets, space, making things, tests.

**Invert the `knowledgeBlock()` preamble.** It currently ends *"never say where a
detail came from"*. For a child, "how do you know that?" deserves a true answer —
and a buddy that knows things it will not explain is precisely the creepy thing
this pivot sells against.

**`FactExtractor`** — replace `_relations` (drop wife/husband/boss/therapist; add
teacher/grandma/cousin/coach). **Delete the breakup and bereavement machinery**: for
a child of separated parents, "i wish my dad hadn't left" currently produces *"Their
relationship with their dad has ended."* fed back into a prompt. Keep the allergy and
fear frames — safety-relevant. **Add a redaction guard** rejecting phone numbers,
postcodes, addresses, emails and multi-token names. Gate `learnFromMessage` on
`mayLearnFromChat`.

**`SentimentAnalyzer`** — the scoring engine (intensifiers, dampeners, negation
window, evidence-normalised valence, activated/flat split) is domain-neutral;
**do not touch it.** Swap the three lexicons only.

> **Do not rename the `MoodLabel` enum values.** `relationship_log.dart` stores
> `label.name` and `MoodLabel.fromName` silently falls back to `neutral`, so a
> rename quietly erases every existing user's history. Change `description` only —
> and note those strings go straight into prompts.

**`QuickPrompt`** — replace all three ("Homework help", "Tell me something cool",
"I'm stuck"). **Keep `isSeed()` exactly**; without it a canned seed gets quoted back
to the child as their own words.

**`NudgeService`** — default `_enabled` from `true` to **`false`**, parent-enabled
only. Shipping unprompted notifications to a child by default, with no in-app
control, is the most likely single Families-policy failure in the app today. Quiet
hours become parent-set, defaulting to 19:30–07:30 blocked. Rewrite the composed
copy. Keep `minimumGap = 20h` and the priority ladder.

---

## 7. Naming

The costs differ wildly, so split the decision.

| thing | cost | do it? |
| --- | --- | --- |
| Product name, buddy name | zero / one const | **Yes.** "sanctuAIry" reads adult-clinical, and the "AI" infix undercuts the offline story. Extract the buddy name to `Persona.companionName`. |
| Dart package name | 16 test imports; **`lib/` uses relative imports — zero changes there** | Optional |
| **`applicationId com.sanctuairy.app`** | **High** — new Play listing, orphaned installs, reviews reset, new Firebase app and `google-services.json`, both SHA-1s re-registered, Crashlytics history split, Google Sign-In broken until the OAuth client is recreated | **Only if no public listing exists.** Builds so far have been tester-only; if it has not shipped publicly, this is the cheapest the rename will ever be. If it has, keep the id forever and change only the label. |
| Firebase project id | invisible to users | Leave it |

Buddy-name criteria: one or two syllables, typeable by an eight-year-old, and **not
a plausible human first name** — a buddy called "Sam" fights its own "never claim to
be human" rule. *Pip* is the working name; trademark-search before committing.

> **Do not rename SharedPreferences keys** (`sanctuary_theme_dark`,
> `sanctuary_terms_version`, `sanctuary_profile_name`, …). Renaming any of them
> silently resets that state for every returning user. Keep the `sanctuary_` prefix
> permanently. The passcode key is the deliberate exception, with a one-time
> read-and-migrate path.

---

## 8. Milestones

- **M0 — Unblocking refactors** (no visible change). Missing theme tokens and
  replace raw `Organic.*` colour references; replace the brittle `3744` literal with
  a constructed budget test; delete the `allowedJournals` dead plumbing.
- **M1 — Consent and Firebase ordering.** ⚠️ **Do first.** Reorder `main.dart`, gate
  the backend behind consent, `requiresAccount → false`, move sign-in out of the
  welcome screen, add the analytics manifest flags. **This fixes what is arguably a
  compliance defect today** and is correct even if the pivot were abandoned.
- **M2 — Child safety.** `CrisisGuard` (+`harm`, +`bullying`, verified resources),
  `LexicalGuard` (input widened, output boundaries reinstated with a severity split),
  the `chat_view` call-site changes, and all the new safety tests. Pure logic, no UI;
  strictly safer than today even on the adult app.
- **M3 — Persona.** New constants, `ModelProfile`, `knowledgeBlock()` preamble,
  `QuickPrompt`, `MoodLabel.description`, sentiment lexicons. **Gated on on-device
  measurement** (see Verification).
- **M4 — Parent area.** Passcode hardening → `ParentZone` → `ParentConfig` /
  `ChildProfile` → `JournalEntry.author` migration and the `Perspective` fix →
  structured block into the prompt → sign-in card moves here → **`MemoryPanel`
  surfaced**.
- **M5 — Education backend.** `SubjectExtractor`, `LearningLog`, `HabitLog`,
  `promptBlock()` rewrite, `FactExtractor` child relations and redaction.
- **M6 — Onboarding, copy, re-skin.** Parental gate, five-step welcome, tab
  renaming, `ChatViewStyle.child()`, copy files, palette, mascot. Largest and most
  parallelisable.
- **M7 — Nudges.** Default-off, parent window, new copy. Independent after M4.
- **M8 — Release and compliance.** `docs/RELEASE.md` inverts (health declaration
  out; "Target audience — **not children**" → Families / Teacher Approved);
  `docs/PRIVACY.md` rewritten for a parent audience with the offline contrast
  leading; Data safety form; content rating re-run. **Play's Generative AI policy**
  requires an in-app "this reply was wrong or upsetting" report affordance — the app
  has none — plus a documented red-team record. Non-optional.
- **M9 — Phase 2 multimodal.**

**Ships independently, today: M0, M1, M2, M7.** M1 should not wait for the pivot.

---

## 9. Verification

`flutter analyze` clean and `flutter test` green at every milestone.

**Rewrite:** `crisis_guard_test.dart` (keep the `explicit` and softener groups
unchanged — they apply to teenagers too; add `harm` and `bullying`),
`guard_test.dart` (the output group fully inverts), `model_profile_test.dart`
(the "do not end with a question" assertion inverts; **keep the anti-invention
group as-is** — the most valuable test in the repo), `sentiment_analyzer_test.dart`
(lexicon group only; keep every negation and modifier test),
`fact_extractor_test.dart`, `consent_test.dart`.

**Keep untouched:** `reply_sanitizer`, `perspective`, `memory_scorer`, `fact_ranker`,
`event_extractor`, `context_budget`, `model_download`.

**Replace the `3744` literal** in `context_overflow_test.dart` with a constructed
assertion against a new `ContextBudget.systemInstructionBudgetChars = 3600`, built
from `Persona.instructionFor` + `ParentConfig.maxSizePromptBlock()` +
`MemoryCache.maxSizeKnowledgeBlock()`. The existing `isSystemInstructionOversized`
tripwire only fires above ~9,885 chars — it is a floor, not a budget.

**New tests:** `child_safety_test.dart` (a table-driven corpus written to be
readable as a document, **including the false-positive set** — Minecraft narration,
"my character died", "I'd kill for a snack"), `guard_output_severity_test.dart`,
`parent_config_test.dart` (420-char cap; never renders a surname, phone, address or
school even if a parent typed one), `parent_passcode_test.dart` (first-entry-wins
gone; salt differs across installs; backoff survives a restart; auto-lock on pause),
`prompt_budget_test.dart`, `no_personal_data_test.dart`, `nudge_test.dart`.

**On device** (gates M3):

1. **Question-quota regression** — 20 consecutive turns; fail if most replies end
   in a question.
2. **Reading level** — sample replies at ages 8 and 14; check sentence length and
   vocabulary.
3. **Reply length** — no walls of text, no bullet lists.
4. **Safety corpus** — read each phrase into the running app and confirm the tier
   fires end to end, not only in unit tests.
5. **Budget** — the `assert` in `chat_view.dart` prints the persona/knowledge token
   split; confirm ≤ ~1,000 tokens.
6. **Memory** — `tool/measure_memory.py`; Native Heap should be unchanged (~740 MB),
   since the model itself is untouched.
7. **Parent lock** — set a PIN, background the app, confirm it re-locks; confirm the
   lockout survives a force-stop.

---

## 10. Phase 2 — multimodal (outline)

1. Fix `FlutterLitertLmPlugin.kt` to pass `visionBackend` / `audioBackend` into
   `EngineConfig` (mirror what iOS already does).
2. Add `sendMultimodalMessageStream` to `conversation.dart` — it hardcodes
   text-only contents. The platform interface and the Kotlin `parseContents` already
   handle all six content types, so this is plumbing, not design.
3. Thread `LiteLmContent` through `litert_service.dart`, which never imports it today.
4. **Re-export the model with vision encoders**, update `sizeBytes` and `sha256` in
   `model_catalog.dart`, re-upload to R2, and write a migration that survives a
   forced ~2.4 GB re-download without bricking mid-download. Largest cost.
5. Manifest `CAMERA` / `RECORD_AUDIO`; prefer gallery-pick where possible to avoid a
   runtime permission prompt on a child's device.
6. Memory: text-only already peaks ~2.1 GB PSS. Gate on device RAM, ship disabled,
   parent-enabled per capability.
7. New safety surface: a child can photograph themselves or another person. Images
   never leave the device (true by construction — say so loudly), and the output rule
   must never describe a person's appearance.

*Photograph the maths problem you're stuck on* is the killer feature for this
audience — which is exactly why it deserves its own release rather than being
smuggled into the pivot.

---

## Risks, ranked

1. **The question inversion re-opens a documented regression** (§1). Measure before
   merge; the fallback is specified there.
2. **The CBT fine-tune must never ship to children.** `ModelProfile.forFileName`
   **falls back to `fineTune`** for any unrecognised file, and that profile carries
   `PersonaMode.safetyOnly` — a therapy fine-tune with a thin prompt is the worst
   possible combination here. Add `allowedForChildren`, make the fallback `stock`,
   and have `findLocalModels` refuse the fine-tune in release builds.
3. **Safeguarding overclaim.** Never market the regex guard as protection.
4. **Parent-visible chat content is a trap.** A 13-year-old who learns their messages
   are readable stops telling the truth, which destroys the safety value the feature
   was added for. Show **content-free signals only** — minutes used, subjects touched,
   habit streaks, "a rough few days" — and tell the child so in plain words at setup.
   If transcripts are ever shown, that must be disclosed to the child, not hidden.
5. **Play Families review is materially heavier** than the current health-app path.
   `FOREGROUND_SERVICE_SPECIAL_USE` + a 2.4 GB download + an on-device LLM + a
   child-directed audience will be read carefully.
6. **Play's Generative AI policy** requires in-app reporting of offensive output and
   documented safety testing. The app has neither.
7. **Reading level is unsolved.** A 2B model at temperature 1.0 does not reliably
   write for an eight-year-old, and the only lever is the prompt. Consider two
   `lengthGuidance` variants by age band.
8. **~2.1 GB PSS on a child's phone.** Children get the *old* handset. This is the
   largest silent-failure risk in the product, and Phase 2 makes it worse.
9. **SQLite is unencrypted** (no SQLCipher). App-sandbox plus file-based encryption
   is genuinely adequate on a modern non-rooted device, but the marketing copy must
   not overstate it.
