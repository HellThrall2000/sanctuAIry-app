import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'auth_service.dart';
import 'firebase_gateway.dart';

/// Why a user flagged a companion reply.
enum ReportReason {
  harmful('Harmful or unsafe'),
  offensive('Offensive or inappropriate'),
  inaccurate('Wrong or misleading');

  final String label;
  const ReportReason(this.label);
}

/// Sends a user's report about one companion reply.
///
/// **Required by Google Play.** The AI-Generated Content policy obliges any app
/// that generates content with AI to let users report or flag offensive output
/// *without leaving the app*. A `mailto:` link would leave the app, so reports go
/// to Firestore, which is already here for usage counting.
///
/// **This is the one path where text leaves the device, and only because the
/// user asked.** It carries the reported reply — the model's words, never the
/// user's — plus a reason and the app version. No uid, no email, no preceding
/// messages: a report has to be readable by whoever reviews it, and nothing about
/// who sent it is needed for that. Because it names nobody, deleting an account
/// has nothing here to remove. Keep that true; `firebase/firestore.rules`
/// enforces the same field allowlist.
class ContentReports {
  static final ContentReports instance = ContentReports._();

  ContentReports._();

  /// Matches the cap in `firebase/firestore.rules`.
  static const int maxReplyChars = 4000;

  /// Whether a report can be sent at all from this build.
  ///
  /// False with no Firebase (a build without `google-services.json`) or no
  /// signed-in user — the rules refuse unauthenticated writes.
  bool get isAvailable =>
      FirebaseGateway.instance.isAvailable && AuthService.instance.uid != null;

  /// Queues the report. Returns false only if it could not even be queued.
  ///
  /// Not awaited to completion: Firestore resolves a write when the server
  /// acknowledges it, which offline may be days away. The write sits in
  /// Firestore's on-disk queue until then, so "queued" is the honest thing to
  /// tell the user.
  Future<bool> submit({
    required String reply,
    required ReportReason reason,
    String? modelProfileId,
  }) async {
    if (!isAvailable) return false;

    var appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Non-fatal; the reply and reason are what matter.
    }

    try {
      final text = reply.length > maxReplyChars
          ? reply.substring(0, maxReplyChars)
          : reply;
      unawaited(
        FirebaseFirestore.instance.collection('reports').add({
          'reason': reason.name,
          'reply': text,
          'modelProfile': modelProfileId ?? 'unknown',
          'appVersion': appVersion,
          'platform': defaultTargetPlatform.name,
          'createdAt': FieldValue.serverTimestamp(),
        }).then(
          (_) {},
          onError: (Object e) => debugPrint('Content report write failed: $e'),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Content report unavailable: $e');
      return false;
    }
  }
}
