import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase_gateway.dart';

/// How the current account was established.
enum AccountKind {
  /// No Firebase at all — no config, offline first run, or provider disabled.
  /// Everything in the app still works; nothing is counted.
  none,

  /// A Firebase anonymous account. A random id and nothing else: no email, no
  /// name, no way to tie it to a person. This is the default, and for most
  /// users it is also the end state.
  anonymous,

  /// The user chose to sign in with Google, so the account now carries their
  /// Google email and display name.
  google,
}

/// Accounts for sanctuAIry.
///
/// **Anonymous by default, Google only if asked.** The app opens straight into
/// the sanctuary on an anonymous account. Nothing is gated behind signing in,
/// because nothing here needs to be: the model, the diary and every memory live
/// on the device, and an account buys the user no capability at all. It exists
/// so the people shipping the app can count installs and usage.
///
/// Two reasons it is built this way rather than as a launch-time gate:
///
/// - **It counts everyone.** A gate only ever measures the people who agreed to
///   it. Anonymous-by-default means the install figures cover 100% of users
///   instead of the self-selecting subset willing to hand over a Google account
///   to write in a journal.
/// - **Apple would reject the gate.** App Store guideline 5.1.1(v) forbids
///   requiring account creation when the app's core features do not depend on
///   it. An offline journal that demands a Google login is the example in the
///   rule. Play would allow it; the iOS port would not survive it.
///
/// **Signing in preserves the account, it does not replace it.** Upgrading goes
/// through `linkWithCredential`, so the anonymous uid — and every usage counter
/// already attached to it — survives. A plain `signInWithCredential` would mint
/// a new uid and silently orphan the old document, which is how a user becomes
/// two users in the numbers.
class AuthService extends ChangeNotifier {
  static final AuthService instance = AuthService._();

  AuthService._();

  /// The Web OAuth client id used to request an idToken on Android.
  ///
  /// Normally null: the google-services Gradle plugin turns the `client_type: 3`
  /// entry of google-services.json into `R.string.default_web_client_id`, and
  /// google_sign_in_android picks that up on its own. Set it only if you are
  /// deliberately using a client that is not the one in that file.
  static String? serverClientId;

  FirebaseAuth? _auth;
  StreamSubscription<User?>? _authSub;

  User? _user;
  AccountKind _kind = AccountKind.none;
  bool _busy = false;
  bool _initialized = false;

  User? get user => _user;

  AccountKind get kind => _kind;

  /// True while a sign-in, sign-out or delete is in flight.
  bool get isBusy => _busy;

  /// Stable id for the account, or null when there is no Firebase.
  /// This is what usage documents are keyed on.
  String? get uid => _user?.uid;

  /// The Google email, or null on an anonymous account.
  String? get email => _kind == AccountKind.google ? _user?.email : null;

  /// The Google display name, or null on an anonymous account.
  String? get displayName =>
      _kind == AccountKind.google ? _user?.displayName : null;

  String? get photoUrl => _kind == AccountKind.google ? _user?.photoURL : null;

  bool get isSignedInWithGoogle => _kind == AccountKind.google;

  /// Establishes an account, creating an anonymous one if there is none.
  ///
  /// Never throws. A failure leaves [kind] as [AccountKind.none] and the app
  /// entirely functional, just uncounted.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (!await FirebaseGateway.instance.init()) return;

    try {
      final auth = FirebaseAuth.instance;
      _auth = auth;

      // Watch rather than read once: a token refresh, a revoked account or a
      // sign-in on the account screen all land here, and the UI follows.
      _authSub = auth.authStateChanges().listen((user) {
        _user = user;
        _kind = _classify(user);
        notifyListeners();
      });

      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
      _user = auth.currentUser;
      _kind = _classify(_user);

      await _initGoogle();
      notifyListeners();
    } catch (e) {
      // `operation-not-allowed` means Anonymous sign-in is switched off in the
      // Firebase console — the single most common setup mistake here, so name it
      // rather than leaving a bare code in the log.
      if (e is FirebaseAuthException && e.code == 'operation-not-allowed') {
        debugPrint(
          'Anonymous sign-in is disabled for this Firebase project. Enable it '
          'under Authentication > Sign-in method, or usage will go uncounted. '
          'The app is unaffected.',
        );
      } else {
        debugPrint('Auth init failed, continuing without an account: $e');
      }
      _kind = AccountKind.none;
    }
  }

  static AccountKind _classify(User? user) {
    if (user == null) return AccountKind.none;
    final linked =
        user.providerData.any((p) => p.providerId == 'google.com');
    return linked ? AccountKind.google : AccountKind.anonymous;
  }

  bool _googleReady = false;

  Future<void> _initGoogle() async {
    if (_googleReady) return;
    try {
      await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
      _googleReady = true;
    } catch (e) {
      debugPrint('Google sign-in unavailable: $e');
    }
  }

  /// Upgrades the current anonymous account to a Google one.
  ///
  /// Returns an [AuthOutcome] rather than throwing, because every failure mode
  /// here is something the UI has to say out loud in plain words — cancelled,
  /// offline, or already-signed-in-elsewhere.
  Future<AuthOutcome> signInWithGoogle() async {
    if (!FirebaseGateway.instance.isAvailable || _auth == null) {
      return const AuthOutcome.failed(
        'Accounts are not set up in this build. Everything else works.',
      );
    }
    if (_busy) return const AuthOutcome.failed('Already signing in.');

    _setBusy(true);
    try {
      await _initGoogle();

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return const AuthOutcome.failed(
          'Google sign-in is not supported on this device.',
        );
      }

      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        // Almost always a missing Web OAuth client: without `client_type: 3` in
        // google-services.json there is no default_web_client_id and Google
        // returns an account with no idToken to exchange.
        return const AuthOutcome.failed(
          'Google did not return a sign-in token. The Firebase project is '
          'missing its Web OAuth client.',
        );
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final current = _auth!.currentUser;

      if (current != null && current.isAnonymous) {
        try {
          // The good path: same uid, same counters, now with a Google identity.
          await current.linkWithCredential(credential);
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use' ||
              e.code == 'email-already-in-use') {
            // This Google account already has an account here, from another
            // device or a reinstall. Theirs wins; the throwaway anonymous uid
            // created moments ago on this device is abandoned.
            await _auth!.signInWithCredential(credential);
          } else {
            rethrow;
          }
        }
      } else {
        await _auth!.signInWithCredential(credential);
      }

      _user = _auth!.currentUser;
      _kind = _classify(_user);
      notifyListeners();
      return const AuthOutcome.ok();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const AuthOutcome.cancelled();
      }
      debugPrint('Google sign-in failed: $e');
      return AuthOutcome.failed(_readable(e.code.name));
    } on FirebaseAuthException catch (e) {
      debugPrint('Firebase sign-in failed: ${e.code}');
      return AuthOutcome.failed(_readable(e.code));
    } catch (e) {
      debugPrint('Sign-in failed: $e');
      return const AuthOutcome.failed('Could not sign in. Please try again.');
    } finally {
      _setBusy(false);
    }
  }

  /// Signs out of Google and returns to a fresh anonymous account.
  ///
  /// Deliberately not a no-account state: the app would otherwise stop counting
  /// a user who is still using it. Nothing on the device is touched — the diary,
  /// the conversation and every memory are local and survive this untouched.
  Future<void> signOut() async {
    if (_auth == null || _busy) return;
    _setBusy(true);
    try {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (e) {
        debugPrint('Google sign-out failed (continuing): $e');
      }
      await _auth!.signOut();
      await _auth!.signInAnonymously();
      _user = _auth!.currentUser;
      _kind = _classify(_user);
      notifyListeners();
    } catch (e) {
      debugPrint('Sign-out failed: $e');
    } finally {
      _setBusy(false);
    }
  }

  /// Deletes the account and everything held against it on the server.
  ///
  /// The caller is responsible for removing the Firestore usage document first —
  /// once the user is gone, the security rules no longer authorise the delete.
  /// See `UsageMetrics.deleteAccountData`.
  ///
  /// Returns false when Firebase requires a fresh sign-in before it will allow
  /// this, which it does for accounts that have not authenticated recently.
  Future<bool> deleteAccount() async {
    final user = _auth?.currentUser;
    if (user == null || _busy) return false;
    _setBusy(true);
    try {
      await user.delete();
      try {
        await GoogleSignIn.instance.disconnect();
      } catch (_) {
        // Nothing to revoke on an anonymous account.
      }
      await _auth!.signInAnonymously();
      _user = _auth!.currentUser;
      _kind = _classify(_user);
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        debugPrint('Delete needs a fresh sign-in.');
        return false;
      }
      debugPrint('Account delete failed: ${e.code}');
      return false;
    } catch (e) {
      debugPrint('Account delete failed: $e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  static String _readable(String code) {
    switch (code) {
      case 'network-request-failed':
      case 'networkError':
        return 'No connection. Sign-in needs the internet — the rest of the '
            'app does not.';
      case 'account-exists-with-different-credential':
        return 'That email is already registered with a different sign-in '
            'method.';
      case 'invalid-credential':
        return 'Google sign-in was rejected. Please try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      default:
        return 'Could not sign in. Please try again.';
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}

/// The result of a sign-in attempt, in terms the UI can show directly.
class AuthOutcome {
  final bool succeeded;
  final bool wasCancelled;
  final String? message;

  const AuthOutcome.ok()
      : succeeded = true,
        wasCancelled = false,
        message = null;

  /// The user backed out. Not an error, and never worth a red banner.
  const AuthOutcome.cancelled()
      : succeeded = false,
        wasCancelled = true,
        message = null;

  const AuthOutcome.failed(String this.message)
      : succeeded = false,
        wasCancelled = false;
}
