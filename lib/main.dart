import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_shell.dart';
import 'services/memory_cache.dart';
import 'services/notification_service.dart';
import 'services/nudge_service.dart';
import 'theme/app_theme.dart';

const _themePrefKey = 'sanctuary_theme_dark';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Sunlit by default: the Organic system is authored as a light theme, and
  // Dusk is the derived one.
  final isDark = prefs.getBool(_themePrefKey) ?? false;

  // Channel and timezone setup only. Permission is deliberately *not* requested
  // here — it is asked for the first time a check-in is actually scheduled, by
  // which point the user has had a conversation and the prompt has some
  // context. A permission dialog on first launch, before the app has done
  // anything, is how you get denied.
  //
  // Not awaited, and wrapped: nothing about an optional reminder may stand
  // between the user and their conversation. An earlier version awaited this,
  // and a bad notification-icon reference threw here and left the app on its
  // splash screen indefinitely — the whole app lost to a feature that only
  // matters when it is closed. NotificationService.init() is idempotent, so
  // the first real use simply awaits whatever this started.
  unawaited(NotificationService.instance.init().catchError((Object e) {
    debugPrint('Notification setup failed, continuing without it: $e');
  }));
  unawaited(NudgeService.instance.load().catchError((Object e) {
    debugPrint('Nudge settings failed to load: $e');
  }));

  // Build the companion's working memory now, while the user is still reading
  // the first screen, so the first message costs no database work at all. This
  // also backfills anything the diary is owed — an entry permitted before
  // extraction existed produces its facts and chunks here.
  unawaited(MemoryCache.instance.warm().catchError((Object e) {
    debugPrint('Memory warm failed: $e');
  }));

  runApp(SanctuaryApp(initialDark: isDark));
}

class SanctuaryApp extends StatefulWidget {
  final bool initialDark;

  const SanctuaryApp({super.key, this.initialDark = false});

  @override
  State<SanctuaryApp> createState() => SanctuaryAppState();

  static SanctuaryAppState of(BuildContext context) =>
      context.findAncestorStateOfType<SanctuaryAppState>()!;
}

class SanctuaryAppState extends State<SanctuaryApp> with WidgetsBindingObserver {
  late bool _isDark;

  @override
  void initState() {
    super.initState();
    _isDark = widget.initialDark;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Condenses the session when the app leaves the foreground.
  ///
  /// `paused` rather than `detached`: Android is not obliged to deliver
  /// `detached` at all, and a summary written only on a graceful exit would be
  /// missing precisely when the app was killed for memory — which, with a 2.5 GB
  /// model resident, is the common case.
  ///
  /// Summarising is extractive and takes microseconds, so it completes inside
  /// the window the platform allows. Nothing here blocks the UI.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(MemoryCache.instance.onSessionEnded().catchError((Object e) {
        debugPrint('Session summary on pause failed: $e');
      }));
    }
  }

  bool get isDark => _isDark;

  /// Switches palette and remembers the choice.
  ///
  /// This used to write the preference and change nothing: `themeMode` was
  /// hardcoded to `ThemeMode.dark` and both themes were identical, so the
  /// drawer's toggle was a dead control. It is the "Sunlit / Dusk" segmented
  /// control now, and it works.
  Future<void> setDark(bool value) async {
    if (value == _isDark) return;
    setState(() => _isDark = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themePrefKey, value);
  }

  void toggleTheme() => setDark(!_isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sanctuary',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.sunlit(),
      darkTheme: AppTheme.dusk(),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: HomeShell(isDark: _isDark, onThemeChanged: setDark),
    );
  }
}
