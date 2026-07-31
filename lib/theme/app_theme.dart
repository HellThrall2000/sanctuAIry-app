import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

/// Builds [ThemeData] from [SanctuaryTokens].
///
/// One builder, two palettes. `main.dart` used to carry `theme` and `darkTheme`
/// as byte-identical 35-line copies, so any change had to be made twice and in
/// practice was made once.
///
/// Most of the app's look comes from the Organic widgets in
/// `lib/widgets/organic/`, which read [SanctuaryTokens] directly. What is set
/// here is the Material scaffolding those widgets sit on — selection handles,
/// scrollbars, the text cursor — so that stock Flutter chrome doesn't arrive
/// in the wrong palette.
abstract final class AppTheme {
  static ThemeData sunlit() => _build(SanctuaryTokens.sunlit);

  static ThemeData dusk() => _build(SanctuaryTokens.dusk);

  static ThemeData _build(SanctuaryTokens t) {
    final brightness = t.isDark ? Brightness.dark : Brightness.light;

    // Spelled out rather than ColorScheme.fromSeed: seeding runs the colour
    // through Material 3's tonal palettes, producing harmonious colours that
    // are *not* the ones the design specifies. The handoff is explicit that
    // this is "high-fidelity … implement pixel-perfectly", so if it says
    // #56633F the app shows #56633F.
    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.accentBg,
      onPrimary: t.onAccent,
      secondary: t.accentText,
      onSecondary: t.onAccent,
      error: Organic.danger,
      onError: Organic.neutral100,
      surface: t.bgSurface,
      onSurface: t.text,
      surfaceContainerHighest: t.bgPanel,
      outline: t.border,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.bgApp,
      canvasColor: t.bgApp,
      dividerColor: t.border,
      fontFamily: Organic.bodyFont,
      // Both set explicitly because ThemeData's defaults are wrong for us: in
      // dark mode `primaryColor` falls back to `colorScheme.surface`, not
      // `.primary`, which would silently turn every accent into the card
      // colour.
      primaryColor: t.accentBg,
      cardColor: t.bgSurface,
      splashFactory: InkSparkle.splashFactory,
      extensions: [t],
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: Organic.bodyFont,
        bodyColor: t.text,
        displayColor: t.text,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.bgPanel,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: t.text, size: 20),
      ),
      dividerTheme: DividerThemeData(
        color: t.border,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: t.muted),
      // The prototype draws its own sheets and dialogs, but Flutter still
      // routes `showModalBottomSheet` / `showDialog` through these.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.bgPanel,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Organic.backdrop,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bgSurface,
        surfaceTintColor: Colors.transparent,
        barrierColor: Organic.dialogBackdrop,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Organic.radiusCard),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: t.bgPanel,
        surfaceTintColor: Colors.transparent,
        scrimColor: Organic.backdrop,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.bgPanel,
        contentTextStyle: OrganicText.input(t),
        actionTextColor: t.accentText,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Organic.radiusMd),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accentBg,
        linearTrackColor: t.border,
        circularTrackColor: t.border,
      ),
      textSelectionTheme: TextSelectionThemeData(
        // `.input { caret-color: var(--color-accent) }`
        cursorColor: t.accentBg,
        selectionColor: t.accentBg.withValues(alpha: 0.3),
        selectionHandleColor: t.accentBg,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.text.withValues(alpha: 0.18)),
        thickness: const WidgetStatePropertyAll(4),
        radius: const Radius.circular(2),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.bgPanel,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(Organic.radiusSm),
        ),
        textStyle: OrganicText.tag(t),
      ),
    );
  }
}
