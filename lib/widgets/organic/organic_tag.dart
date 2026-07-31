import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.tag` variants.
///
/// The three filled variants pair a `-100` background with an `-800`
/// foreground from the same ramp, which is what keeps them legible in both
/// themes without needing per-theme values.
enum OrganicTagVariant {
  /// `.tag-accent` — terracotta ramp.
  accent,

  /// `.tag-accent-2` — sage ramp.
  accent2,

  /// `.tag-neutral` — warm grey ramp.
  neutral,

  /// `.tag-outline` — hairline border, accent text, transparent fill. The one
  /// variant used as a control: the quick-prompt chips.
  outline,
}

/// A pill label drawn to the Organic system's `.tag` rules.
///
/// Tappable when [onTap] is given — the quick-prompt chips ("Deep Reflection",
/// "Stream of Consciousness", "Focus on Wonder") are outline tags that fill the
/// composer when pressed.
class OrganicTag extends StatelessWidget {
  final String label;
  final OrganicTagVariant variant;
  final VoidCallback? onTap;

  /// `.tag` is 11px; 1c's quick prompts drop to 10px.
  final double fontSize;

  const OrganicTag({
    super.key,
    required this.label,
    this.variant = OrganicTagVariant.neutral,
    this.onTap,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final (Color bg, Color fg, Color? borderColor) = switch (variant) {
      OrganicTagVariant.accent => (
          Organic.accent100,
          Organic.accent800,
          null,
        ),
      OrganicTagVariant.accent2 => (
          Organic.accent2100,
          Organic.accent2800,
          null,
        ),
      // The one place the transcription departs from the stylesheet, and only
      // under Sunlit. `.tag-neutral` fills with `--color-neutral-100`
      // (#F9F4ED), which the ramps put close to the *base* Organic background
      // (sand #F5EAD8) it was designed against. The handoff retuned the light
      // theme to off-white and left the ramps alone, so on a #F7F5EF panel the
      // fill differs by two values and the tag disappears — verified on device,
      // where "Rain / Resonance / Temple Bells" rendered as bare text with no
      // hint they were tappable. A hairline restores the affordance without
      // touching the specified fill. Dusk is unaffected and takes no border.
      OrganicTagVariant.neutral => (
          Organic.neutral100,
          Organic.neutral800,
          t.isDark ? null : Organic.neutral300,
        ),
      // The prototype overrides the stylesheet's `border-color: accent` with
      // the theme's own border, and the label with `accentText`.
      OrganicTagVariant.outline => (Colors.transparent, t.accentText, t.border),
    };

    final content = Container(
      // `.tag { padding: 3px 10px }`
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        border: borderColor == null ? null : Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(Organic.radiusPill),
      ),
      child: Text(
        label,
        style: OrganicText.tag(t, size: fontSize, color: fg),
      ),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Organic.radiusPill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        hoverColor: t.accentText.withValues(alpha: 0.10),
        highlightColor: t.accentText.withValues(alpha: 0.18),
        child: content,
      ),
    );
  }
}
