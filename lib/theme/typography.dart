import 'package:flutter/material.dart';

import 'tokens.dart';

/// Text styles transcribed from `organic-styles.css`.
///
/// Named after the CSS classes they come from rather than Material's slots
/// (`bodyMedium`, `titleLarge`, …), because the mapping is not one-to-one —
/// `.card-title` is 17px in the heading face, which is not any Material slot —
/// and because a reviewer holding the stylesheet should be able to find each
/// rule by name.
///
/// Sizes are logical pixels, matching the CSS 1:1. Where the CSS sets opacity
/// on a colour (`.card-body { opacity: 0.8 }`) that is folded into the colour
/// here, since Flutter would otherwise fade the whole subtree.
abstract final class OrganicText {
  static const _heading = Organic.headingFont;
  static const _body = Organic.bodyFont;

  // --- Headings: Caprasimo, line-height 1.12, letter-spacing -0.015em ------

  static TextStyle _h(double size, Color color) => TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: size,
        height: 1.12,
        letterSpacing: size * -0.015,
        color: color,
      );

  static TextStyle h1(SanctuaryTokens t) => _h(42, t.text);
  static TextStyle h2(SanctuaryTokens t) => _h(32, t.text);
  static TextStyle h3(SanctuaryTokens t) => _h(25, t.text);
  static TextStyle h4(SanctuaryTokens t) => _h(20, t.text);
  static TextStyle h5(SanctuaryTokens t) => _h(16, t.text);

  /// `h6` is the odd one: uppercase, positive tracking, used as a section
  /// label ("Sanctuary Controls", "Secure Journal Vault"). Callers uppercase
  /// the string themselves — Flutter has no `text-transform`.
  static TextStyle h6(SanctuaryTokens t, {Color? color}) => TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: 13,
        height: 1.12,
        letterSpacing: 13 * 0.08,
        color: color ?? t.text,
      );

  // --- Body ---------------------------------------------------------------

  /// `body { font-size: 15px; line-height: 1.55 }`.
  static TextStyle body(SanctuaryTokens t) => TextStyle(
        fontFamily: _body,
        fontWeight: FontWeight.w400,
        fontSize: 15,
        height: 1.55,
        color: t.text,
      );

  /// `.text-muted` — the CSS mixes text with 55% transparency.
  static TextStyle muted(SanctuaryTokens t) =>
      body(t).copyWith(color: t.text.withValues(alpha: 0.55));

  // --- Components ---------------------------------------------------------

  /// `.btn` — 14px in the *heading* face, which is what gives the buttons
  /// their character. Easy to miss: it is the only control that isn't Figtree.
  static TextStyle button(SanctuaryTokens t, {Color? color}) => TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: 14,
        height: 1.2,
        color: color ?? t.text,
      );

  /// `.input` / `.radio`
  static TextStyle input(SanctuaryTokens t, {Color? color}) => TextStyle(
        fontFamily: _body,
        fontWeight: FontWeight.w400,
        fontSize: 14,
        color: color ?? t.text,
      );

  /// `.field > label` — 12px at 70% of the text colour.
  static TextStyle fieldLabel(SanctuaryTokens t) => TextStyle(
        fontFamily: _body,
        fontSize: 12,
        height: 1.3,
        color: t.text.withValues(alpha: 0.70),
      );

  /// `.card-title` — 17px heading face.
  static TextStyle cardTitle(SanctuaryTokens t, {double size = 17}) => TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: size,
        height: 1.2,
        color: t.text,
      );

  /// `.card-body` — 13px, `opacity: 0.8` folded into the colour.
  static TextStyle cardBody(SanctuaryTokens t) => TextStyle(
        fontFamily: _body,
        fontSize: 13,
        height: 1.55,
        color: t.text.withValues(alpha: 0.8),
      );

  /// `.card-meta` — 11px at 50%.
  static TextStyle cardMeta(SanctuaryTokens t) => TextStyle(
        fontFamily: _body,
        fontSize: 11,
        height: 1.4,
        color: t.text.withValues(alpha: 0.5),
      );

  /// `.card-kicker` — 10px uppercase accent, tracking 0.1em.
  static TextStyle cardKicker(SanctuaryTokens t) => TextStyle(
        fontFamily: _body,
        fontSize: 10,
        height: 1.4,
        letterSpacing: 10 * 0.1,
        color: t.accentText,
      );

  /// `.tag` — 11px, tracking 0.02em. 1c drops it to 10px.
  static TextStyle tag(SanctuaryTokens t, {double size = 11, Color? color}) =>
      TextStyle(
        fontFamily: _body,
        fontSize: size,
        height: 1.3,
        letterSpacing: size * 0.02,
        color: color ?? t.text,
      );

  /// `.dialog-title` — 20px heading face. 1c drops it to 17px.
  static TextStyle dialogTitle(SanctuaryTokens t, {double size = 20}) =>
      TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: size,
        height: 1.12,
        color: t.text,
      );

  /// `.dialog-body` — 14px, `opacity: 0.85`. 1c drops it to 12px.
  static TextStyle dialogBody(SanctuaryTokens t, {double size = 14}) =>
      TextStyle(
        fontFamily: _body,
        fontSize: size,
        height: 1.5,
        color: t.text.withValues(alpha: 0.85),
      );

  // --- Shell chrome -------------------------------------------------------

  /// The uppercase strapline under the app name — "PRIVATE COMPANION & DIARY".
  /// 9px in 1a, 8px in 1c, tracking 0.12em in both.
  static TextStyle strapline(SanctuaryTokens t, {double size = 9}) => TextStyle(
        fontFamily: _body,
        fontSize: size,
        height: 1.3,
        letterSpacing: size * 0.12,
        color: t.muted,
      );

  /// Chat bubble copy. 13.5px in 1a, 13px in 1c; line-height 1.5 in both.
  static TextStyle bubble(Color color, {double size = 13.5}) => TextStyle(
        fontFamily: _body,
        fontSize: size,
        height: 1.5,
        color: color,
      );

  /// Sidebar / tab-bar nav labels — heading face, 13px in 1b, 12px in 1c.
  static TextStyle navLabel(Color color, {double size = 13}) => TextStyle(
        fontFamily: _heading,
        fontWeight: FontWeight.w400,
        fontSize: size,
        height: 1.2,
        color: color,
      );
}
