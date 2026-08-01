import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/upcoming_event.dart';
import 'chat_store.dart';
import 'chunk_store.dart';
import 'event_store.dart';
import 'notification_service.dart';
import 'relationship_log.dart';

/// A composed check-in.
class Nudge {
  /// The notification's one-line title.
  final String title;

  /// The message, used both as the notification body and as the line that
  /// appears in the conversation.
  final String text;

  /// The event this was built from, so it can be marked as asked once
  /// delivered.
  final UpcomingEvent? about;

  const Nudge({required this.title, required this.text, this.about});
}

/// Decides when the companion should reach out, and what it should say.
///
/// The difference between a companion and a retention notification is entirely
/// in the second half of that sentence. *"We miss you! Come back!"* is
/// engagement farming. *"You had your interview yesterday — how did it go?"* is
/// someone paying attention. So [compose] works down a priority list and only
/// falls back to something generic when it genuinely has nothing specific, and
/// [_generic] is deliberately the least likely branch to be reached.
class NudgeService {
  static final NudgeService instance = NudgeService._();

  NudgeService._();

  final ChatStore _chat = ChatStore.instance;
  final ChunkStore _chunks = ChunkStore.instance;
  final EventStore _events = EventStore.instance;
  final RelationshipLog _log = RelationshipLog.instance;
  final NotificationService _notifications = NotificationService.instance;

  static const _enabledKey = 'sanctuary_nudges_enabled';
  static const _lastNudgeKey = 'sanctuary_last_nudge_at';

  /// How long the companion waits before reaching out.
  static const Duration silenceBefore = Duration(hours: 3, minutes: 30);

  /// The floor between two check-ins, regardless of everything else.
  ///
  /// Someone who has put the app down for a fortnight should come back to one
  /// message, not fourteen. This is the single most important number here for
  /// keeping the feature on the right side of the line.
  static const Duration minimumGap = Duration(hours: 20);

  /// Quiet hours. Nothing is delivered between these, local time.
  ///
  /// A mental-health app that pings someone at 03:00 has actively harmed them.
  /// A check-in that would land in the window is pushed to [_wakeHour].
  static const int _sleepHour = 22;
  static const int _wakeHour = 9;

  bool _enabled = true;

  bool get enabled => _enabled;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (!value) await _notifications.cancelCheckIn();
  }

  // ── Scheduling ──────────────────────────────────────────────────────────

  /// Re-arms the check-in. Call after every user turn.
  ///
  /// Each call replaces the pending notification, so an active conversation
  /// keeps pushing the check-in out and it only ever fires into real silence.
  Future<void> rearm() async {
    if (!_enabled) return;
    if (!_notifications.permitted) {
      final granted = await _notifications.requestPermission();
      if (!granted) return;
    }

    final nudge = await compose();
    if (nudge == null) return;

    await _notifications.scheduleCheckIn(
      when: _respectQuietHours(DateTime.now().add(silenceBefore)),
      title: nudge.title,
      body: nudge.text,
      payload: nudge.about?.id,
    );
  }

  /// Pushes [when] out of the quiet window.
  static DateTime _respectQuietHours(DateTime when) {
    if (when.hour >= _wakeHour && when.hour < _sleepHour) return when;
    final target = when.hour >= _sleepHour
        ? DateTime(when.year, when.month, when.day + 1, _wakeHour, 30)
        : DateTime(when.year, when.month, when.day, _wakeHour, 30);
    return target;
  }

  // ── In-app delivery ─────────────────────────────────────────────────────

  /// The check-in to show in the conversation on open, or null.
  ///
  /// Separate from the notification so the two agree: someone who opens the app
  /// without tapping the notification should still find the companion has
  /// reached out, rather than an empty screen and a stale ping in the shade.
  Future<Nudge?> pendingNudge() async {
    if (!_enabled) return null;

    final lastUser = await _chat.lastUserMessageAt();
    if (lastUser == null) return null;
    if (DateTime.now().difference(lastUser) < silenceBefore) return null;

    final prefs = await SharedPreferences.getInstance();
    final lastNudgeRaw = prefs.getString(_lastNudgeKey);
    if (lastNudgeRaw != null) {
      final lastNudge = DateTime.tryParse(lastNudgeRaw);
      if (lastNudge != null &&
          DateTime.now().difference(lastNudge) < minimumGap) {
        return null;
      }
    }

    // Never deliver a check-in the moment someone opens the app at 04:00.
    final hour = DateTime.now().hour;
    if (hour >= _sleepHour || hour < _wakeHour) return null;

    return compose();
  }

  /// Records that a check-in was delivered, starting the [minimumGap] clock.
  Future<void> markDelivered(Nudge nudge) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastNudgeKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    if (nudge.about != null) await _events.markAsked(nudge.about!.id);
  }

  // ── Composition ─────────────────────────────────────────────────────────

  /// Builds the most specific check-in the stored context supports.
  Future<Nudge?> compose() async {
    // 1. Something they told us was happening, which has now happened.
    final passed = await _events.nextToAskAbout();
    if (passed != null) {
      return Nudge(
        title: 'Thinking of you',
        text: _pick([
          'You mentioned ${passed.text} ${passed.rawWhen ?? "recently"}. '
              'How did it go?',
          'I have been wondering how ${passed.text} went.',
          "${_capitalise(passed.rawWhen ?? 'Recently')} you had ${passed.text}. "
              'How was it?',
        ]),
        about: passed,
      );
    }

    // 2. Something still ahead of them, close enough to be on their mind.
    final upcoming = await _events.nextUpcoming();
    if (upcoming != null &&
        upcoming.dueAt!.difference(DateTime.now()) < const Duration(days: 2)) {
      return Nudge(
        title: 'Thinking of you',
        text: _pick([
          'You have ${upcoming.text} coming up. How are you feeling about it?',
          '${_capitalise(upcoming.text)} is close now. '
              'Want to talk any of it through?',
        ]),
      );
    }

    // 3. Pick the thread back up from what was actually said.
    final topics = await _log.favouriteTopics(limit: 1);
    if (topics.isNotEmpty) {
      final topic = topics.first.topic;
      return Nudge(
        title: 'Still here',
        text: _pick([
          'I have been thinking about what you said about $topic. '
              'How is that sitting today?',
          'No pressure at all — but I am curious how things are with $topic.',
        ]),
      );
    }

    // 4. Nothing specific. Only reached by someone who has barely talked yet,
    //    so keep it short and make clear it costs them nothing to ignore.
    final recent = await _chunks.latest(limit: 1);
    if (recent.isEmpty) return null;
    return Nudge(title: 'Still here', text: _generic());
  }

  static String _generic() => _pick([
        'No agenda — just checking the door is still open. How has your day been?',
        'Here whenever you want to pick things back up.',
        'Thinking of you. Nothing needed, but I am around if you want to talk.',
      ]);

  /// Varies wording so a returning user does not receive the same sentence
  /// every time, which is what makes a check-in feel automated.
  static String _pick(List<String> options) =>
      options[Random().nextInt(options.length)];

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
