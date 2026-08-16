import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'diagnostics_log.dart';
import 'firebase_gateway.dart';

/// Sends crashes somewhere they can actually be read.
///
/// **The problem this solves.** A release APK is not debuggable, so `run-as`
/// cannot reach `engine.log` on a tester's phone, and a sideloaded build has no
/// Play Console to report into. Until now a crash on someone else's device
/// produced exactly nothing — the only diagnosis available was guessing from a
/// screenshot of "sanctuAIry keeps stopping".
///
/// Three classes of failure, and each needs a different mechanism:
///
///  * **Dart exceptions** — [FlutterError.onError] and
///    [PlatformDispatcher.onError]. Caught in-process and reported.
///  * **Native crashes** — the Crashlytics NDK layer, wired in
///    `app/build.gradle`.
///  * **Out-of-memory kills** — *not catchable at all*. `SIGKILL` runs no
///    handler. These are reported one launch late, from the breadcrumb trail in
///    [DiagnosticsLog], which is why that class exists.
///
/// Reports are written to disk immediately and uploaded on the next launch, so
/// none of this blocks or delays an offline device. The app is fully usable with
/// no network and no Firebase project at all — [FirebaseGateway.isAvailable]
/// gates every call here.
class CrashReporter {
  static final CrashReporter instance = CrashReporter._();

  CrashReporter._();

  bool _active = false;

  /// Installs the handlers. Safe to call when Firebase is absent.
  Future<void> init() async {
    if (!FirebaseGateway.instance.isAvailable) {
      debugPrint('Crash reporting unavailable: no Firebase project.');
      return;
    }

    try {
      final crashlytics = FirebaseCrashlytics.instance;

      // Debug builds report to the console, not to the dashboard. Otherwise a
      // day of deliberately breaking things locally buries the one real report
      // from a tester.
      await crashlytics.setCrashlyticsCollectionEnabled(!kDebugMode);

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        crashlytics.recordFlutterFatalError(details);
      };

      // Everything the framework does not route through FlutterError: async
      // errors with no zone, platform-channel failures, isolate errors.
      PlatformDispatcher.instance.onError = (error, stack) {
        crashlytics.recordError(error, stack, fatal: true);
        return true;
      };

      _active = true;
      await _reportPreviousUncleanExit(crashlytics);
    } catch (e) {
      debugPrint('Crash reporting setup failed, continuing without it: $e');
    }
  }

  /// Turns a silent kill into a report, one launch after it happened.
  ///
  /// If the previous run left a breadcrumb trail with no clean-exit marker, the
  /// process died without unwinding — an OOM kill, a native abort, or the user
  /// force-stopping it. The trail names the last stage reached and the memory
  /// available at the time, which together distinguish "killed while loading a
  /// 2.5 GB model on a 6 GB phone" from every other cause.
  ///
  /// Recorded as non-fatal: it is a report *about* a previous crash, not a crash
  /// of this run, and marking it fatal would corrupt the crash-free-users metric
  /// for a session that is currently fine.
  Future<void> _reportPreviousUncleanExit(FirebaseCrashlytics crashlytics) async {
    final trail = DiagnosticsLog.instance.previousCrashTrail;
    if (trail == null) return;

    try {
      final lastStage = trail
          .trim()
          .split('\n')
          .lastWhere((l) => l.contains('stage='), orElse: () => 'unknown');

      await crashlytics.setCustomKey('last_stage', lastStage);
      await crashlytics.log('Previous run ended without a clean exit:\n$trail');
      await crashlytics.recordError(
        'Unclean exit — likely an OOM kill. Last stage: $lastStage',
        StackTrace.current,
        reason: 'process died with no handler; reconstructed from breadcrumbs',
        fatal: false,
      );
      debugPrint('Reported previous unclean exit. Last stage: $lastStage');
    } catch (e) {
      debugPrint('Could not report previous exit: $e');
    }
  }

  /// Records the stage locally and, when available, on the next crash report.
  ///
  /// One call site, two destinations: the local trail survives a kill, and the
  /// custom key means any crash that *is* caught arrives already labelled with
  /// what the app was doing.
  Future<void> stage(String name, {String? detail}) async {
    await DiagnosticsLog.instance.stage(name, detail: detail);
    if (!_active) return;
    try {
      await FirebaseCrashlytics.instance.setCustomKey('stage', name);
    } catch (_) {}
  }

  /// Attaches the signed-in user, so a tester's reports can be found together.
  ///
  /// The Firebase uid only — never an email, a name, or anything they wrote.
  Future<void> setUser(String? uid) async {
    if (!_active) return;
    try {
      await FirebaseCrashlytics.instance.setUserIdentifier(uid ?? '');
    } catch (_) {}
  }
}
