import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.seg` / `.seg-opt` — a pill-shaped segmented control.
///
/// Used for the "Sunlit / Dusk" theme switch. Options are divided by a 1px
/// rule (`.seg-opt + .seg-opt { border-left: … }`) and the selected one fills.
///
/// **The selected fill is terracotta in both themes.** The stylesheet says
/// `.seg-opt:has(input:checked) { background: var(--color-accent) }` and the
/// prototype overrides only the control's border, not that fill — unlike the
/// buttons, which it explicitly repaints with the per-theme accent. So under
/// Dusk the active segment stays `#C67139` rather than becoming apricot. That
/// is what the reference renders; it is transcribed rather than corrected.
class OrganicSegmented<T> extends StatelessWidget {
  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// The prototype gives the control `width: 100%` inside drawers and sheets.
  final bool expand;

  const OrganicSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    Widget option(({T value, String label}) o, bool first) {
      final isSelected = o.value == selected;
      final child = Container(
        // `.seg-opt { padding: 7px 12px }`
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? Organic.accent : Colors.transparent,
          border: first
              ? null
              : Border(left: BorderSide(color: t.border)),
        ),
        child: Text(
          o.label,
          style: OrganicText.input(
            t,
            color: isSelected ? Organic.bg : t.text,
          ).copyWith(fontSize: 13),
        ),
      );

      final tappable = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(o.value),
          splashFactory: NoSplash.splashFactory,
          hoverColor:
              isSelected ? Colors.transparent : t.text.withValues(alpha: 0.07),
          highlightColor:
              isSelected ? Colors.transparent : t.text.withValues(alpha: 0.14),
          child: child,
        ),
      );

      return expand ? Expanded(child: tappable) : tappable;
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(Organic.radiusPill),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++)
              option(options[i], i == 0),
          ],
        ),
      ),
    );
  }
}

/// The circular "S" badge. 34px in 1a's header, 32px for a signed-in user and
/// in 1b's sidebar, 52px at the top of 1c.
///
/// Foreground is the page background (`color: {{ v.bgApp }}`), not a separate
/// token — the mark is meant to read as a hole punched in the accent.
class OrganicAvatar extends StatelessWidget {
  final String initial;
  final double size;

  /// The prototype scales the glyph independently: 52px avatar carries 20px
  /// text, 32px carries 11px.
  final double? fontSize;

  const OrganicAvatar({
    super.key,
    required this.initial,
    this.size = 34,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.accentBg, shape: BoxShape.circle),
      child: Text(
        initial.isEmpty ? 'S' : initial.characters.first.toUpperCase(),
        style: TextStyle(
          fontFamily: Organic.headingFont,
          fontWeight: FontWeight.w400,
          fontSize: fontSize ?? size * 0.41,
          height: 1.0,
          color: t.onAccent,
        ),
      ),
    );
  }
}
