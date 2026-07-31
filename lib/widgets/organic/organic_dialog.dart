import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.dialog` — a centred modal on a `--color-neutral-900` 50% scrim.
///
/// ```css
/// .dialog { width: min(440px, 100%); gap: var(--space-3);
///           padding: var(--space-4); box-shadow: var(--shadow-lg); }
/// .dialog, .card { border-radius: calc(var(--radius-lg) * 1.15); }
/// .dialog-actions { justify-content: flex-end; gap: var(--space-2);
///                   margin-top: var(--space-2); }
/// ```
///
/// 1a and 1b use the 440px width with a 20px title; 1c narrows to
/// `min(340px, 90%)` with a 17px title — hence [maxWidth] and [titleSize].
class OrganicDialog extends StatelessWidget {
  final String title;
  final String? body;
  final List<Widget> children;
  final List<Widget> actions;
  final double maxWidth;
  final double titleSize;
  final double bodySize;

  const OrganicDialog({
    super.key,
    required this.title,
    this.body,
    this.children = const [],
    this.actions = const [],
    this.maxWidth = 440,
    this.titleSize = 20,
    this.bodySize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      // `.dialog-backdrop { padding: var(--space-4) }`
      padding: const EdgeInsets.all(Organic.space4),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Material(
            color: t.bgSurface,
            borderRadius: BorderRadius.circular(Organic.radiusCard),
            child: Container(
              decoration: BoxDecoration(
                color: t.bgSurface,
                borderRadius: BorderRadius.circular(Organic.radiusCard),
                boxShadow: Organic.shadowLg,
              ),
              padding: const EdgeInsets.all(Organic.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: OrganicText.dialogTitle(t, size: titleSize),
                  ),
                  if (body != null) ...[
                    const SizedBox(height: Organic.space3),
                    Text(
                      body!,
                      style: OrganicText.dialogBody(t, size: bodySize),
                    ),
                  ],
                  for (final child in children) ...[
                    const SizedBox(height: Organic.space3),
                    child,
                  ],
                  if (actions.isNotEmpty) ...[
                    // `gap: space-3` between blocks, plus the actions row's own
                    // `margin-top: space-2`.
                    const SizedBox(height: Organic.space3 + Organic.space2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (var i = 0; i < actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: Organic.space2),
                          actions[i],
                        ],
                      ],
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

  /// Shows [dialog] over the Organic scrim.
  ///
  /// Uses [showGeneralDialog] rather than `showDialog` so the barrier colour
  /// and the fade duration are the prototype's rather than Material's.
  static Future<T?> show<T>(BuildContext context, Widget dialog) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Organic.dialogBackdrop,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => dialog,
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
  }
}
