import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/consent.dart';
import '../../services/local_profile.dart';
import '../../services/usage_metrics.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../google_sign_in_button.dart';
import '../organic/organic.dart';

/// The account dialog.
///
/// **This replaced a fake.** The prototype shipped an "Enter the Sanctuary"
/// dialog that took a name and an email and wrote them to `SharedPreferences` —
/// an offline demo login, honestly labelled as one. Now that there is real
/// authentication behind it, keeping both would have left the app with two
/// controls called "sign in" that mean different things. So this is the one
/// account surface, and [LocalProfile] is demoted to what it always actually
/// was: the name the companion calls you, which needs no account at all.
///
/// **This is not the gate.** First-run consent and any required sign-in happen
/// in [WelcomeScreen]; by the time anyone reaches this dialog they are already
/// through. What is left here is management — the name the companion uses,
/// signing out, and deleting the account.
///
/// "Sign out" is hidden where [Consent.requiresAccount] holds, which on Android
/// it does. There is nothing to sign out *to* on a platform that requires an
/// account, and offering a control that would immediately re-gate the app on
/// next launch would be a trap rather than a choice. Deleting the account stays
/// available on every platform, because that is a right rather than a
/// convenience.
class SignInDialog extends StatefulWidget {
  final bool compact;

  const SignInDialog({super.key, this.compact = false});

  static Future<bool?> show(BuildContext context, {bool compact = false}) {
    return OrganicDialog.show<bool>(context, SignInDialog(compact: compact));
  }

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  final _auth = AuthService.instance;
  late final TextEditingController _name;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: LocalProfile.instance.signedIn ? LocalProfile.instance.name : '',
    );
    _auth.addListener(_onAuth);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    _name.dispose();
    super.dispose();
  }

  void _onAuth() {
    if (mounted) setState(() {});
  }

  Future<void> _saveName() async {
    await LocalProfile.instance.signIn(name: _name.text);
  }

  Future<void> _google() async {
    setState(() => _error = null);
    final outcome = await _auth.signInWithGoogle();
    if (!mounted) return;

    if (outcome.succeeded) {
      UsageMetrics.instance.recordSignIn();
      // Adopt the Google name only when the user has not set one themselves —
      // someone who typed "Ravi" should not be renamed to "Ravi Sharma" by an
      // unrelated action.
      final display = _auth.displayName;
      if (display != null && !LocalProfile.instance.signedIn) {
        await LocalProfile.instance.signIn(name: display);
        if (mounted) _name.text = display;
      }
      if (mounted) setState(() {});
    } else if (!outcome.wasCancelled) {
      setState(() => _error = outcome.message);
    }
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final confirmed = await OrganicDialog.show<bool>(
      context,
      OrganicDialog(
        title: 'Delete your account?',
        body: 'This removes your account and the usage counts held against it '
            'on our server. Your conversations, diary and memories are on this '
            'phone and are not touched — to remove those, use "Forget '
            'everything" in settings.',
        maxWidth: 400,
        actions: [
          OrganicButton(
            label: 'Cancel',
            variant: OrganicButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          OrganicButton(
            label: 'Delete',
            foreground: Organic.danger,
            variant: OrganicButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Order matters: the security rules only let a signed-in user delete their
    // own document, so the data has to go before the account does.
    await UsageMetrics.instance.deleteAccountData();
    final ok = await _auth.deleteAccount();
    if (!mounted) return;
    setState(() {
      _error = ok
          ? null
          : 'Could not delete the account. Signing in again and retrying '
              'usually fixes it.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final compact = widget.compact;
    final signedIn = _auth.isSignedInWithGoogle;

    return OrganicDialog(
      title: signedIn ? 'Your account' : 'Your account',
      body: signedIn
          ? null
          : 'Your companion, your diary and every memory live on this phone. '
              'An account only tells us the app is being used.',
      maxWidth: compact ? 340 : 440,
      titleSize: compact ? 17 : 20,
      bodySize: compact ? 12 : 14,
      children: [
        OrganicField(
          label: 'What should the companion call you?',
          child: OrganicInput(
            controller: _name,
            hint: LocalProfile.defaultName,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveName(),
          ),
        ),
        const SizedBox(height: Organic.space3),
        if (signedIn)
          _SignedIn(email: _auth.email, name: _auth.displayName)
        else
          GoogleSignInButton(busy: _auth.isBusy, onPressed: _google),
        if (_error != null) ...[
          const SizedBox(height: Organic.space2),
          Text(
            _error!,
            style: OrganicText.body(t).copyWith(color: Organic.danger),
          ),
        ],
        const SizedBox(height: Organic.space3),
        Text(
          signedIn
              ? 'We hold your email, your display name and counts of how often '
                  'the app is opened. Never a message, a diary entry or '
                  'anything you have written.'
              : 'If you do sign in, we store your Google email and name, plus '
                  'counts of how often the app is opened. Never a message, a '
                  'diary entry or anything you have written.',
          style: OrganicText.muted(t).copyWith(fontSize: 12),
        ),
        if (signedIn) ...[
          const SizedBox(height: Organic.space3),
          Row(
            children: [
              if (!Consent.requiresAccount) ...[
                OrganicButton(
                  label: 'Sign out',
                  variant: OrganicButtonVariant.secondary,
                  fontSize: 12,
                  onPressed: _auth.isBusy ? null : _signOut,
                ),
                const SizedBox(width: Organic.space2),
              ],
              OrganicButton(
                label: 'Delete account',
                variant: OrganicButtonVariant.ghost,
                fontSize: 12,
                foreground: Organic.danger,
                onPressed: _auth.isBusy ? null : _delete,
              ),
            ],
          ),
        ],
      ],
      actions: [
        OrganicButton(
          label: compact ? 'Done' : 'Back to the sanctuary',
          onPressed: () async {
            await _saveName();
            if (context.mounted) Navigator.of(context).pop(true);
          },
        ),
      ],
    );
  }
}

class _SignedIn extends StatelessWidget {
  final String? email;
  final String? name;

  const _SignedIn({this.email, this.name});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(Organic.space3),
      decoration: BoxDecoration(
        color: t.bgApp,
        borderRadius: BorderRadius.circular(Organic.radiusMd),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: t.accentText),
          const SizedBox(width: Organic.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name ?? 'Signed in', style: OrganicText.body(t)),
                if (email != null)
                  Text(email!, style: OrganicText.muted(t).copyWith(
                        fontSize: 12,
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
