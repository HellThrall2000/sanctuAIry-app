import 'package:flutter/material.dart';

import '../models/journal_entry.dart';
import '../services/local_profile.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/organic/organic.dart';
import '../widgets/sanctuary/chat_view.dart';
import '../widgets/sanctuary/diary_panel.dart';
import '../widgets/sanctuary/settings_panel.dart';
import '../widgets/sanctuary/signin_dialog.dart';

/// Variation **1a — Warm Companion**, the wide shell.
///
/// "Same shell as the original: header, centered chat, side drawers for
/// settings & diary."
///
/// Reference geometry (960×640): 66px header on the panel colour with a bottom
/// rule; a 270px settings drawer sliding in from the left and a 320px diary
/// drawer from the right, both on `translateX` over 0.25s, sharing a
/// click-to-dismiss backdrop.
class WarmCompanionShell extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeChanged;

  const WarmCompanionShell({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
  });

  @override
  State<WarmCompanionShell> createState() => _WarmCompanionShellState();
}

class _WarmCompanionShellState extends State<WarmCompanionShell> {
  bool _leftOpen = false;
  bool _rightOpen = false;
  List<JournalEntry> _allowedJournals = const [];

  final LocalProfile _profile = LocalProfile.instance;

  static const _leftWidth = 270.0;
  static const _rightWidth = 320.0;
  static const _headerHeight = 66.0;

  @override
  void initState() {
    super.initState();
    _profile.addListener(_refresh);
    _profile.load();
  }

  @override
  void dispose() {
    _profile.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _closeAll() => setState(() {
        _leftOpen = false;
        _rightOpen = false;
      });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.bgApp,
      body: Stack(
        children: [
          Column(
            children: [
              _header(t),
              Expanded(
                child: ChatView(
                  allowedJournals: _allowedJournals,
                  style: const ChatViewStyle.warmCompanion(),
                ),
              ),
            ],
          ),
          _backdrop(),
          _drawer(
            side: _DrawerSide.left,
            open: _leftOpen,
            width: _leftWidth,
            title: 'Sanctuary Controls',
            onClose: () => setState(() => _leftOpen = false),
            child: SettingsPanel(
              isDark: widget.isDark,
              onThemeChanged: widget.onThemeChanged,
              onDismiss: () => setState(() => _leftOpen = false),
            ),
          ),
          _drawer(
            side: _DrawerSide.right,
            open: _rightOpen,
            width: _rightWidth,
            title: 'Secure Journal Vault',
            onClose: () => setState(() => _rightOpen = false),
            child: DiaryPanel(
              onAllowedEntriesChanged: (list) =>
                  setState(() => _allowedJournals = list),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(SanctuaryTokens t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bgPanel,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: _headerHeight,
          child: Padding(
            // `padding: 16px 22px`
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: [
                OrganicIconButton(
                  bordered: true,
                  tooltip: 'Open Sanctuary Controls',
                  onPressed: () => setState(() => _leftOpen = true),
                  child: OrganicMenuDots(color: t.text),
                ),
                const SizedBox(width: 12),
                const OrganicAvatar(initial: 'S', size: 34),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'sanctuAIry',
                        style: OrganicText.h4(t).copyWith(fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'PRIVATE COMPANION & DIARY',
                        overflow: TextOverflow.ellipsis,
                        style: OrganicText.strapline(t),
                      ),
                    ],
                  ),
                ),
                // `justify-content: space-between` — the brand group sits left,
                // the diary and account controls at the far right.
                const Spacer(),
                const SizedBox(width: 12),
                OrganicButton(
                  label: 'Open Diary',
                  variant: OrganicButtonVariant.secondary,
                  fontSize: 11,
                  onPressed: () => setState(() => _rightOpen = true),
                ),
                const SizedBox(width: 8),
                if (_profile.signedIn)
                  OrganicAvatar(
                    initial: _profile.initial,
                    size: 32,
                    fontSize: 11,
                  )
                else
                  OrganicButton(
                    label: 'Sign In',
                    variant: OrganicButtonVariant.ghost,
                    fontSize: 11,
                    onPressed: () => SignInDialog.show(context),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _backdrop() {
    final open = _leftOpen || _rightOpen;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedOpacity(
        opacity: open ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
          onTap: _closeAll,
          child: Container(color: Organic.backdrop),
        ),
      ),
    );
  }

  Widget _drawer({
    required _DrawerSide side,
    required bool open,
    required double width,
    required String title,
    required VoidCallback onClose,
    required Widget child,
  }) {
    final t = context.tokens;
    final isLeft = side == _DrawerSide.left;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.ease,
      top: 0,
      bottom: 0,
      width: width,
      left: isLeft ? (open ? 0 : -width) : null,
      right: isLeft ? null : (open ? 0 : -width),
      child: Container(
        decoration: BoxDecoration(
          color: t.bgPanel,
          border: Border(
            right: isLeft ? BorderSide(color: t.border) : BorderSide.none,
            left: isLeft ? BorderSide.none : BorderSide(color: t.border),
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: OrganicSectionLabel(title)),
                  OrganicIconButton(
                    icon: Icons.close_rounded,
                    size: 24,
                    onPressed: onClose,
                  ),
                ],
              ),
              // `gap: 18px` in the left drawer, `16px` in the right.
              SizedBox(height: isLeft ? 18 : 16),
              Expanded(child: SingleChildScrollView(child: child)),
            ],
          ),
        ),
      ),
    );
  }
}

enum _DrawerSide { left, right }
