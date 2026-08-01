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

  /// Logout / destructive. The one literal in the prototype outside the ramps.
  static const danger = Color(0xFFA13A2E);

  /// The blue of a read receipt.
  ///
  /// Deliberately outside both accent ramps and the only cool colour in the
  /// Sunlit palette. That is the point: the tick has to read as *the* read
  /// signal at a glance, and people already know this colour means it. Rendered
  /// in sage or terracotta it would just look like more chrome. Desaturated
  /// from the familiar messenger blue so it sits on warm sand without shouting.
  static const tickRead = Color(0xFF4F9BC9);

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
  /// avatar, so this is the page background rather than a separate token.
  Color get onAccent => bgApp;

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

  /// Dusk — deep blue-black ground, apricot chrome.
  ///
  /// The ground is blue (hue 250) while the bubbles stay warm (the neutral
  /// ramp is hue 95). That contrast is deliberate in the prototype: the room
  /// goes cold, the conversation stays warm.
  static const dusk = SanctuaryTokens(
    bgApp: Color(0xFF0B151F), // oklch(19% 0.025 250)
    bgPanel: Color(0xFF131E2A), // oklch(23% 0.028 250)
    bgSurface: Color(0xFF192532), // oklch(26% 0.03 250)
    text: Color(0xFFE0E5EB), // oklch(92% 0.01 250)
    muted: Color(0xFF7D8792), // oklch(62% 0.02 250)
    border: Color(0xFF273442), // oklch(32% 0.03 250)
    accentBg: Organic.accent400,
    accentText: Organic.accent300,
    userBubbleBg: Organic.accent400,
    userBubbleFg: Organic.neutral900,
    assistantBubbleBg: Organic.neutral800,
    assistantBubbleFg: Organic.neutral100,
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
