import 'package:flutter/material.dart';

import '../../screens/model_setup_screen.dart';
import '../../services/auth_service.dart';
import '../../services/chat_store.dart';
import '../../services/consent.dart';
import '../../services/litert_service.dart';
import '../../services/local_profile.dart';
import '../../services/nudge_service.dart';
import '../../services/soundscape_controller.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';
import 'signin_dialog.dart';

/// "Sanctuary Controls" — profile, theme, and ambient sound.
///
/// The same content in every shell: 1a puts it in the left drawer, 1c in a
/// bottom sheet. Only [compact] differs, matching 1c's settings sheet, which
/// drops the "Not signed in." line under the guest card.
class SettingsPanel extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeChanged;

  /// Closes the containing drawer or sheet after signing in, as `doSignIn`
  /// does in the prototype.
  final VoidCallback? onDismiss;

  final bool compact;

  const SettingsPanel({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
    this.onDismiss,
    this.compact = false,
  });

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final LocalProfile _profile = LocalProfile.instance;
  final SoundscapeController _sound = SoundscapeController.instance;
  final NudgeService _nudges = NudgeService.instance;

  @override
  void initState() {
    super.initState();
    _profile.addListener(_refresh);
    _sound.addListener(_refresh);
    // The profile card shows the account's email, so it has to follow auth.
    AuthService.instance.addListener(_refresh);
    _profile.load();
    _checkModel();
    _nudges.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _profile.removeListener(_refresh);
    _sound.removeListener(_refresh);
    AuthService.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Assumed present until proven otherwise, so the "finish setting up" card
  /// does not flash into view for the overwhelming majority of users who
  /// already have a model.
  bool _modelInstalled = true;

  Future<void> _checkModel() async {
    final models = await LiteRtService().findLocalModels();
    if (mounted) setState(() => _modelInstalled = models.isNotEmpty);
  }

  Future<void> _openModelSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ModelSetupScreen(
          onReady: () => Navigator.of(context).maybePop(),
          onDefer: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
    await _checkModel();
  }

  Future<void> _openSignIn() async {
    final signedIn = await SignInDialog.show(context);
    if (signedIn == true) widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _profileCard(t),
        const SizedBox(height: Organic.space4),
        const OrganicSectionLabel('Aesthetic Palette'),
        const SizedBox(height: Organic.space2),
        OrganicSegmented<bool>(
          options: const [
            (value: false, label: 'Sunlit'),
            (value: true, label: 'Dusk'),
          ],
          selected: widget.isDark,
          onChanged: widget.onThemeChanged,
        ),
        const SizedBox(height: Organic.space4),
        const OrganicSectionLabel('Environment Resonance'),
        const SizedBox(height: Organic.space2),
        _resonanceTags(t),
        const SizedBox(height: Organic.space4),
        // Only appears when the model is missing. Once the companion is on the
        // device this is dead weight in a panel that already scrolls.
        if (!_modelInstalled) ...[
          const OrganicSectionLabel('Companion'),
          const SizedBox(height: Organic.space2),
          OrganicCard(
            children: [
              const OrganicCardTitle('Finish setting up', size: 13),
              const OrganicCardBody(
                'The companion has not been downloaded yet.',
              ),
              OrganicButton(
                label: 'Download the companion',
                variant: OrganicButtonVariant.secondary,
                fontSize: 11,
                block: true,
                onPressed: _openModelSetup,
              ),
            ],
          ),
          const SizedBox(height: Organic.space4),
        ],
        // "Companion Memory" (the What I Remember / Review & Forget card) and
        // "Check-ins" (the nudge toggle) used to sit here and were removed from
        // the UI deliberately — neither is presented as the user's decision.
        //
        // **Both subsystems are untouched and still running.** MemoryStore keeps
        // learning and MemoryPanel still exists; NudgeService still schedules
        // check-ins on its own settings. Only the controls are gone, so this is
        // a presentation change, not a behaviour change. `MemoryPanel.open` and
        // `NudgeService.setEnabled` are the entry points if either is ever
        // surfaced again.
        //
        // Note that turning off check-ins remains possible at the OS level:
        // Android's per-app notification settings still apply, which is the
        // control that actually matters for an app that messages people
        // unprompted.
        const OrganicSectionLabel('Conversation'),
        const SizedBox(height: Organic.space2),
        _conversationCard(t),
      ],
    );
  }

  Widget _conversationCard(SanctuaryTokens t) {
    return OrganicCard(
      children: [
        const OrganicCardTitle('Clear conversation', size: 13),
        // Was "…clear that from What I Remember", which pointed at a card that
        // no longer exists. It still says the two are separate, because the
        // surprising half of this action is what it does *not* erase.
        const OrganicCardBody(
          'Erases what is on screen. What I remember about you is kept '
          'separately and is not affected.',
        ),
        OrganicButton(
          label: 'Clear conversation',
          variant: OrganicButtonVariant.secondary,
          fontSize: 11,
          block: true,
          foreground: Organic.danger,
          onPressed: _confirmClearConversation,
        ),
      ],
    );
  }

  Future<void> _confirmClearConversation() async {
    final confirmed = await OrganicDialog.show<bool>(
      context,
      OrganicDialog(
        title: 'Clear the conversation?',
        body: 'Every message will be removed from this device and cannot be '
            'recovered. What I remember about you is not affected.',
        actions: [
          OrganicButton(
            label: 'Cancel',
            variant: OrganicButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          OrganicButton(
            label: 'Clear',
            variant: OrganicButtonVariant.secondary,
            foreground: Organic.danger,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) await ChatStore.instance.deleteAll();
  }

  Widget _profileCard(SanctuaryTokens t) {
    if (!_profile.signedIn) {
      return OrganicCard(
        children: [
          const OrganicCardTitle('Guest Companion', size: 13),
          if (!widget.compact) const OrganicCardBody('Not signed in.'),
          OrganicButton(
            label: 'Sign In',
            block: true,
            onPressed: _openSignIn,
          ),
        ],
      );
    }

    // The real address on the account, or nothing. Never a placeholder: this
    // line sits directly under the display name and reads as the account's
    // email, so inventing one is worse than leaving the space empty.
    final email = AuthService.instance.email;

    return OrganicCard(
      children: [
        OrganicCardTitle(_profile.name, size: 13),
        if (email != null)
          // `font-family: ui-monospace; font-size: 10px`
          Text(
            email,
            style: OrganicText.cardBody(t).copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Courier New', 'monospace'],
              fontSize: 10,
            ),
          ),
        // Hidden where an account is required, matching the account dialog.
        // On Android this used to clear the local name while leaving the
        // Firebase session signed in — two different ideas of "logged out" on
        // one screen, and the app would demand a sign-in it already had.
        if (!Consent.requiresAccount)
          OrganicButton(
            label: 'Logout Session',
            variant: OrganicButtonVariant.secondary,
            fontSize: 10,
            foreground: Organic.danger,
            onPressed: () async {
              // Both halves, so "logged out" means one thing.
              await AuthService.instance.signOut();
              await _profile.signOut();
            },
          ),
      ],
    );
  }

  /// Rain / Resonance / Temple Bells.
  ///
  /// Decorative in the prototype. Wired here to [SoundscapeController], because
  /// the app already has the audio and a tag that does nothing is worse than no
  /// tag. The active loop takes the sage `.tag-accent-2` treatment the
  /// prototype gives "Rain", so the selected state reads the same way.
  Widget _resonanceTags(SanctuaryTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Only the loops with a file in the bundle. The others stay
            // declared in the enum but out of sight until they ship.
            for (final scape in Soundscape.available)
              OrganicTag(
                label: scape.label,
                variant: _sound.active == scape
                    ? OrganicTagVariant.accent2
                    : OrganicTagVariant.neutral,
                onTap: () => _sound.toggle(scape),
              ),
          ],
        ),
        if (_sound.unavailable) ...[
          const SizedBox(height: Organic.space2),
          Text(
            'No ambient audio is bundled in this build.',
            style: OrganicText.cardMeta(t),
          ),
        ],
      ],
    );
  }
}
