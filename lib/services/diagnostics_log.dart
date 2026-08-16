import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A breadcrumb trail that survives the process dying.
///
/// **Why this exists alongside Crashlytics.** A crash handler needs a live
/// process to run in. An out-of-memory kill is a `SIGKILL` — the kernel stops
/// the process where it stands, no handler runs, nothing is reported, and the
/// user sees "sanctuAIry keeps stopping" with no trace anywhere. That is the
/// single most likely failure for an app holding a 2.5 GB model resident, and
/// it is exactly the one Crashlytics cannot see.
///
/// So the trail is written *forward*, before each risky step, and a clean exit
/// is marked at the end. If the next launch finds a trail with no clean-exit
/// marker, the previous run died — and the last stage written says where.
/// [reportPreviousRun] then sends that to Crashlytics as a non-fatal, which is
/// how a silent kill becomes a remote report.
///
/// Written to app-scoped **external** storage on purpose: a release build is not
/// debuggable, so `run-as` cannot reach internal storage on a tester's phone.
/// This path opens in any file manager, so a tester can send the file without
/// tools, a cable, or a network.
class DiagnosticsLog {
  static final DiagnosticsLog instance = DiagnosticsLog._();

  DiagnosticsLog._();

  File? _file;
  bool _ready = false;

  /// The trail from the run before this one, if it ended without a clean exit.
  ///
  /// Null when the previous run exited normally, or when there was no previous
  /// run. Read once at startup, before the current run truncates the file.
  String? previousCrashTrail;

  static const String _cleanExit = 'clean_exit';

  /// Whether [trail] describes a run that died rather than finished.
  ///
  /// The test is the **last** line, not whether a clean exit appears anywhere.
  /// The marker is written every time the app is backgrounded, so a run that
  /// paused, resumed and then crashed contains one in the middle — treating a
  /// mere occurrence as proof of a clean exit would silently discard exactly the
  /// crashes that happen after the user comes back to the app.
  static bool _endedBadly(String trail) {
    final lines =
        trail.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    if (lines.isEmpty) return false;
    return !lines.last.contains(_cleanExit);
  }

  /// Trails are tiny, but a device that crash-loops would otherwise grow one
  /// without bound.
  static const int _maxBytes = 64 * 1024;

  /// Opens the trail, reads the previous run's, and starts a fresh one.
  ///
  /// Never throws. Diagnostics that can break the app they are diagnosing are
  /// worse than no diagnostics — this whole class is optional by construction.
  Future<void> init() async {
    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
      final file = File('${dir.path}/diagnostics.log');

      if (await file.exists()) {
        final previous = await file.readAsString();
        if (_endedBadly(previous)) {
          previousCrashTrail = previous.length > _maxBytes
              ? previous.substring(previous.length - _maxBytes)
              : previous;
        }
      }

      _file = file;
      _ready = true;
      await file.writeAsString(
        '--- run started ${DateTime.now().toIso8601String()} ---\n',
      );
      await stage('app_start');
    } catch (e) {
      debugPrint('Diagnostics log unavailable: $e');
      _ready = false;
    }
  }

  /// Records that the app is about to attempt [name].
  ///
  /// Deliberately written *before* the step, not after: the whole point is to
  /// name the thing that was in progress when the process died.
  Future<void> stage(String name, {String? detail}) async {
    if (!_ready || _file == null) return;
    try {
      final free = await _availableMemoryMb();
      final line = StringBuffer()
        ..write(DateTime.now().toIso8601String())
        ..write('  stage=')
        ..write(name);
      if (free != null) line.write('  freeRamMb=$free');
      if (detail != null) line.write('  $detail');
      line.write('\n');
      await _file!.writeAsString(line.toString(), mode: FileMode.append);
    } catch (_) {
      // A failed diagnostic write is not worth surfacing anywhere.
    }
  }

  /// Marks this run as having ended on purpose.
  ///
  /// Its absence on the next launch is the signal, so this is the one call that
  /// must not be skipped on a normal exit.
  Future<void> markCleanExit() async {
    if (!_ready || _file == null) return;
    try {
      await _file!.writeAsString(
        '${DateTime.now().toIso8601String()}  $_cleanExit\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Memory the kernel believes is actually available, in MB.
  ///
  /// `MemAvailable` rather than `MemFree`: free memory on Android is nearly
  /// always small because the page cache uses whatever is spare, so `MemFree`
  /// looks alarming on a healthy device and says nothing. `MemAvailable` is the
  /// kernel's own estimate of what a new allocation could actually get, which
  /// is the number that predicts an OOM kill.
  ///
  /// Linux-only, and absent on some devices — null simply omits the field.
  Future<int?> _availableMemoryMb() async {
    if (!Platform.isAndroid) return null;
    try {
      final meminfo = await File('/proc/meminfo').readAsLines();
      for (final line in meminfo) {
        if (!line.startsWith('MemAvailable:')) continue;
        final kb = int.tryParse(
          line.replaceAll(RegExp(r'[^0-9]'), ''),
        );
        return kb == null ? null : kb ~/ 1024;
      }
    } catch (_) {}
    return null;
  }
}
