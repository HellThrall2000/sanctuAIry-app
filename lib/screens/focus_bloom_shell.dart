import 'package:flutter/material.dart';

import '../models/journal_entry.dart';
import '../services/local_profile.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/organic/organic.dart';
import '../widgets/sanctuary/chat_view.dart';
import '../widgets/sanctuary/diary_panel.dart';
import '../widgets/sanctuary/settings_panel.dart';

/// Variation **1c — Focus Bloom**, the phone shell.
///
/// "A meditative, phone-shaped take: airy centered chat, no header chrome,
/// diary & settings open as rounded bottom sheets from a pill tab bar."
///
/// Reference geometry (420×680): content inset `bottom: 74px`; tab bar
/// `left/right: 16, bottom: 16, height: 58, radius: 29`; sheets 76% of the
/// card height with 28px top corners, sliding on `translateY` over 0.28s.
class FocusBloomShell extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeChanged;

  const FocusBloomShell({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
  });

  @override
  State<FocusBloomShell> createState() => _FocusBloomShellState();
}

enum _Sheet { diary, settings }

class _FocusBloomShellState extends State<FocusBloomShell> {
  _Sheet? _activeSheet;
  List<JournalEntry> _allowedJournals = const [];

  static const _tabBarHeight = 58.0;
  static const _tabBarInset = 16.0;

  void _closeSheet() => setState(() => _activeSheet = null);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The reference floats the tab bar 16px off the bottom of a 680px card. On
    // a real handset that would collide with the gesture bar, so the inset is
    // measured from the safe area instead.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final barBottom = _tabBarInset + bottomInset;
    final contentBottom = barBottom + _tabBarHeight;

    return Scaffold(
      backgroundColor: t.bgApp,
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final sheetHeight = constraints.maxHeight * 0.76;

          return Stack(
            children: [
              Positioned.fill(
                bottom: contentBottom,
                child: Column(
                  children: [
                    _brandBlock(t),
                    Expanded(
                      child: ChatView(
                        allowedJournals: _allowedJournals,
                        style: const ChatViewStyle.focusBloom(),
                      ),
                    ),
                  ],
                ),
              ),
              // Below the sheets on purpose. The prototype gives the sheets
              // `z-index: 10` and the tab bar none, so an open sheet covers it
              // and is dismissed with its × or the backdrop. Ordering it above
              // instead also looks broken: the pill and the sheet are both
              // `bgPanel`, so the bar dissolves into the sheet behind it.
              Positioned(
                left: _tabBarInset,
                right: _tabBarInset,
                bottom: barBottom,
                child: _tabBar(t),
              ),
              _backdrop(),
              _sheet(
                open: _activeSheet == _Sheet.diary,
                height: sheetHeight,
                title: 'Secure Journal Vault',
                child: DiaryPanel(
                  onAllowedEntriesChanged: (list) =>
                      setState(() => _allowedJournals = list),
                ),
              ),
              _sheet(
                open: _activeSheet == _Sheet.settings,
                height: sheetHeight,
                title: 'Settings',
                child: SettingsPanel(
                  isDark: widget.isDark,
                  onThemeChanged: widget.onThemeChanged,
                  onDismiss: _closeSheet,
                  compact: true,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Centred avatar, title and strapline — 1c's replacement for a header bar.
  Widget _brandBlock(SanctuaryTokens t) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            OrganicAvatar(
              initial: LocalProfile.instance.initial,
              size: 52,
              fontSize: 20,
            ),
            const SizedBox(height: 6),
            Text('Sanctuary', style: OrganicText.h4(t).copyWith(fontSize: 14)),
            const SizedBox(height: 6),
            Text(
              'PRIVATE COMPANION',
              style: OrganicText.strapline(t, size: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBar(SanctuaryTokens t) {
    Widget tab(String label, bool active, VoidCallback onTap) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(_tabBarHeight / 2),
          child: SizedBox(
            height: _tabBarHeight,
            child: Center(
              child: Text(
                label,
                style: OrganicText.navLabel(
                  active ? t.accentText : t.muted,
                  size: 12,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: t.bgPanel,
      borderRadius: BorderRadius.circular(_tabBarHeight / 2),
      clipBehavior: Clip.antiAlias,
      child: Container(
        height: _tabBarHeight,
        decoration: BoxDecoration(
          color: t.bgPanel,
          borderRadius: BorderRadius.circular(_tabBarHeight / 2),
          boxShadow: Organic.shadowMd,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            tab('Companion', _activeSheet == null, _closeSheet),
            tab(
              'Diary',
              _activeSheet == _Sheet.diary,
              () => setState(() => _activeSheet = _Sheet.diary),
            ),
            tab(
              'Settings',
              _activeSheet == _Sheet.settings,
              () => setState(() => _activeSheet = _Sheet.settings),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backdrop() {
    final open = _activeSheet != null;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedOpacity(
        opacity: open ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
          onTap: _closeSheet,
          child: Container(color: Organic.backdrop),
        ),
      ),
    );
  }

  Widget _sheet({
    required bool open,
    required double height,
    required String title,
    required Widget child,
  }) {
    final t = context.tokens;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 280),
      curve: Curves.ease,
      left: 0,
      right: 0,
      height: height,
      bottom: open ? 0 : -height,
      child: Container(
        decoration: BoxDecoration(
          color: t.bgPanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: Organic.shadowLg,
        ),
        padding: const EdgeInsets.all(20),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: OrganicSectionLabel(title)),
                  OrganicIconButton(
                    icon: Icons.close_rounded,
                    size: 24,
                    onPressed: _closeSheet,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(child: child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
