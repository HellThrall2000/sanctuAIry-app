import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// `.input` — a pill text field.
///
/// ```css
/// .input { min-height:36px; padding:6px 10px; font-size:14px;
///          background: var(--color-surface);
///          border:1px solid var(--color-divider); }
/// .input { border-radius: 999px; padding-inline: 14px; }
/// .input:hover  { border-color: text 45% }
/// .input:focus-visible { border-color: var(--color-accent) }
/// ```
///
/// Built on a bare [EditableText]-backed [TextField] with the Material
/// decoration stripped, because `InputDecoration` cannot produce a 1px border
/// that changes colour on hover without also bringing along its own padding
/// and 4px-radius assumptions.
class OrganicInput extends StatefulWidget {
  final TextEditingController controller;
  final String? hint;
  final bool obscureText;
  final TextAlign textAlign;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final int? maxLines;
  final int? minLines;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;

  /// Defaults to the theme's surface. Overridden where a field sits *inside* a
  /// surface-coloured card — the diary passcode uses `bgApp` so it recedes.
  final Color? fillColor;

  const OrganicInput({
    super.key,
    required this.controller,
    this.hint,
    this.obscureText = false,
    this.textAlign = TextAlign.start,
    this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
    this.focusNode,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.sentences,
    this.fillColor,
  });

  @override
  State<OrganicInput> createState() => _OrganicInputState();
}

class _OrganicInputState extends State<OrganicInput> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final borderColor = _focused
        ? t.accentBg
        : _hovered
            ? t.text.withValues(alpha: 0.45)
            : t.border;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        canRequestFocus: false,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          decoration: BoxDecoration(
            color: widget.fillColor ?? t.bgSurface,
            border: Border.all(color: borderColor),
            // A multi-line field cannot be a pill — the ends would swallow the
            // text. The prototype only ever uses single-line inputs.
            borderRadius: BorderRadius.circular(
              widget.maxLines == 1 ? Organic.radiusPill : Organic.radiusMd,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.center,
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
            obscureText: widget.obscureText,
            textAlign: widget.textAlign,
            maxLines: widget.maxLines,
            minLines: widget.minLines,
            textInputAction: widget.textInputAction,
            textCapitalization: widget.textCapitalization,
            onSubmitted: widget.onSubmitted,
            onChanged: widget.onChanged,
            cursorColor: t.accentBg,
            cursorWidth: 1.5,
            style: OrganicText.input(t),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: widget.hint,
              // `.sc-input::placeholder { color: inherit; opacity: .5 }`
              hintStyle: OrganicText.input(
                t,
                color: t.text.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.field` — a 12px label above an [OrganicInput].
class OrganicField extends StatelessWidget {
  final String label;
  final Widget child;

  const OrganicField({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          // `.field > label { margin-bottom: 5px }`
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(label, style: OrganicText.fieldLabel(context.tokens)),
        ),
        child,
      ],
    );
  }
}
