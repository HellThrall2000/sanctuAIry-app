import 'package:flutter/material.dart';

import '../../services/local_profile.dart';
import '../organic/organic.dart';

/// "Enter the Sanctuary" — the local profile dialog.
///
/// The design's own copy is the honest description of what this does:
/// *"Instant offline demo login — nothing leaves this device."* Blank fields
/// fall back to the prototype's placeholders. See [LocalProfile] for why this
/// is not called authentication.
///
/// 1a and 1b use a 440px dialog with a 20px title and the action label "Enter
/// Sandbox Session"; 1c narrows to 340px, drops the title to 17px and shortens
/// the action to "Enter".
class SignInDialog extends StatefulWidget {
  final bool compact;

  const SignInDialog({super.key, this.compact = false});

  /// Returns true when a profile was saved.
  static Future<bool?> show(BuildContext context, {bool compact = false}) {
    return OrganicDialog.show<bool>(context, SignInDialog(compact: compact));
  }

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;

    return OrganicDialog(
      title: 'Enter the Sanctuary',
      body: compact
          ? 'Instant offline demo login.'
          : 'Instant offline demo login — nothing leaves this device.',
      maxWidth: compact ? 340 : 440,
      titleSize: compact ? 17 : 20,
      bodySize: compact ? 12 : 14,
      children: [
        OrganicField(
          label: 'Display Name',
          child: OrganicInput(
            controller: _name,
            hint: LocalProfile.defaultName,
            textInputAction: TextInputAction.next,
          ),
        ),
        OrganicField(
          label: 'Email Address',
          child: OrganicInput(
            controller: _email,
            hint: LocalProfile.defaultEmail,
            textCapitalization: TextCapitalization.none,
            textInputAction: TextInputAction.done,
          ),
        ),
      ],
      actions: [
        OrganicButton(
          label: 'Cancel',
          variant: OrganicButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        OrganicButton(
          label: compact ? 'Enter' : 'Enter Sandbox Session',
          onPressed: () async {
            await LocalProfile.instance.signIn(
              name: _name.text,
              email: _email.text,
            );
            if (context.mounted) Navigator.of(context).pop(true);
          },
        ),
      ],
    );
  }
}
