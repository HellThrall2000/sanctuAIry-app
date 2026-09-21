import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// A pill-shaped progress bar.
///
/// Lifted from the model-download screen, which had the only progress bar in the
/// app, and generalised. Pill-radius and token-coloured so it belongs to the
/// same family as the tags and buttons rather than looking like stock Material.
class OrganicMeter extends StatelessWidget {
  /// 0.0 to 1.0. Values outside are clamped rather than rejected — a meter that
  /// throws on 1.01 is a worse outcome than one that reads full.
  final double value;
  final double height;
  final Color? color;

  /// Animate to a new value rather than snapping. Off inside long lists, where
  /// dozens of simultaneous animations cost more than they add.
  final bool animate;

  const OrganicMeter({
    super.key,
    required this.value,
    this.height = 8,
    this.color,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fill = color ?? t.accentBg;
    // Dusk's bars run violet into pink. Only when the caller has not named a
    // colour: a meter given an explicit colour is being used to mean something
    // (a metric's own hue, a warning), and a gradient would overrule that.
    final gradient = color == null && t.isDark
        ? const LinearGradient(colors: Organic.duskGradient)
        : null;
    final clamped = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(Organic.radiusPill),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: t.border),
            LayoutBuilder(
              builder: (context, c) {
                final width = c.maxWidth * clamped;
                final decoration = BoxDecoration(
                  // A BoxDecoration takes one or the other, never both.
                  color: gradient == null ? fill : null,
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(Organic.radiusPill),
                );
                final bar = Container(width: width, decoration: decoration);
                if (!animate) return bar;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  width: width,
                  decoration: decoration,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A progress ring with a value in the middle.
///
/// The hero element of the tracker: one glance should say how today is going.
/// Drawn rather than pulled from a chart package — the whole design system is
/// hand-transcribed, a ring is forty lines of `CustomPainter`, and a dependency
/// here would be the first one in the UI layer.
class OrganicRing extends StatelessWidget {
  final double value;
  final double size;
  final double stroke;
  final Color? color;

  /// Big text in the middle — usually a number or a percentage.
  final String? label;

  /// Small text under the label.
  final String? caption;

  const OrganicRing({
    super.key,
    required this.value,
    this.size = 104,
    this.stroke = 9,
    this.color,
    this.label,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final clamped = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: clamped),
        duration: const Duration(milliseconds: 620),
        curve: Curves.easeOutCubic,
        builder: (context, animated, _) => CustomPaint(
          painter: _RingPainter(
            value: animated,
            track: t.border,
            fill: color ?? t.accentBg,
            // Same rule as the meter: a caller-supplied colour wins.
            gradient: color == null && t.isDark ? Organic.duskGradient : null,
            stroke: stroke,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null)
                  Text(
                    label!,
                    style: OrganicText.h4(t).copyWith(
                      fontSize: size * 0.26,
                      height: 1.1,
                    ),
                  ),
                if (caption != null) ...[
                  const SizedBox(height: 2),
                  Text(caption!, style: OrganicText.cardMeta(t)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color track;
  final Color fill;

  /// Swept around the ring instead of [fill] when present.
  final List<Color>? gradient;

  final double stroke;

  const _RingPainter({
    required this.value,
    required this.track,
    required this.fill,
    required this.gradient,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);

    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);

    if (value <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      // Rounded, so a tiny value still reads as a deliberate mark rather than
      // a rendering artefact.
      ..strokeCap = StrokeCap.round;
    if (gradient == null) {
      arc.color = fill;
    } else {
      // Swept, not linear: a linear gradient across the bounding box would put
      // the same colour at the top and the bottom of the ring, so the arc would
      // double back through its own start. A sweep rotated to twelve o'clock
      // runs the colours along the stroke, which is the direction it is read in.
      arc.shader = SweepGradient(
        colors: gradient!,
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    }
    // Starts at twelve o'clock and runs clockwise, which is the only direction
    // anyone reads a ring.
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * value, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.fill != fill ||
      old.track != track ||
      old.gradient != gradient;
}

/// Seven days at a glance, oldest on the left.
///
/// [days] is **newest first**, matching `WellnessLog.history`, and is reversed
/// for display — a week reads left to right regardless of how it is stored.
/// `null` means the day was never logged, which is drawn differently from a
/// logged miss: showing up and falling short is not the same as not showing up,
/// and a tracker that conflates them tells you less than it knows.
class OrganicWeekStrip extends StatelessWidget {
  final List<bool?> days;
  final double dotSize;
  final Color? color;

  /// Mon/Tue/… beneath each dot.
  final bool showLabels;

  /// Weekday of the newest entry, so labels line up with reality.
  final int? todayWeekday;

  const OrganicWeekStrip({
    super.key,
    required this.days,
    this.dotSize = 26,
    this.color,
    this.showLabels = true,
    this.todayWeekday,
  });

  static const _names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fill = color ?? t.accentBg;
    final ordered = days.reversed.toList();
    final today = todayWeekday ?? DateTime.now().weekday;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < ordered.length; i++)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(
                state: ordered[i],
                size: dotSize,
                fill: fill,
                track: t.border,
                onFill: t.onAccent,
              ),
              if (showLabels) ...[
                const SizedBox(height: 5),
                Text(
                  // Walk back from today for the oldest entry, then forward.
                  _names[(today - (ordered.length - i) + 7) % 7],
                  style: OrganicText.cardMeta(t).copyWith(fontSize: 9),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final bool? state;
  final double size;
  final Color fill;
  final Color track;
  final Color onFill;

  const _Dot({
    required this.state,
    required this.size,
    required this.fill,
    required this.track,
    required this.onFill,
  });

  @override
  Widget build(BuildContext context) {
    // Three states, three treatments: filled for met, a hollow ring for a
    // logged miss, and a faint disc for a day that never happened.
    final met = state == true;
    final missed = state == false;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: met ? fill : (missed ? Colors.transparent : track.withValues(alpha: 0.45)),
        border: missed ? Border.all(color: fill.withValues(alpha: 0.55), width: 1.6) : null,
      ),
      child: met
          ? Icon(Icons.check_rounded, size: size * 0.56, color: onFill)
          : null,
    );
  }
}

/// A round check control in the app's own idiom.
///
/// Material's `Checkbox` is square, ships its own ripple and splash colours, and
/// ignores the token palette — three reasons it never appeared in this codebase.
class OrganicCheck extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double size;
  final Color? color;

  const OrganicCheck({
    super.key,
    required this.value,
    this.onChanged,
    this.size = 24,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fill = color ?? t.accentBg;

    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      // Transparent so the tap target covers the padding, not just the circle.
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: value ? fill : Colors.transparent,
          border: Border.all(
            color: value ? fill : t.border,
            width: 1.8,
          ),
        ),
        child: value
            ? Icon(Icons.check_rounded, size: size * 0.62, color: t.onAccent)
            : null,
      ),
    );
  }
}
