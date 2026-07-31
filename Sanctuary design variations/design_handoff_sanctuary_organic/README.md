# Handoff: Sanctuary — Organic-themed UI variations

## Overview
Three interactive layout variations for the Sanctuary companion/journal app, restyled with the "Organic" design system (warm rounded shapes, Caprasimo headings, Figtree body, terracotta/sage accents), then color-tuned per feedback into an off-white + sage-green light theme and a deep blue-black dark theme.

## About the Design Files
The files in this bundle are **design references built in HTML** (a Design Component prototype) — they show intended look, layout and interaction, not production code to copy directly. The task is to **recreate these HTML designs in the target codebase's existing environment** (the app's real stack — Flutter, per the source repo, or whatever the developer's project actually uses) using its established patterns and libraries, matching this reference pixel-for-pixel for spacing, color, and type.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii and interaction states below are final — implement pixel-perfectly, not just "in the spirit of."

## Screens / Views
Three self-contained variations, each a full app shell with: header/nav, chat log, quick-prompt chips, message input, a settings panel (profile, theme switch, ambient-sound tags), a diary/journal lockbox (passcode → entries), and a sign-in dialog.

### 1a — Warm Companion (960×640)
- **Layout**: Fixed header (66px) + chat body filling the rest. Settings opens as a **left slide-in drawer** (270px wide, `transform: translateX`, 0.25s ease). Diary opens as a **right slide-in drawer** (320px wide). Both share a click-to-dismiss backdrop (`rgba(32,30,29,.35)`).
- **Header**: circular menu button (36px, 3-dot icon) → opens left drawer; 34px circular "S" avatar badge (accent bg); title "Sanctuary" (heading font, 15px) + subtitle "Private Companion & Diary" (9px, uppercase, letter-spacing .12em, muted); right side: "Open Diary" secondary button, then either a signed-in avatar circle or a "Sign In" ghost button.
- **Chat**: bubbles max-width 70%, 16px radius, 12px/16px padding, 13.5px/1.5 line-height; user bubble right-aligned in accent color, assistant bubble left-aligned in surface color.
- **Quick prompts**: 3 outline tag chips — "Deep Reflection", "Stream of Consciousness", "Focus on Wonder" — clicking fills the input with matching seed text.
- **Input bar**: pill text input + primary "Send" button, docked at bottom with a top border.
- **Left drawer**: "Sanctuary Controls" header, profile card (guest/signed-in state), "Aesthetic Palette" segmented control (Sunlit/Dusk = light/dark theme), "Environment Resonance" tag row (Rain/Resonance/Temple Bells, decorative).
- **Right drawer**: "Secure Journal Vault" header; locked state = centered card with passcode field + "Unlock Diary" button; unlocked state = 2 journal entry cards (date meta, title, snippet).
- **Sign-in dialog**: centered modal (`.dialog` pattern), name + email fields, Cancel / "Enter Sandbox Session" actions.

### 1b — Split Sanctuary (960×640)
- **Layout**: Persistent 220px left sidebar (no overlay drawers) + main content pane that swaps between three inline views based on the active nav item.
- **Sidebar**: "S" avatar + "Sanctuary" / "Diary Lockbox" label, 3 nav buttons (Companion / Diary Lockbox / Settings) — active item gets solid accent-color background + inverted text, inactive items are transparent; footer note "Sovereign Local Sandbox / Zero cloud synchronization" pinned to sidebar bottom.
- **Companion view**: identical chat/quick-prompts/input structure to 1a, just without drawer chrome.
- **Diary view**: same locked/unlocked passcode flow as 1a, laid out inline (not overlaid) with entry cards in a wrapping row.
- **Settings view**: profile card, theme segmented control, ambient-sound tags — same content as 1a's left drawer, laid out inline.
- **Sign-in**: same centered dialog pattern as 1a, triggered from the Settings view.

### 1c — Focus Bloom (420×680, phone-shaped)
- **Layout**: No header bar — centered 52px circular "S" avatar + title/subtitle at top, chat log below, then quick-prompt chips, then a rounded input row with a **circular send button** (40px, arrow glyph). A floating pill-shaped bottom tab bar (58px tall, 29px radius) with 3 text tabs: Companion / Diary / Settings.
- **Sheets**: tapping Diary or Settings raises a **bottom sheet** (76% of card height, rounded top corners 28px, `transform: translateY`, 0.28s ease) with the same locked/unlocked diary content or the same settings content as the other variants. A backdrop dims and dismisses on tap.
- **Sign-in**: centered dialog, layered above the sheets (higher z-index), same fields/actions as other variants.

## Interactions & Behavior
- **Theme toggle** (segmented control, "Sunlit"/"Dusk"): swaps every background/text/border token below; persists per-variant in local component state (not shared across the three examples).
- **Chat send**: Enter/click appends a user bubble, clears the input, then after ~700ms appends a canned assistant reply (rotates through 3 fixed strings). No real backend — mock/replace with real inference or API call.
- **Quick-prompt chips**: click sets the input field's text to a seed phrase (does not auto-send).
- **Diary unlock**: any non-empty passcode value unlocks (no real validation in this prototype — add real passcode/biometric logic in production).
- **Sign-in**: "Enter Sandbox Session" sets a mock signed-in user (name/email fields, defaults to "Sovereign Soul" / "explorer@sanctuary.private" if left blank) and closes all open panels/dialogs.
- **Drawers/sheets/backdrops**: all open/close via CSS transform transitions (translateX for drawers, translateY for bottom sheets), backdrop click closes the open panel.

## State Management
Per variant, track: `theme` ('light'|'dark'), `input` (chat draft text), `messages` (array of {role, text}), `diaryUnlocked` (bool), `passcode` (string), `signedIn` (bool), `demoName`, `demoEmail`, plus panel-open state specific to that variant's navigation pattern (1a: `leftOpen`/`rightOpen`/`signinOpen` booleans; 1b: `nav` enum + `signinOpen`; 1c: `activeSheet` enum + `signinOpen`).

## Design Tokens

### Typography
- Headings: **Caprasimo** (400 weight only)
- Body/UI: **Figtree** (400/600/700)
- Sizes used: 20px (dialog title), 15–17px (card/section titles), 13–14px (body/buttons), 11px (tags/meta), 9–10px (uppercase labels, letter-spacing .1–.12em)

### Light theme ("Sunlit")
| Token | Value |
|---|---|
| Page background | `oklch(96% 0.01 95)` |
| Panel background (header/drawers/sidebar) | `oklch(97% 0.008 95)` |
| Surface background (cards/bubbles/inputs) | `oklch(99% 0.003 95)` |
| Text | `#201e1d` (Organic `--color-text`) |
| Muted text | Organic `--color-neutral-600` (`#82796a`) |
| Border/divider | `oklch(90% 0.012 95)` |
| Accent (buttons, user bubble, active nav, accent text) | Organic `--color-accent-2-700` (`#56633f`, dark sage green) |

### Dark theme ("Dusk")
| Token | Value |
|---|---|
| Page background | `oklch(19% 0.025 250)` (deep blue-black) |
| Panel background | `oklch(23% 0.028 250)` |
| Surface background | `oklch(26% 0.03 250)` |
| Text | `oklch(92% 0.01 250)` |
| Muted text | `oklch(62% 0.02 250)` |
| Border/divider | `oklch(32% 0.03 250)` |
| Accent | Organic `--color-accent-400` (`#f6a06b`) |

### Shape / elevation (from Organic tokens — see `organic-styles.css`)
- Radii: `--radius-sm` 8px, `--radius-md` 16px, `--radius-lg` 28px (cards/dialogs use `calc(--radius-lg * 1.15)`); buttons/tags/inputs are full pill (999px)
- Shadows: `--shadow-sm/md/lg` as defined in the stylesheet
- Components used: `.btn` (`-primary`/`-secondary`/`-ghost`/`-block`), `.tag` (`-outline`/`-accent-2`/`-neutral`), `.card` (+ `-title`/`-body`/`-meta`), `.field`/`.input`, `.seg`/`.seg-opt`, `.dialog-backdrop`/`.dialog` (+ `-title`/`-body`/`-actions`)

## Assets
No external images/icons — all visual marks (menu dots, avatar initials, send arrow, close ×) are drawn with plain CSS shapes or text glyphs, no icon library dependency in the prototype (production should swap in the app's real icon set, e.g. Lucide per the Organic system guide).

## Files
- `Sanctuary Organic.dc.html` — the full prototype (all 3 variations, live interactive)
- `organic-styles.css` — the Organic design-system stylesheet (tokens + component classes) the prototype is built against
