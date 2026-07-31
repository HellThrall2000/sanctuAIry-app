import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.card` — a column of content on the surface colour.
///
/// ```css
/// .card { display:flex; flex-direction:column; gap: var(--space-2);
///         padding: var(--space-3); background: var(--color-surface); }
/// .card, .dialog { border-radius: calc(var(--radius-lg) * 1.15); }
/// ```
///
/// The 32.2px radius is what makes the system read as "organic" — it is nearly
/// a quarter of a small card's height, so cards look pebble-like rather than
/// rectangular. Rounding it to 32 across a screen of cards is visible, so
/// [Organic.radiusCard] keeps the fraction.
class OrganicCard extends StatelessWidget {
  final List<Widget> children;

  /// `.elev-sm` / `.elev-md` / `.elev-lg`. Cards in the prototype are flat;
  /// sheets and dialogs carry elevation.
  final List<BoxShadow>? shadow;

  /// Defaults to the theme's surface. The prototype overrides it per placement
  /// — the diary's passcode field sits on `bgApp` inside a `bgSurface` card.
  final Color? color;

  final EdgeInsetsGeometry? padding;
  final CrossAxisAlignment crossAxisAlignment;
  final VoidCallback? onTap;

  const OrganicCard({
    super.key,
    required this.children,
    this.shadow,
    this.color,
    this.padding,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final radius = BorderRadius.circular(Organic.radiusCard);

    Widget content = Container(
      padding: padding ?? const EdgeInsets.all(Organic.space3),
      decoration: BoxDecoration(
        color: color ?? t.bgSurface,
        borderRadius: radius,
        boxShadow: shadow,
      ),
      child: Column(
        crossAxisAlignment: crossAxisAlignment,
        mainAxisSize: MainAxisSize.min,
        children: _withGaps(children),
      ),
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        hoverColor: t.text.withValues(alpha: 0.04),
        highlightColor: t.text.withValues(alpha: 0.08),
        child: content,
      ),
    );
  }

  /// `gap: var(--space-2)` — Flutter has no flex gap, so it is inserted.
  static List<Widget> _withGaps(List<Widget> items) {
    if (items.length < 2) return items;
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(height: Organic.space2),
        items[i],
      ],
    ];
  }
}

/// `.card-kicker` — small uppercase accent label above a title.
class OrganicCardKicker extends StatelessWidget {
  final String text;

  const OrganicCardKicker(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: OrganicText.cardKicker(context.tokens),
      );
}

/// `.card-title`
class OrganicCardTitle extends StatelessWidget {
  final String text;
  final double size;

  const OrganicCardTitle(this.text, {super.key, this.size = 17});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: OrganicText.cardTitle(context.tokens, size: size),
      );
}

/// `.card-body`
class OrganicCardBody extends StatelessWidget {
  final String text;
  final int? maxLines;
  final TextStyle? style;

  const OrganicCardBody(this.text, {super.key, this.maxLines, this.style});

  @override
  Widget build(BuildContext context) {
    final base = OrganicText.cardBody(context.tokens);
    return Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: style == null ? base : base.merge(style),
    );
  }
}

/// `.card-meta` — the dateline on a journal entry.
class OrganicCardMeta extends StatelessWidget {
  final String text;

  const OrganicCardMeta(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text, style: OrganicText.cardMeta(context.tokens));
}

/// `h6` used as a panel header — "Sanctuary Controls", "Secure Journal Vault",
/// "Aesthetic Palette". Uppercase, muted, tracked out.
class OrganicSectionLabel extends StatelessWidget {
  final String text;

  const OrganicSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Text(
      text.toUpperCase(),
      style: OrganicText.h6(t, color: t.muted),
    );
  }
}
