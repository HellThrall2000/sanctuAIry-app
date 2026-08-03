import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Brings up Firebase, and records whether it came up at all.
///
/// **Firebase is optional to this app, and the code has to mean it.** Sanctuary
/// runs the model, the diary and the whole memory subsystem on the device with
/// no network. Accounts and usage counting are a layer on top for the people
/// shipping it, not something the user is buying. So every Firebase-touching
/// path in the app asks [isAvailable] first and degrades to local-only rather
/// than failing.
///
/// That is not a hypothetical. Three ordinary situations produce an app with no
/// Firebase, and none of them may break it:
///
/// - a fresh clone with no `android/app/google-services.json`, where the Gradle
///   plugin is skipped entirely (see `android/app/build.gradle`);
/// - a device that is offline on first launch, which is the *expected* state for
///   an offline companion;
/// - a Firebase project where Anonymous sign-in was never enabled in the
///   console, which throws `operation-not-allowed` at the first call.
///
/// **Initialisation never throws to the caller.** A failure here leaves
/// [isAvailable] false and is logged; the app carries on. An earlier lesson from
/// `NotificationService` applies exactly: nothing optional may stand between the
/// user and their conversation, and an unguarded `await` in `main()` is how you
/// lose the whole app to a feature that only matters at the edges.
class FirebaseGateway {
  static final FirebaseGateway instance = FirebaseGateway._();

  FirebaseGateway._();

  bool _available = false;
  bool _attempted = false;
  Future<bool>? _initializing;
  String? _failureReason;

  /// Whether a Firebase app is live in this process.
  bool get isAvailable => _available;

  /// Whether [init] has run, successfully or not.
  bool get isResolved => _attempted;

  /// Why Firebase is unavailable, for the diagnostics panel. Null when it is
  /// available or has not been tried.
  String? get failureReason => _failureReason;

  /// Starts Firebase. Safe to call repeatedly and from several places at once.
  ///
  /// Returns whether it is usable, so callers can branch without a second
  /// round trip.
  Future<bool> init() {
    if (_attempted) return Future.value(_available);
    return _initializing ??= _init().whenComplete(() => _initializing = null);
  }

  Future<bool> _init() async {
    try {
      // No explicit FirebaseOptions: on Android the native plugin reads
      // google-services.json, and on iOS GoogleService-Info.plist. That keeps
      // the credentials out of Dart source and means `flutterfire configure` is
      // not a prerequisite for the repository to compile.
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _available = true;
      _failureReason = null;
    } catch (e) {
      _available = false;
      _failureReason = e.toString();
      debugPrint(
        'Firebase unavailable, continuing local-only. '
        'Accounts and usage metrics are off. Reason: $e',
      );
    } finally {
      _attempted = true;
    }
    return _available;
  }
}
