import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'firebase_gateway.dart';

/// Counts how much the app is used. Nothing else.
///
/// **What leaves the device.** Numbers and enum values, broken down by day: how
/// many hours the app was open, how many sessions, how many messages sent, how
/// many diary entries written, plus the app version and platform. And, only when
/// the user has actively signed in with Google, the email and display name on
/// that account.
///
/// **What never leaves the device, by construction.** There is no code path here
/// that takes a string the user wrote. Not a message, not a diary line, not a
/// title, not a remembered fact, not a mood, not a topic. The counters are
/// `int`s incremented by call sites that are handed no text to begin with —
/// [recordMessageSent] takes no arguments on purpose, so there is nothing to
/// leak even by mistake. This is the property the whole app is sold on, and it
/// should be impossible rather than merely unintended.
///
/// **Offline-first, because the app is.** A companion that works on a plane must
/// still count that it was used on a plane. Usage is written to a durable local
/// ledger keyed by date, and syncing pushes it upward whenever the network
/// allows; nothing is ever lost by being offline, however long that lasts.
///
/// **The ledger is a queue, not an archive.** A day is deleted from local
/// storage the moment the server acknowledges it, so the app is not holding a
/// second copy of data that is already safe elsewhere. In steady use that leaves
/// exactly one entry — today's.
///
/// **Absolute totals, not increments.** The consequence of holding the truth
/// locally is that each day is written as the whole day's figure. That makes a
/// write idempotent, so a retry, a duplicate, or a queued write arriving out of
/// order all converge on the right answer. `FieldValue.increment` would
/// double-count every one of those, and offline queues make all three likely.
class UsageMetrics {
  static final UsageMetrics instance = UsageMetrics._();

  UsageMetrics._();

  static const _ledgerKey = 'usage_ledger_v2';
  static const _firstSeenKey = 'usage_first_seen_v1';

  /// Sessions shorter than this are a glance at a notification, not a use.
  /// Counting them inflates the session figure and tells you nothing.
  static const Duration _minSession = Duration(seconds: 3);

  /// Days kept locally are the ones the server has not confirmed, plus today.
  ///
  /// See [_prune]. The ledger is a queue, not an archive.
  static const bool _dropSyncedDays = true;

  FirebaseAnalytics? _analytics;
  FirebaseFirestore? _db;
  bool _enabled = false;

  DateTime? _sessionStart;
  String _appVersion = 'unknown';

  /// date (yyyy-MM-dd) -> that day's totals.
  final Map<String, _Day> _ledger = {};

  bool get isEnabled => _enabled;

  /// Today's totals, for a future "your usage" screen.
  Map<String, num> get today => (_ledger[_todayKey()] ?? _Day()).toMap();

  /// Days recorded locally but not yet accepted by the server.
  int get unsyncedDays => _ledger.values.where((d) => !d.synced).length;

  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Non-fatal; the counters matter more than the label on them.
    }

    await _loadLedger();

    if (!FirebaseGateway.instance.isAvailable) {
      debugPrint('Usage metrics local-only: no Firebase.');
      return;
    }

    try {
      _analytics = FirebaseAnalytics.instance;
      _db = FirebaseFirestore.instance;
      _enabled = true;
      await _analytics!.setAnalyticsCollectionEnabled(true);
    } catch (e) {
      debugPrint('Usage metrics unavailable: $e');
      _enabled = false;
    }
  }

  // ── Recording ───────────────────────────────────────────────────────────
  //
  // Note the signatures: none of these accept content. There is deliberately no
  // parameter through which one of the user's sentences could reach this file.

  void startSession() => _sessionStart = DateTime.now();

  void recordMessageSent() => _bump((d) => d.messages++);

  void recordJournalEntry() => _bump((d) => d.journalEntries++);

  /// Called once when the model finishes loading, so installs that got a
  /// working companion can be told apart from installs that did not.
  void recordModelReady() {
    _bump((d) => d.modelLoads++);
    unawaited(_log('model_ready'));
  }

  void recordModelDownloaded() => unawaited(_log('model_downloaded'));

  void recordSignIn() => unawaited(_log('account_linked_google'));

  void _bump(void Function(_Day) change) {
    final day = _ledger.putIfAbsent(_todayKey(), _Day.new);
    change(day);
    day.synced = false;
  }

  // ── Session accounting ──────────────────────────────────────────────────

  /// Closes the session, folds its time into the ledger, and syncs.
  Future<void> endSessionAndFlush() async {
    final started = _sessionStart;
    _sessionStart = null;

    if (started != null) {
      final elapsed = DateTime.now().difference(started);
      if (elapsed >= _minSession) {
        // A session running past midnight is split across the two days it
        // actually happened on, rather than being charged entirely to whichever
        // day it happened to end on.
        _attribute(started, DateTime.now());
        final day = _ledger.putIfAbsent(_todayKey(), _Day.new);
        day.sessions++;
        day.synced = false;
      }
    }

    await _saveLedger();
    await sync();
  }

  /// Adds the seconds between [from] and [to] to the days they fall on.
  void _attribute(DateTime from, DateTime to) {
    var cursor = from;
    while (cursor.isBefore(to)) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day)
          .add(const Duration(days: 1));
      final chunkEnd = midnight.isBefore(to) ? midnight : to;
      final seconds = chunkEnd.difference(cursor).inSeconds;
      if (seconds > 0) {
        final day = _ledger.putIfAbsent(_keyFor(cursor), _Day.new);
        day.activeSeconds += seconds;
        day.synced = false;
      }
      cursor = chunkEnd;
    }
  }

  // ── Syncing ─────────────────────────────────────────────────────────────

  /// Pushes every unsynced day to Firestore.
  ///
  /// The write is **not awaited to completion**. Firestore resolves a write only
  /// once a server has acknowledged it, so awaiting inside
  /// `AppLifecycleState.paused` — where the platform allows a few hundred
  /// milliseconds — would block until it gave up. Instead the future is left to
  /// resolve whenever connectivity returns, and marks the day synced when it
  /// does. Firestore's own on-disk queue carries it across process death, and
  /// the local ledger carries it across anything that queue does not survive.
  Future<void> sync() async {
    if (!_enabled) return;
    final uid = AuthService.instance.uid;
    if (uid == null) return;

    final pending = _ledger.entries.where((e) => !e.value.synced).toList();
    if (pending.isEmpty) return;

    final auth = AuthService.instance;
    final user = _db!.collection('users').doc(uid);

    // Profile document: who this is, at the coarsest level. Rewritten on each
    // sync so a sign-in or an app update is reflected.
    final profile = <String, Object?>{
      'lastSeenAt': FieldValue.serverTimestamp(),
      'firstSeenAt': await _firstSeen(),
      'accountKind': auth.kind.name,
      'appVersion': _appVersion,
      'platform': defaultTargetPlatform.name,
    };
    // Identity is written only for an account the user deliberately created. An
    // anonymous document is a random id and a set of counters, with nothing in
    // it that could name a person.
    if (auth.kind == AccountKind.google) {
      profile['email'] = auth.email;
      profile['displayName'] = auth.displayName;
    }

    unawaited(
      user.set(profile, SetOptions(merge: true)).catchError((Object e) {
        debugPrint('Usage profile write failed: $e');
      }),
    );

    for (final entry in pending) {
      final date = entry.key;
      final day = entry.value;
      final data = <String, Object?>{
        'date': date,
        ...day.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      unawaited(
        user.collection('daily').doc(date).set(data, SetOptions(merge: true)).then(
          (_) {
            // Only now is it certainly on the server. Until this resolves the
            // day stays unsynced and will be offered again on the next flush —
            // harmless, because the write is an absolute total.
            _ledger[date]?.synced = true;
            unawaited(_saveLedger());
          },
        ).catchError((Object e) {
          debugPrint('Usage write for $date failed: $e');
        }),
      );
    }
  }

  /// Removes the server-side usage data.
  ///
  /// Must run **before** `AuthService.deleteAccount`: the rules only let a
  /// signed-in user delete their own data, and once the account is gone there is
  /// no longer a user to authorise it.
  Future<bool> deleteAccountData() async {
    if (!_enabled) return true;
    final uid = AuthService.instance.uid;
    if (uid == null) return true;
    try {
      final user = _db!.collection('users').doc(uid);
      // Deleting a document does not delete its subcollections, so the daily
      // records have to go explicitly or they survive as orphans.
      final daily = await user.collection('daily').get();
      for (final doc in daily.docs) {
        await doc.reference.delete();
      }
      await user.delete();
      _ledger.clear();
      await _saveLedger();
      return true;
    } catch (e) {
      debugPrint('Usage delete failed: $e');
      return false;
    }
  }

  Future<void> _log(String name) async {
    if (!_enabled) return;
    try {
      await _analytics!.logEvent(name: name);
    } catch (e) {
      debugPrint('Analytics event "$name" failed: $e');
    }
  }

  /// Install date, recorded locally on first run.
  ///
  /// Kept on the device rather than derived from the account, because signing
  /// out mints a new anonymous uid and a server-side `createdAt` would reset
  /// with it, making a long-standing user look brand new.
  Future<String> _firstSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_firstSeenKey);
    if (existing != null) return existing;
    final now = DateTime.now().toUtc().toIso8601String();
    await prefs.setString(_firstSeenKey, now);
    return now;
  }

  // ── Local ledger ────────────────────────────────────────────────────────

  static String _todayKey() => _keyFor(DateTime.now());

  /// Local dates, deliberately, not UTC. "How long did I use this on Tuesday"
  /// means the user's Tuesday; a UTC key would split their evening in two for
  /// anyone west of Greenwich.
  static String _keyFor(DateTime when) =>
      '${when.year.toString().padLeft(4, '0')}-'
      '${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')}';

  Future<void> _loadLedger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_ledgerKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _ledger.clear();
      decoded.forEach((date, value) {
        _ledger[date] = _Day.fromJson(value as Map<String, dynamic>);
      });
    } catch (e) {
      // A corrupt ledger costs some counts; refusing to start would cost the
      // app. Start clean.
      debugPrint('Could not restore usage ledger: $e');
      _ledger.clear();
    }
  }

  Future<void> _saveLedger() async {
    try {
      _prune();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _ledgerKey,
        jsonEncode(_ledger.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (e) {
      debugPrint('Could not save usage ledger: $e');
    }
  }

  /// Drops every day the server has confirmed.
  ///
  /// **The ledger is a queue, not an archive.** Once a day's figures are on the
  /// server there is no reason to keep a second copy in the user's storage, so
  /// it goes immediately. In steady use the ledger holds a single entry — today.
  ///
  /// Two things are deliberately kept. **Today**, because it is still
  /// accumulating and will be rewritten anyway; and **anything unsynced**,
  /// regardless of age, because those are precisely the days a long offline
  /// stretch produced and dropping them would throw away the data the ledger
  /// exists to protect.
  void _prune() {
    if (!_dropSyncedDays) return;
    final today = _todayKey();
    _ledger.removeWhere((date, day) => day.synced && date != today);
  }
}

/// One day's totals.
class _Day {
  int activeSeconds;
  int sessions;
  int messages;
  int journalEntries;
  int modelLoads;

  /// Whether the server has acknowledged this day's figures.
  bool synced;

  _Day({
    this.activeSeconds = 0,
    this.sessions = 0,
    this.messages = 0,
    this.journalEntries = 0,
    this.modelLoads = 0,
    this.synced = false,
  });

  /// What gets written to Firestore.
  ///
  /// Hours as well as seconds: the seconds are the precise figure, the hours are
  /// what anyone actually reads off a dashboard without dividing by 3600 in
  /// their head.
  Map<String, num> toMap() => {
        'activeSeconds': activeSeconds,
        'activeHours': double.parse((activeSeconds / 3600).toStringAsFixed(3)),
        'sessions': sessions,
        'messages': messages,
        'journalEntries': journalEntries,
        'modelLoads': modelLoads,
      };

  /// Short keys — this is written to prefs on every counted action, and the
  /// field names would otherwise be most of the payload.
  Map<String, dynamic> toJson() => {
        's': activeSeconds,
        'n': sessions,
        'm': messages,
        'j': journalEntries,
        'l': modelLoads,
        'y': synced,
      };

  factory _Day.fromJson(Map<String, dynamic> json) => _Day(
        activeSeconds: (json['s'] as num?)?.toInt() ?? 0,
        sessions: (json['n'] as num?)?.toInt() ?? 0,
        messages: (json['m'] as num?)?.toInt() ?? 0,
        journalEntries: (json['j'] as num?)?.toInt() ?? 0,
        modelLoads: (json['l'] as num?)?.toInt() ?? 0,
        synced: json['y'] as bool? ?? false,
      );
}
