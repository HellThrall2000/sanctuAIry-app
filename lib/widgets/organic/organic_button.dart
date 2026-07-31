import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.btn` variants from `organic-styles.css`.
enum OrganicButtonVariant {
  /// `.btn-primary` — filled with the theme's accent.
  primary,

  /// `.btn-secondary` — transparent with a hairline border.
  secondary,

  /// `.btn-ghost` — accent-coloured text, no border, tighter side padding.
  ghost,
}

/// A button drawn to the Organic system's `.btn` rules.
///
/// Built on [TextButton] rather than a bare [GestureDetector] so focus
/// traversal, disabled semantics and screen-reader roles come for free, with
/// the ripple removed — the reference is a CSS prototype whose feedback is an
/// instant background swap, not a Material ink spread.
///
/// The label renders in the **heading** face. That is the system's one real
/// surprise: `.btn` sets `font-family: var(--font-heading)`, so every button is
/// Caprasimo while every input beside it is Figtree.
class OrganicButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final OrganicButtonVariant variant;

  /// `.btn-block` — fills the width and takes a `--space-2` top margin.
  final bool block;

  /// Overrides the 14px `.btn` size. The prototype drops several buttons to
  /// 10–11px in drawers and headers.
  final double fontSize;

  /// Overrides the label colour. Used for the destructive "Logout Session"
  /// button, which is a `.btn-secondary` with `color: #a13a2e`.
  final Color? foreground;

  final IconData? icon;

  const OrganicButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = OrganicButtonVariant.primary,
    this.block = false,
    this.fontSize = 14,
    this.foreground,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final (Color bg, Color fg, Color? borderColor) = switch (variant) {
      OrganicButtonVariant.primary => (t.accentBg, t.onAccent, null),
      OrganicButtonVariant.secondary => (Colors.transparent, t.text, t.border),
      OrganicButtonVariant.ghost => (Colors.transparent, t.accentText, null),
    };
    final label = foreground ?? fg;

    // `:hover` / `:active` from the stylesheet. The primary rules there step
    // along the terracotta ramp (`--color-accent-600/700`), which would turn a
    // sage button orange under the thumb, so the press state darkens whatever
    // accent the theme actually uses instead.
    final pressed = switch (variant) {
      OrganicButtonVariant.primary =>
        Color.lerp(t.accentBg, Colors.black, 0.14)!,
      OrganicButtonVariant.secondary => t.text.withValues(alpha: 0.14),
      OrganicButtonVariant.ghost => t.accentText.withValues(alpha: 0.18),
    };
    final hovered = switch (variant) {
      OrganicButtonVariant.primary =>
        Color.lerp(t.accentBg, Colors.black, 0.07)!,
      OrganicButtonVariant.secondary => t.text.withValues(alpha: 0.07),
      OrganicButtonVariant.ghost => t.accentText.withValues(alpha: 0.10),
    };

    final button = TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return pressed;
          if (s.contains(WidgetState.hovered)) return hovered;
          return bg;
        }),
        foregroundColor: WidgetStatePropertyAll(label),
        // `.btn:disabled { opacity: 0.45 }`
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        elevation: const WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            vertical: Organic.space2,
            horizontal: variant == OrganicButtonVariant.ghost
                ? Organic.space1
                : Organic.space3 * 1.2,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll(Size.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Organic.radiusPill),
          ),
        ),
        side: borderColor == null
            ? null
            : WidgetStatePropertyAll(BorderSide(color: borderColor)),
        textStyle: WidgetStatePropertyAll(
          OrganicText.button(t).copyWith(fontSize: fontSize),
        ),
      ),
      child: icon == null
          ? Text(this.label)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: fontSize + 2),
                const SizedBox(width: 6), // `.btn { gap: 6px }`
                Text(this.label),
              ],
            ),
    );

    if (!block) return button;
    return Padding(
      padding: const EdgeInsets.only(top: Organic.space2),
      child: SizedBox(width: double.infinity, child: button),
    );
  }
}

/// `.btn-icon` — a 36px circular button. Used for the header's three-dot menu
/// and the `×` that closes drawers and sheets.
class OrganicIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Drawn inside the circle. When null, [child] is used.
  final IconData? icon;
  final Widget? child;
  final double size;

  /// `.btn-icon` has no border by default; the prototype's menu button adds
  /// `border: 1px solid {{ borderCol }}`.
  final bool bordered;
  final Color? color;

  const OrganicIconButton({
    super.key,
    required this.onPressed,
    this.icon,
    this.child,
    this.tooltip,
    this.size = 36,
    this.bordered = false,
    this.color,
  }) : assert(icon != null || child != null, 'provide icon or child');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fg = color ?? t.text;

    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(
          side: bordered ? BorderSide(color: t.border) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          splashFactory: NoSplash.splashFactory,
          hoverColor: t.text.withValues(alpha: 0.07),
          highlightColor: t.text.withValues(alpha: 0.14),
          child: Center(
            child: child ?? Icon(icon, size: size * 0.44, color: fg),
          ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The header's menu control: three 4px dots in a row, drawn with plain shapes
/// exactly as the prototype does (no icon font).
class OrganicMenuDots extends StatelessWidget {
  final Color color;

  const OrganicMenuDots({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => Container(
          width: 4,
          height: 4,
          margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
