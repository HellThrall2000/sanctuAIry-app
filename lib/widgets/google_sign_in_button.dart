import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Google's sign-in button, to Google's rules.
///
/// **Deliberately outside the Organic system.** Every other control in this app
/// is drawn from `organic-styles.css`; this one is not ours to restyle. The
/// Sign-In branding guidelines are specific and checked at review: the "G" mark
/// unrecoloured, on a white or near-black field, with the exact wording "Sign in
/// with Google". So the design system bends around this control rather than the
/// other way round — the only place in the app where that is true.
class GoogleSignInButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  final double height;

  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.height = 48,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final enabled = onPressed != null && !busy;

    return SizedBox(
      width: double.infinity,
      height: height,
      child: Material(
        color: t.isDark ? const Color(0xFF131314) : Colors.white,
        borderRadius: BorderRadius.circular(Organic.radiusPill),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(Organic.radiusPill),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Organic.radiusPill),
              border: Border.all(
                color: t.isDark
                    ? const Color(0xFF8E918F)
                    : const Color(0xFF747775),
              ),
            ),
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: t.accentBg,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const GoogleMark(size: 18),
                        const SizedBox(width: 10),
                        Text(
                          // The wording is prescribed. Do not shorten it.
                          'Sign in with Google',
                          style: TextStyle(
                            fontFamily: Organic.bodyFont,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: t.isDark
                                ? const Color(0xFFE3E3E3)
                                : const Color(0xFF1F1F1F),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The four-colour Google "G", drawn rather than bundled.
///
/// Painted instead of shipped as an asset so it stays crisp at any size and adds
/// nothing to the APK — but the colours below are Google's brand hexes and must
/// not be adjusted to fit the palette.
class GoogleMark extends StatelessWidget {
  final double size;

  const GoogleMark({super.key, required this.size});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _GoogleMarkPainter()),
      );
}

class _GoogleMarkPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.22;
    final rect = Rect.fromCircle(
      center: Offset(s / 2, s / 2),
      radius: (s - stroke) / 2,
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    void arc(double startDeg, double sweepDeg, Color color) {
      canvas.drawArc(
        rect,
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        paint..color = color,
      );
    }

    // Clockwise from the bar on the right.
    arc(-18, 78, _blue);
    arc(60, 70, _green);
    arc(130, 78, _yellow);
    arc(208, 84, _red);

    // The crossbar of the G, reaching in from the right.
    canvas.drawRect(
      Rect.fromLTRB(s * 0.5, s * 0.39, s * 0.94, s * 0.61),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
