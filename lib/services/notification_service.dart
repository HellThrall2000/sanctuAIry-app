import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// OS-level check-ins.
///
/// One notification id is reused throughout: there is only ever one pending
/// check-in, and scheduling a new one replaces it. A companion that stacks up
/// four unread pings is not attentive, it is nagging.
class NotificationService {
  static final NotificationService instance = NotificationService._();

  NotificationService._();

  static const int _checkInId = 1;
  static const String _channelId = 'sanctuary_check_in';

  /// A finished reply, on its own id and channel so silencing check-ins does
  /// not also silence the answer to a question the user just asked.
  static const int _replyId = 2;
  static const String _replyChannelId = 'sanctuary_reply';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _permitted = false;

  bool get permitted => _permitted;

  /// Payload of the notification the user tapped to open the app, if any.
  String? launchPayload;

  /// Whether setup succeeded. False means check-ins are unavailable this run;
  /// nothing else about the app changes.
  bool _available = false;

  bool get available => _available;

  /// Prepares the plugin. Safe to call repeatedly and safe to fail.
  ///
  /// **Every step is guarded.** This runs from `main()` before `runApp`, and an
  /// exception here means the app never renders at all — which is exactly what
  /// happened the first time: the icon was declared as `@mipmap/ic_launcher`,
  /// a resource this project does not have (the manifest points at the
  /// framework's `sym_def_app_icon`), so `initialize` threw and the app sat on
  /// its splash screen forever. A companion that cannot send a reminder is a
  /// degraded companion; a companion that will not start is not one at all.
  Future<void> init() async {
    if (_ready) return;
    _ready = true;

    try {
      tzdata.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (e) {
        // Falls back to UTC. A check-in an hour or two off is a much smaller
        // problem than no check-ins at all.
        debugPrint('Timezone lookup failed, using UTC: $e');
      }

      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
        ),
      );

      // Ask the system what is actually granted, rather than remembering
      // whether *this process* happened to call requestPermission().
      //
      // [_permitted] used to start false on every launch and only become true
      // if [requestPermission] ran — so a user who had granted notifications
      // weeks ago still got nothing until something re-asked. It silently
      // suppressed the reply notification entirely: `POST_NOTIFICATIONS` read
      // `granted=true` on device while the app refused to post, and the
      // `sanctuary_reply` channel was never even created.
      try {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        _permitted = await android?.areNotificationsEnabled() ?? false;
      } catch (e) {
        // Unknown is treated as permitted: the platform is the real gate and
        // drops what is not allowed. Guessing "no" here is how the bug above
        // happened.
        debugPrint('Could not read notification permission: $e');
        _permitted = true;
      }

      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        launchPayload = details?.notificationResponse?.payload;
      }
      _available = true;
    } catch (e, stack) {
      debugPrint('Notifications unavailable: $e\n$stack');
      _available = false;
    }
  }

  /// Asks for notification permission.
  ///
  /// Called the first time a check-in is actually scheduled rather than at
  /// startup, so the prompt arrives with some context — the user has had at
  /// least one conversation by then.
  Future<bool> requestPermission() async {
    await init();
    if (!_available) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      _permitted = await android?.requestNotificationsPermission() ?? false;
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
      _permitted = false;
    }
    return _permitted;
  }

  /// Schedules the check-in for [when], replacing any pending one.
  Future<void> scheduleCheckIn({
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  }) async {
    await init();
    if (!_available || !_permitted) return;
    if (when.isBefore(DateTime.now())) return;

    await cancelCheckIn();
    await _plugin.zonedSchedule(
      id: _checkInId,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Check-ins',
          channelDescription:
              'Occasional messages from your companion when it has not heard '
              'from you in a while.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // The body is a sentence, not a label; without this it is truncated
          // to one line and the part that makes it personal is the part lost.
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      // Inexact on purpose. `exactAllowWhileIdle` needs SCHEDULE_EXACT_ALARM,
      // which Android treats as a high-friction permission reserved for alarms
      // and calendar events. A check-in that lands within a window of its slot
      // is entirely fine, and this keeps the app off that permission and easier
      // on the battery.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  Future<void> cancelCheckIn() async {
    await init();
    if (!_available) return;
    await _plugin.cancel(id: _checkInId);
  }

  /// Tells the user a reply arrived while they were not looking.
  ///
  /// Only used when generation finished with the app in the background. If they
  /// are watching the conversation the reply simply appears, and notifying
  /// about something already on screen is noise.
  ///
  /// Distinct from a check-in in both id and channel: a check-in is the
  /// companion reaching out unprompted and is something a user might reasonably
  /// switch off, whereas this is the answer to a question they asked thirty
  /// seconds ago. Sharing a channel would mean silencing one silences the
  /// other.
  Future<void> showReply(String text) async {
    await init();
    if (!_available || !_permitted) return;

    // The reply itself, trimmed. Showing the real words is the point — a
    // "you have a new message" placeholder would make them open the app to
    // learn nothing.
    final body = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final preview = body.length <= 240 ? body : '${body.substring(0, 239)}…';

    await _plugin.show(
      id: _replyId,
      title: 'sanctuAIry',
      body: preview,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _replyChannelId,
          'Replies',
          channelDescription:
              'Shown when your companion finishes a reply while the app is '
              'closed.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(preview),
        ),
      ),
    );
  }

  Future<void> cancelReply() async {
    await init();
    if (!_available) return;
    await _plugin.cancel(id: _replyId);
  }
}
