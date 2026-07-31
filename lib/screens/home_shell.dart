import 'package:flutter/material.dart';

import 'focus_bloom_shell.dart';
import 'warm_companion_shell.dart';

/// Picks the shell that fits the window.
///
/// The handoff offers three alternative layouts for the same app. Two are
/// built: **1c Focus Bloom** for phones and **1a Warm Companion** for tablets
/// and desktops. They share every component, every token and the whole of
/// [ChatView] — only the navigation chrome differs, which is the only part the
/// two designs actually disagree about.
///
/// The 1b sidebar variant is not built. It is 1a's content in a persistent
/// column rather than overlay drawers, so it would add a third chrome for the
/// same three destinations.
class HomeShell extends StatelessWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeChanged;

  /// Below this the phone shell is used.
  ///
  /// 600dp is Material's own phone/tablet split, and it lands in the right
  /// place for these two designs: 1a's header needs room for a title, a
  /// strapline, "Open Diary" and a sign-in control on one line, and its 270px
  /// drawer would cover most of a phone.
  static const breakpoint = 600.0;

  const HomeShell({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= breakpoint;

    return wide
        ? WarmCompanionShell(isDark: isDark, onThemeChanged: onThemeChanged)
        : FocusBloomShell(isDark: isDark, onThemeChanged: onThemeChanged);
  }
}
