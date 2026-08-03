import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/consent.dart';
import '../services/firebase_gateway.dart';
import '../services/local_profile.dart';
import '../services/usage_metrics.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/google_sign_in_button.dart';
import '../widgets/organic/organic.dart';

/// The first screen: what the app does with your data, and the account.
///
/// **Four lines, not a wall.** Nobody reads a terms page, and a long one is a
/// way of not being understood while technically having disclosed. The promises
/// worth making here are short enough to actually land, so they are the whole
/// screen, and the full policy sits one tap away for anyone who wants it.
///
/// **The account is required on Android and optional on iOS** — see
/// [Consent.requiresAccount] for why the two platforms differ.
class WelcomeScreen extends StatefulWidget {
  /// Called once the terms are accepted and any required account exists.
  final VoidCallback onAccepted;

  const WelcomeScreen({super.key, required this.onAccepted});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _auth = AuthService.instance;
  bool _agreed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_refresh);
  }

  @override
  void dispose() {
    _auth.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Whether an account is genuinely required *right now*.
  ///
  /// Android requires one — but only when there is a Firebase project to make
  /// one against. Without `google-services.json` there is no sign-in that could
  /// possibly succeed, and a hard gate would mean nobody could open the app at
  /// all. A build with no backend falls through rather than locking the door on
  /// a key that does not exist.
  bool get _mustSignIn =>
      Consent.requiresAccount && FirebaseGateway.instance.isAvailable;

  Future<void> _continue({required bool withGoogle}) async {
    if (!_agreed) return;
    setState(() => _error = null);

    if (withGoogle) {
      final outcome = await _auth.signInWithGoogle();
      if (!mounted) return;
      if (!outcome.succeeded) {
        if (!outcome.wasCancelled) setState(() => _error = outcome.message);
        return;
      }
      UsageMetrics.instance.recordSignIn();

      // Adopt the Google display name as the name the companion uses.
      //
      // Without this, signing in *here* left LocalProfile empty while the
      // account dialog's path filled it — so the settings card greeted a
      // signed-in user as "Guest Companion" and offered them a sign-in button
      // they had already used. Only set when they have not chosen a name
      // themselves; someone who typed "Ravi" should not be renamed by this.
      final display = _auth.displayName;
      if (display != null && !LocalProfile.instance.signedIn) {
        await LocalProfile.instance.signIn(name: display);
      }
    }

    await Consent.accept();
    if (mounted) widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.bgApp,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Organic.space6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Arch(color: t.accentBg, surface: t.bgSurface),
                  const SizedBox(height: Organic.space6),
                  Text('sanctuAIry', style: OrganicText.h1(t)),
                  const SizedBox(height: Organic.space4),

                  const _Line('Your chats are never stored by us.'),
                  const _Line('The companion runs offline, on this phone.'),
                  const _Line(
                    'We only record how long the app is used, for analytics.',
                  ),
                  const _Line('No private data is kept on our servers.'),

                  const SizedBox(height: Organic.space6),
                  _checkbox(t),
                  const SizedBox(height: Organic.space4),

                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: OrganicText.body(t).copyWith(color: Organic.danger),
                    ),
                    const SizedBox(height: Organic.space3),
                  ],

                  Opacity(
                    opacity: _agreed ? 1 : 0.45,
                    child: IgnorePointer(
                      ignoring: !_agreed,
                      child: GoogleSignInButton(
                        busy: _auth.isBusy,
                        onPressed: () => _continue(withGoogle: true),
                      ),
                    ),
                  ),

                  // Only where an account is not required. On Android this is
                  // absent entirely rather than shown-and-disabled, which would
                  // just be advertising a door that does not open.
                  if (!_mustSignIn) ...[
                    const SizedBox(height: Organic.space2),
                    Center(
                      child: OrganicButton(
                        label: 'Continue without an account',
                        variant: OrganicButtonVariant.ghost,
                        fontSize: 13,
                        onPressed: _agreed
                            ? () => _continue(withGoogle: false)
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _checkbox(SanctuaryTokens t) {
    return InkWell(
      onTap: () => setState(() => _agreed = !_agreed),
      borderRadius: BorderRadius.circular(Organic.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Organic.space1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _agreed,
              activeColor: t.accentBg,
              onChanged: (v) => setState(() => _agreed = v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('I agree to the ', style: OrganicText.body(t)),
                    GestureDetector(
                      onTap: () => _TermsDialog.show(context),
                      child: Text(
                        'Terms and Privacy Policy',
                        style: OrganicText.body(t).copyWith(
                          color: t.accentText,
                          decoration: TextDecoration.underline,
                          decorationColor: t.accentText,
                        ),
                      ),
                    ),
                    Text('.', style: OrganicText.body(t)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One promise, with a tick.
class _Line extends StatelessWidget {
  final String text;

  const _Line(this.text);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: Organic.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(Icons.check, size: 17, color: t.accentText),
          ),
          const SizedBox(width: Organic.space2),
          Expanded(child: Text(text, style: OrganicText.body(t))),
        ],
      ),
    );
  }
}

/// The full terms, held in the app rather than behind a link.
///
/// A privacy policy you can only read by going online is the wrong shape for an
/// app whose entire claim is that it does not need to.
class _TermsDialog extends StatelessWidget {
  const _TermsDialog();

  static Future<void> show(BuildContext context) =>
      OrganicDialog.show<void>(context, const _TermsDialog());

  @override
  Widget build(BuildContext context) {
    return OrganicDialog(
      title: 'Terms and Privacy',
      maxWidth: 480,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Section(
                  'What stays on your phone',
                  'Every message you send the companion and every reply, all '
                      'your diary entries, everything the companion remembers '
                      'about you, and your passcode. None of it is uploaded. '
                      'Uninstalling the app deletes all of it.',
                ),
                _Section(
                  'The companion runs here',
                  'Your messages are not sent to any AI service for '
                      'processing. The model runs on this device, which is why '
                      'it has to be downloaded once.',
                ),
                _Section(
                  'What we collect',
                  'How often and how long the app is used, and counts of '
                      'messages and diary entries — the numbers only, never '
                      'the content. If you sign in, your Google email and '
                      'display name.',
                ),
                _Section(
                  'What we never collect',
                  'The text of your messages or diary, anything the companion '
                      'has remembered, your mood, your health information, '
                      'your contacts, photos, files or location.',
                ),
                _Section(
                  'Your control',
                  'You can delete your account and its usage record at any '
                      'time from Settings. You can delete what the companion '
                      'knows about you from Settings, Companion Memory.',
                ),
                _Section(
                  'Not a medical service',
                  'sanctuAIry is a journalling and reflection companion. It '
                      'is not therapy, does not give medical advice, and is '
                      'not a crisis service. In a crisis, please contact your '
                      'local emergency number.',
                ),
              ],
            ),
          ),
        ),
      ],
      actions: [
        OrganicButton(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;

  const _Section(this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: Organic.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: OrganicText.h5(t)),
          const SizedBox(height: Organic.space1),
          Text(body, style: OrganicText.body(t)),
        ],
      ),
    );
  }
}

/// The app mark, drawn rather than shipped as an asset so it follows the theme.
class _Arch extends StatelessWidget {
  final Color color;
  final Color surface;

  const _Arch({required this.color, required this.surface});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Organic.radiusLg),
      ),
      child: Center(
        child: Container(
          width: 27,
          height: 38,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
        ),
      ),
    );
  }
}
