import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_shell.dart';
import 'screens/model_setup_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';
import 'services/consent.dart';
import 'services/firebase_gateway.dart';
import 'services/litert_service.dart';
import 'services/memory_cache.dart';
import 'services/model_profile.dart';
import 'services/notification_service.dart';
import 'services/nudge_service.dart';
import 'services/usage_metrics.dart';
import 'theme/app_theme.dart';

const _themePrefKey = 'sanctuary_theme_dark';

/// Set once the user has chosen to deal with the model download later, so the
/// setup screen does not reappear on every launch and turn a deferral into
/// nagging.
const _setupDeferredKey = 'sanctuary_model_setup_deferred';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Sunlit by default: the Organic system is authored as a light theme, and
  // Dusk is the derived one.
  final isDark = prefs.getBool(_themePrefKey) ?? false;

  // Accounts and usage counting, in that order — the metrics need a uid to
  // attach to.
  //
  // Awaited, unlike everything else in this function, and only because the
  // welcome screen needs a resolved answer: it decides whether to require a
  // Google account, and that decision turns on whether Firebase exists at all.
  // Asking before the answer is known would flash the wrong screen. Bounded by
  // a timeout so an unreachable network delays the launch by two seconds rather
  // than holding it forever — the failure mode this app can least afford.
  try {
    await Future.any([
      () async {
        await FirebaseGateway.instance.init();
        await AuthService.instance.init();
        await UsageMetrics.instance.init();
      }(),
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  } catch (e) {
    debugPrint('Accounts/metrics unavailable, continuing: $e');
  }
  UsageMetrics.instance.startSession();

  final accepted = await Consent.isAccepted();

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

  // Whether a companion is actually on this device. A Play install arrives with
  // no model at all, so this is the ordinary first-run state rather than an
  // error — see ModelSetupScreen.
  final hasModel =
      (await LiteRtService().findLocalModels().catchError((Object e) {
    debugPrint('Model scan failed: $e');
    return const <LocatedModel>[];
  }))
          .isNotEmpty;
  final deferred = prefs.getBool(_setupDeferredKey) ?? false;

  runApp(SanctuaryApp(
    initialDark: isDark,
    needsConsent: !accepted,
    needsModelSetup: !hasModel && !deferred,
  ));
}

class SanctuaryApp extends StatefulWidget {
  final bool initialDark;

  /// Show the terms and account screen before anything else.
  final bool needsConsent;

  /// Show the first-run download before the sanctuary itself.
  final bool needsModelSetup;

  const SanctuaryApp({
    super.key,
    this.initialDark = false,
    this.needsConsent = false,
    this.needsModelSetup = false,
  });

  @override
  State<SanctuaryApp> createState() => SanctuaryAppState();

  static SanctuaryAppState of(BuildContext context) =>
      context.findAncestorStateOfType<SanctuaryAppState>()!;
}

class SanctuaryAppState extends State<SanctuaryApp> with WidgetsBindingObserver {
  late bool _isDark;
  late bool _needsConsent;
  late bool _needsSetup;

  @override
  void initState() {
    super.initState();
    _isDark = widget.initialDark;
    _needsConsent = widget.needsConsent;
    _needsSetup = widget.needsModelSetup;
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
      // The one point where usage counters go to the server. Buffered until
      // now so a chatty session costs one write rather than forty.
      unawaited(UsageMetrics.instance.endSessionAndFlush().catchError((Object e) {
        debugPrint('Usage flush on pause failed: $e');
      }));
    } else if (state == AppLifecycleState.resumed) {
      UsageMetrics.instance.startSession();
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

  /// Leaves the setup screen, whether the model arrived or the user deferred.
  Future<void> _leaveSetup({required bool deferred}) async {
    if (deferred) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_setupDeferredKey, true);
    }
    if (mounted) setState(() => _needsSetup = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sanctuAIry',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.sunlit(),
      darkTheme: AppTheme.dusk(),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      // Consent, then the model, then the sanctuary. Terms come first because
      // agreeing to them is what licenses everything after — including the
      // download.
      home: _needsConsent
          ? WelcomeScreen(onAccepted: () => setState(() => _needsConsent = false))
          : _needsSetup
              ? ModelSetupScreen(
                  onReady: () => _leaveSetup(deferred: false),
                  onDefer: () => _leaveSetup(deferred: true),
                )
              : HomeShell(isDark: _isDark, onThemeChanged: setDark),
    );
  }
}
