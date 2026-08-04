import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps a reply being written when the user stops looking at the app.
///
/// **The problem this solves.** Generation takes 15–30 seconds. In that window
/// the user can switch apps, lock the screen, or simply put the phone down —
/// and a backgrounded process holding a 2.5 GB model resident is the first
/// thing Android reclaims. The reply was discarded mid-sentence and the message
/// sat unanswered, which is exactly what a tester reported.
///
/// The existing wake lock does not help: it stops the CPU sleeping, not the
/// system freezing or killing a background process. A foreground service is the
/// only supported way to finish work the user asked for after they look away —
/// see `GenerationService.kt` for why `shortService` is the right type.
///
/// **Wrapped in defence, not relied upon.** If the platform refuses the service
/// or kills the process anyway, generation still runs; the reply is simply at
/// risk again, and the unanswered message is picked up on next launch. Nothing
/// here may throw into the send path.
class BackgroundGeneration {
  static final BackgroundGeneration instance = BackgroundGeneration._();

  BackgroundGeneration._();

  static const MethodChannel _channel = MethodChannel('sanctuary/generation');

  bool _active = false;

  /// Whether a reply is currently being protected.
  bool get isActive => _active;

  /// Whether the app is in the background right now.
  ///
  /// Used to decide whether a finished reply needs a notification: if the user
  /// is looking at the conversation the reply simply appears, and a
  /// notification for something already on screen is noise.
  bool get isAppInBackground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  /// Call immediately before generation starts.
  ///
  /// Must be called while the app is foreground — `shortService` cannot be
  /// started from the background — which is always true here, because the user
  /// has just pressed send.
  Future<void> begin() async {
    if (_active) return;
    try {
      await _channel.invokeMethod<bool>('begin');
      _active = true;
    } on PlatformException catch (e) {
      debugPrint('Background generation unavailable: ${e.message}');
    } catch (e) {
      debugPrint('Background generation unavailable: $e');
    }
  }

  /// Call when generation finishes, however it finishes.
  ///
  /// Leaving the service running would leave a permanent notification and hold
  /// the process awake, so this belongs in a `finally`.
  Future<void> end() async {
    if (!_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<bool>('end');
    } catch (e) {
      debugPrint('Could not stop background generation: $e');
    }
  }
}
