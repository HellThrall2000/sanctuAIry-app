import 'package:flutter/material.dart';

import '../../services/chat_store.dart';
import '../../services/local_profile.dart';
import '../../services/nudge_service.dart';
import '../../services/soundscape_controller.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';
import 'memory_panel.dart';
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
    _profile.load();
    _nudges.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _profile.removeListener(_refresh);
    _sound.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
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
        // Not in the handoff, which has three destinations and no room for a
        // fourth. It is here because the companion builds a profile of the user
        // from chat and diary, and an app that promises nothing leaves the
        // device still owes them a way to see and delete what is on it.
        const OrganicSectionLabel('Companion Memory'),
        const SizedBox(height: Organic.space2),
        OrganicCard(
          children: [
            const OrganicCardTitle('What I Remember', size: 13),
            const OrganicCardBody(
              'Everything the companion has picked up, and where it learned it.',
            ),
            OrganicButton(
              label: 'Review & Forget',
              variant: OrganicButtonVariant.secondary,
              fontSize: 11,
              block: true,
              onPressed: () => MemoryPanel.open(context),
            ),
          ],
        ),
        const SizedBox(height: Organic.space4),
        const OrganicSectionLabel('Check-ins'),
        const SizedBox(height: Organic.space2),
        _checkInCard(t),
        const SizedBox(height: Organic.space4),
        const OrganicSectionLabel('Conversation'),
        const SizedBox(height: Organic.space2),
        _conversationCard(t),
      ],
    );
  }

  /// Whether the companion may reach out after a long silence.
  ///
  /// Given its own section rather than buried, and switchable in one tap. An
  /// app that messages people about their mental health has to make "stop"
  /// trivially easy to find.
  Widget _checkInCard(SanctuaryTokens t) {
    return OrganicCard(
      children: [
        const OrganicCardTitle('Reach out to me', size: 13),
        const OrganicCardBody(
          'If we have not spoken for a few hours, I may send one message — '
          'never more than one a day, and never overnight.',
        ),
        Row(
          children: [
            OrganicTag(
              label: _nudges.enabled ? 'On' : 'Off',
              variant: _nudges.enabled
                  ? OrganicTagVariant.accent2
                  : OrganicTagVariant.neutral,
              onTap: () async {
                await _nudges.setEnabled(!_nudges.enabled);
                if (_nudges.enabled) await _nudges.rearm();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _conversationCard(SanctuaryTokens t) {
    return OrganicCard(
      children: [
        const OrganicCardTitle('Clear conversation', size: 13),
        const OrganicCardBody(
          'Erases what is on screen. What I remember about you is kept '
          'separately — clear that from What I Remember.',
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

    return OrganicCard(
      children: [
        OrganicCardTitle(_profile.name, size: 13),
        // `font-family: ui-monospace; font-size: 10px`
        Text(
          _profile.email,
          style: OrganicText.cardBody(t).copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Courier New', 'monospace'],
            fontSize: 10,
          ),
        ),
        OrganicButton(
          label: 'Logout Session',
          variant: OrganicButtonVariant.secondary,
          fontSize: 10,
          foreground: Organic.danger,
          onPressed: () async {
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
            for (final scape in Soundscape.values)
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
