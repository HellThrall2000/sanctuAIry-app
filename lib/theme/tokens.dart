import 'package:flutter/material.dart';

/// The Organic design system's tonal ramps and fixed values.
///
/// These live in `:root` in `organic-styles.css` and do **not** change between
/// Sunlit and Dusk — only the eight values in [SanctuaryTokens] do. Keeping
/// that split means a palette is eight colours to check, not thirty.
///
/// Source: `Sanctuary design variations/design_handoff_sanctuary_organic/`.
abstract final class Organic {
  // Base roles (`--color-*`).
  static const bg = Color(0xFFF5EAD8);
  static const surface = Color(0xFFEBDDC5);
  static const text = Color(0xFF201E1D);
  static const accent = Color(0xFFC67139); // terracotta
  static const accent2 = Color(0xFF7A8A5E); // sage

  // Neutral ramp (`--color-neutral-*`).
  static const neutral100 = Color(0xFFF9F4ED);
  static const neutral200 = Color(0xFFEEE7DB);
  static const neutral300 = Color(0xFFDCD3C4);
  static const neutral400 = Color(0xFFC0B6A5);
  static const neutral500 = Color(0xFFA19786);
  static const neutral600 = Color(0xFF82796A);
  static const neutral700 = Color(0xFF645C50);
  static const neutral800 = Color(0xFF474238);
  static const neutral900 = Color(0xFF2E2B25);

  // Accent ramp (`--color-accent-*`), terracotta.
  static const accent100 = Color(0xFFFFF2EB);
  static const accent200 = Color(0xFFFFE1D0);
  static const accent300 = Color(0xFFFFC6A5);
  static const accent400 = Color(0xFFF6A06B);
  static const accent500 = Color(0xFFD67F48);
  static const accent600 = Color(0xFFB2622D);
  static const accent700 = Color(0xFF8C491A);
  static const accent800 = Color(0xFF643312);
  static const accent900 = Color(0xFF402310);

  // Second accent ramp (`--color-accent-2-*`), sage.
  static const accent2100 = Color(0xFFF0FAE1);
  static const accent2200 = Color(0xFFE1EECC);
  static const accent2300 = Color(0xFFCCDBB2);
  static const accent2400 = Color(0xFFAEBF92);
  static const accent2500 = Color(0xFF8FA073);
  static const accent2600 = Color(0xFF728157);
  static const accent2700 = Color(0xFF56633F);
  static const accent2800 = Color(0xFF3D472B);
  static const accent2900 = Color(0xFF272E1B);

  // ── Dusk ───────────────────────────────────────────────────────────
  //
  // Dusk began as Sunlit dimmed, then went cyan-neon on near-black, then
  // indigo-and-violet. It is now blue, and the chat speaks in yellow.
  //
  // **Named by role, not by hue.** The previous set was `duskViolet`,
  // `duskPink` and so on, which meant this recolour would have been a rename
  // of every call site as well as a change of value. Two recolours was enough
  // to learn that the constant should say what a colour *does*.
  //
  // The grounds carry the accent's hue a few steps darker, which is what makes
  // a blue control look lit from within the surface rather than pasted onto
  // it, and nothing here is pure black or pure white — most of why it reads
  // soft rather than harsh.
  //
  // Kept as named constants rather than a fourth nine-step ramp: only a handful
  // of steps are ever used, and a full ramp would imply a generality that does
  // not exist.

  /// Primary — buttons, meters, active nav.
  ///
  /// Bright rather than deep, and that is forced rather than chosen: blue
  /// contributes almost nothing to luminance (0.07 of it, against green's
  /// 0.72), so **no saturated blue carries a white label at 4.5:1** — the best
  /// available is about 4.0. A bright blue with a dark label clears it
  /// comfortably instead, and [SanctuaryTokens.onAccent] picks that side on
  /// its own by measuring, so this needed no special case.
  static const duskAccent = Color(0xFF4C8DFF);

  /// The accent used as *text*, where the fill is too dark to read at 14px.
  static const duskAccentSoft = Color(0xFF8AB4FF);

  /// The user's own voice — their chat bubble.
  ///
  /// Darkish yellow, and the read receipts are the reason. Ticks are the one
  /// place this app borrows a convention wholesale: grey for delivered, blue
  /// for read, which everyone already knows. That only works if both survive
  /// on the bubble behind them, and against the previous pink they did not.
  /// Golden yellow — chosen by eye over the alternatives, and the ticks are
  /// tuned to it rather than the other way round.
  ///
  /// A deeper amber was tried because it lets both ticks be *light*, which is
  /// the half of the range a bright blue naturally lives in. It measured
  /// better and looked worse: the bubble went brown and stopped reading as
  /// the warm, spoken-aloud side of the conversation. So the bubble stays
  /// gold and [duskTick] carries the compromise instead.
  static const duskVoice = Color(0xFFDCAF44);

  /// Streaks and warmth, in the tracker.
  static const duskStreak = Color(0xFFFFC24B);

  /// Read receipt, second tick.
  ///
  /// **Measures 2.85:1 on [duskVoice], under the 3:1 an icon is supposed to
  /// hold, and that is deliberate.** The first version cleared 4.65:1 by being
  /// a deep navy, and on the device it read as a dark mark rather than a blue
  /// one — which fails the only job the tick has. Blue against gold is very
  /// nearly a complementary pair, so almost all of the separation here is
  /// hue and saturation, which the luminance ratio does not measure at all.
  /// Picked by eye at the size it actually renders, then recorded.
  static const duskTick = Color(0xFF0B5ED7);

  /// Read receipt, delivered. A true neutral rather than the bubble's own ink
  /// dimmed — a translucent ink over gold comes out brown, and the whole
  /// point of the convention is that this one reads *grey* beside the blue.
  static const duskTickPending = Color(0xFF4A4F58);

  static const duskInk = Color(0xFF0E1422); // app ground
  static const duskPanel = Color(0xFF151D30); // panels and sheets
  static const duskSurface = Color(0xFF1E283F); // cards on panels
  static const duskBorder = Color(0xFF2E3B57); // hairlines
  static const duskText = Color(0xFFEAF0FA);
  static const duskMuted = Color(0xFF8C9AB5);

  /// Blue into cyan — Dusk's one gradient, for the ring and the meters.
  ///
  /// Two stops, not three: at the width a progress bar actually renders, a
  /// third stop is invisible at best and muddies the middle at worst.
  static const duskGradient = [duskAccent, Color(0xFF45C8F0)];

  /// The glow under a primary control.
  ///
  /// Tinted with the accent rather than black, and offset almost not at all —
  /// on a dark ground a black drop shadow does nothing, so the lift has to come
  /// from light spilling out of the control instead. The negative spread keeps
  /// it tighter than the shape so it reads as a halo, not a second button.
  static const duskGlow = [
    BoxShadow(
      color: Color(0x4D4C8DFF),
      offset: Offset(0, 6),
      blurRadius: 22,
      spreadRadius: -6,
    ),
  ];

  /// Red reads as "system error" beside blue. Dusk gets a softer red that
  /// belongs to the palette while still stopping the eye.
  static const duskDanger = Color(0xFFFF6B6B);

  /// Logout / destructive. The one literal in the prototype outside the ramps.
  static const danger = Color(0xFFA13A2E);

  /// The blue of a read receipt, Sunlit.
  ///
  /// Deliberately outside both accent ramps and the only cool colour in the
  /// Sunlit palette. That is the point: the tick has to read as *the* read
  /// signal at a glance, and people already know this colour means it.
  ///
  /// **Was #4F9BC9, which was invisible.** It had been chosen to sit on the
  /// page — "warm sand without shouting" — but a tick is never drawn on the
  /// page. It is drawn inside the user's own terracotta bubble, where that
  /// blue measured 1.18:1 and the delivered tick 1.09:1, so in practice the
  /// light theme had no read receipts at all. Both are now picked against
  /// the bubble.
  static const tickRead = Color(0xFF0B3570);

  /// Delivered-but-unread, Sunlit. Dark enough to hold on terracotta, and
  /// neutral so it reads grey beside the blue.
  static const tickPending = Color(0xFF33373E);

  // --- Spacing (`--space-*`) --------------------------------------------
  //
  // A 4px grid multiplied by the system's 1.1 density, which is why these are
  // fractional. Reproduced literally rather than rounded: at 8 steps the drift
  // would be 3.2px, enough to break alignment against the reference.
  static const space1 = 4.4;
  static const space2 = 8.8;
  static const space3 = 13.2;
  static const space4 = 17.6;
  static const space6 = 26.4;
  static const space8 = 35.2;

  // --- Radii (`--radius-*`) ---------------------------------------------
  static const radiusSm = 8.0;
  static const radiusMd = 16.0;
  static const radiusLg = 28.0;

  /// Cards and dialogs: `calc(var(--radius-lg) * 1.15)` from the rounded-frame
  /// rules at the bottom of the stylesheet.
  static const radiusCard = radiusLg * 1.15; // 32.2

  /// Buttons, tags, segmented controls and inputs are full pills (`999px`).
  static const radiusPill = 999.0;

  // --- Elevation (`--shadow-*`) -----------------------------------------
  //
  // Ink-tinted rather than black: `color-mix(in srgb, #2e2b25 N%, transparent)`.
  static const shadowSm = [
    BoxShadow(color: Color(0x242E2B25), offset: Offset(0, 1), blurRadius: 2),
  ];
  static const shadowMd = [
    BoxShadow(color: Color(0x292E2B25), offset: Offset(0, 3), blurRadius: 10),
  ];
  static const shadowLg = [
    BoxShadow(color: Color(0x382E2B25), offset: Offset(0, 12), blurRadius: 32),
  ];

  /// Drawer and sheet scrim, `rgba(32,30,29,.35)`.
  static const backdrop = Color(0x59201E1D);

  /// Dialog scrim, `--color-neutral-900` at 50%.
  static const dialogBackdrop = Color(0x802E2B25);

  // --- Type ---------------------------------------------------------------
  static const headingFont = 'Caprasimo';
  static const bodyFont = 'Figtree';
}

/// The eight values that differ between Sunlit and Dusk, plus the chat-bubble
/// colours derived from them.
///
/// **Why this exists.** Before it, the app carried 65 hardcoded hex literals
/// across seven screens that had drifted into three disagreeing palettes — the
/// chat accent was neon `#00E5FF`, the journal's was slate `#A3B1BC`, and a
/// whole warm palette sat in `isDark ? … : …` false branches that could never
/// render because `themeMode` was pinned to dark.
///
/// Screens read this through `context.tokens` and never name a colour directly.
@immutable
class SanctuaryTokens extends ThemeExtension<SanctuaryTokens> {
  /// Page background.
  final Color bgApp;

  /// Header, drawers, sidebar, tab bar, bottom sheets.
  final Color bgPanel;

  /// Cards, inputs, assistant bubbles.
  final Color bgSurface;

  final Color text;
  final Color muted;
  final Color border;

  /// Filled chrome: primary buttons, active nav, avatar badges.
  final Color accentBg;

  /// Accent used as *text*: quick-prompt chips, links, card kickers. Separate
  /// from [accentBg] because Dusk lightens it for contrast on a dark ground.
  final Color accentText;

  final Color userBubbleBg;
  final Color userBubbleFg;
  final Color assistantBubbleBg;
  final Color assistantBubbleFg;

  const SanctuaryTokens({
    required this.bgApp,
    required this.bgPanel,
    required this.bgSurface,
    required this.text,
    required this.muted,
    required this.border,
    required this.accentBg,
    required this.accentText,
    required this.userBubbleBg,
    required this.userBubbleFg,
    required this.assistantBubbleBg,
    required this.assistantBubbleFg,
  });

  /// Foreground for anything sitting on [accentBg].
  ///
  /// The prototype writes `color: {{ v.bgApp }}` on every primary button and
  /// avatar, and that held while both accents were far from the page ground —
  /// Sunlit's dark sage under off-white, Dusk's bright cyan under near-black.
  /// A mid-violet is not: at 18% luminance it is *closer* to the indigo ground
  /// than to anything, so `bgApp` would put near-black on near-violet.
  ///
  /// So pick whichever of the theme's two poles the accent is furthest from.
  /// This returns exactly what the prototype specified for Sunlit, and the
  /// light label a violet button actually needs for Dusk.
  Color get onAccent =>
      _contrast(text, accentBg) >= _contrast(bgApp, accentBg) ? text : bgApp;

  /// WCAG relative contrast between two opaque colours, 1.0 to 21.0.
  ///
  /// Measured rather than approximated by comparing luminance *distance*: the
  /// two are not the same ranking, and they disagreed on exactly the colour
  /// that prompted this. Cheap enough to run per build — two luminance
  /// computations, no allocation.
  static double _contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    final hi = x > y ? x : y;
    final lo = x > y ? y : x;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Destructive actions. Derived rather than stored, so it needs no
  /// constructor, copyWith or lerp entry — the same trick as [onAccent].
  /// Sunlit's brick red disappears on indigo; Dusk gets a pink-red
  /// that belongs to the palette and still stops the eye.
  Color get danger => isDark ? Organic.duskDanger : Organic.danger;

  /// Read receipts, second tick.
  ///
  /// The one convention this app borrows outright — blue means read — so it is
  /// measured against [userBubbleBg], the only place it is ever drawn, rather
  /// than against the page.
  Color get tickRead => isDark ? Organic.duskTick : Organic.tickRead;

  /// Read receipts, delivered but unread.
  ///
  /// Both themes name this explicitly. Sunlit used to dim the bubble's own
  /// cream ink, which came out at 1.09:1 on terracotta — a tick nobody could
  /// see. Dusk cannot dim its ink either: ink over yellow comes out brown, and
  /// a brown tick beside a blue one loses the grey/blue contrast the whole
  /// convention is made of.
  Color get tickPending =>
      isDark ? Organic.duskTickPending : Organic.tickPending;

  bool get isDark => bgApp.computeLuminance() < 0.5;

  /// Sunlit — off-white ground, sage chrome.
  ///
  /// Not the sand `#f5ead8` of the base Organic system: the handoff README
  /// records that it was "color-tuned per feedback into an off-white +
  /// sage-green light theme". [Organic.bg] survives only inside chat bubbles.
  static const sunlit = SanctuaryTokens(
    bgApp: Color(0xFFF4F2EA), // oklch(96% 0.01 95)
    bgPanel: Color(0xFFF7F5EF), // oklch(97% 0.008 95)
    bgSurface: Color(0xFFFCFCF9), // oklch(99% 0.003 95)
    text: Organic.text,
    muted: Organic.neutral600,
    border: Color(0xFFE0DED5), // oklch(90% 0.012 95)
    accentBg: Organic.accent2700,
    accentText: Organic.accent2700,
    // Terracotta, not sage. The prototype and the README's token table
    // disagree here; this follows the prototype, which is what renders.
    userBubbleBg: Organic.accent,
    userBubbleFg: Organic.bg,
    assistantBubbleBg: Organic.surface,
    assistantBubbleFg: Organic.text,
  );

  /// Dusk — navy ground, blue chrome, and a yellow voice.
  ///
  /// Every ground here is the same hue as the accent, several steps darker.
  /// That is what separates this from a grey dark theme with a blue button in
  /// it: the surfaces are quietly tinted, so the accent belongs to the room.
  ///
  /// The bubble is the deliberate exception. The room is cool and the user's
  /// own voice is warm, which is the one contrast in the palette that is about
  /// meaning rather than depth — and it is what lets the read receipts keep
  /// the grey/blue convention everyone already reads without thinking.
  static const dusk = SanctuaryTokens(
    bgApp: Organic.duskInk,
    bgPanel: Organic.duskPanel,
    bgSurface: Organic.duskSurface,
    text: Organic.duskText,
    muted: Organic.duskMuted,
    border: Organic.duskBorder,
    accentBg: Organic.duskAccent,
    // Lighter than accentBg on purpose: this is used as *text* on the dark
    // ground, where the blue that reads well as a fill goes muddy at 14px.
    accentText: Organic.duskAccentSoft,
    // The user speaks in yellow, the companion in navy. Two voices that are
    // obviously different at a glance, which is most of what a chat needs.
    userBubbleBg: Organic.duskVoice,
    userBubbleFg: Organic.duskInk,
    assistantBubbleBg: Color(0xFF202B44),
    assistantBubbleFg: Organic.duskText,
  );

  @override
  SanctuaryTokens copyWith({
    Color? bgApp,
    Color? bgPanel,
    Color? bgSurface,
    Color? text,
    Color? muted,
    Color? border,
    Color? accentBg,
    Color? accentText,
    Color? userBubbleBg,
    Color? userBubbleFg,
    Color? assistantBubbleBg,
    Color? assistantBubbleFg,
  }) {
    return SanctuaryTokens(
      bgApp: bgApp ?? this.bgApp,
      bgPanel: bgPanel ?? this.bgPanel,
      bgSurface: bgSurface ?? this.bgSurface,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      border: border ?? this.border,
      accentBg: accentBg ?? this.accentBg,
      accentText: accentText ?? this.accentText,
      userBubbleBg: userBubbleBg ?? this.userBubbleBg,
      userBubbleFg: userBubbleFg ?? this.userBubbleFg,
      assistantBubbleBg: assistantBubbleBg ?? this.assistantBubbleBg,
      assistantBubbleFg: assistantBubbleFg ?? this.assistantBubbleFg,
    );
  }

  @override
  SanctuaryTokens lerp(covariant SanctuaryTokens? other, double t) {
    if (other == null) return this;
    return SanctuaryTokens(
      bgApp: Color.lerp(bgApp, other.bgApp, t)!,
      bgPanel: Color.lerp(bgPanel, other.bgPanel, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      accentBg: Color.lerp(accentBg, other.accentBg, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      userBubbleBg: Color.lerp(userBubbleBg, other.userBubbleBg, t)!,
      userBubbleFg: Color.lerp(userBubbleFg, other.userBubbleFg, t)!,
      assistantBubbleBg:
          Color.lerp(assistantBubbleBg, other.assistantBubbleBg, t)!,
      assistantBubbleFg:
          Color.lerp(assistantBubbleFg, other.assistantBubbleFg, t)!,
    );
  }
}

/// `context.tokens` instead of `Theme.of(context).extension<SanctuaryTokens>()!`.
///
/// Falls back to [SanctuaryTokens.sunlit] rather than throwing, so a widget
/// built outside the app's theme (a test harness, a widget preview) renders
/// instead of crashing.
extension SanctuaryTokensX on BuildContext {
  SanctuaryTokens get tokens =>
      Theme.of(this).extension<SanctuaryTokens>() ?? SanctuaryTokens.sunlit;
}
