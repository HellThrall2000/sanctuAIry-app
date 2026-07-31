import 'package:flutter/material.dart';
import '../models/journal_entry.dart';
import '../main.dart';
import 'chat_screen.dart';
import 'journal_screen.dart';
import 'memory_screen.dart';
import 'soundscape_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<JournalEntry> _allowedJournals = [];

  void _handleAllowedEntriesChanged(List<JournalEntry> allowed) {
    setState(() {
      _allowedJournals = allowed;
    });
  }

  void _openSecureDiarySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return JournalScreen(
              onAllowedEntriesChanged: _handleAllowedEntriesChanged,
            );
          },
        );
      },
    );
  }

  void _openMemorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => const MemoryScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appState = SanctuaryApp.of(context);
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      drawer: _buildLeftDrawer(isDark, appState, primaryColor),
      appBar: AppBar(
        title: Column(
          children: [
            const Text(
              'Sanctuary',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
            Text(
              'PRIVATE COMPANION & DIARY LOCKBOX',
              style: TextStyle(
                fontSize: 7,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: isDark ? const Color(0xFF878F96) : const Color(0xFF786E63),
              ),
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu, size: 20),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          // Sits next to DIARY on purpose: what the companion remembers is as
          // much the user's private data as the diary is, and should be no
          // harder to reach.
          TextButton.icon(
            onPressed: _openMemorySheet,
            icon: const Icon(Icons.psychology_outlined, size: 14),
            label: const Text(
              'MEMORY',
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
            style: TextButton.styleFrom(foregroundColor: primaryColor),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: TextButton.icon(
              onPressed: _openSecureDiarySheet,
              icon: const Icon(Icons.book_outlined, size: 14),
              label: const Text(
                'DIARY',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              style: TextButton.styleFrom(
                foregroundColor: primaryColor,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Embedded Chat Companion Screen
            Expanded(
              child: ChatScreen(
                allowedJournals: _allowedJournals,
              ),
            ),
            
            // Footer Brand Indicator
            _buildAccessibilityFooter(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftDrawer(bool isDark, SanctuaryAppState appState, Color primaryColor) {
    return Drawer(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.explore_outlined, color: primaryColor, size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'SANCTUARY CONTROLS',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                      ),
                    ],
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  )
                ],
              ),
              const SizedBox(height: 24),

              // User Guest block
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: Colors.grey,
                          child: Icon(Icons.person, size: 16, color: Colors.white),
                        ),
                        SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Guest Explorer',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'CLIENT: ANONYMOUS',
                              style: TextStyle(fontSize: 7, color: Colors.grey, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    _buildLedgerLine('Encryption status:', 'ACTIVE', Colors.green),
                    const SizedBox(height: 6),
                    _buildLedgerLine('Local storage ledge:', 'LOCAL-ONLY', null),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Theme choice
              const Text(
                'AESTHETIC PALETTE',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        if (isDark) appState.toggleTheme();
                      },
                      icon: Icon(Icons.wb_sunny_outlined, size: 12, color: !isDark ? Colors.white : Colors.grey),
                      label: const Text('Zen Earth', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: !isDark ? primaryColor : Colors.transparent,
                        foregroundColor: !isDark ? Colors.white : Colors.grey,
                        side: BorderSide(color: !isDark ? primaryColor : Colors.grey.withOpacity(0.4)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        if (!isDark) appState.toggleTheme();
                      },
                      icon: Icon(Icons.nightlight_round_outlined, size: 12, color: isDark ? Colors.black : Colors.grey),
                      label: const Text('Steel Night', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: isDark ? primaryColor : Colors.transparent,
                        foregroundColor: isDark ? Colors.black : Colors.grey,
                        side: BorderSide(color: isDark ? primaryColor : Colors.grey.withOpacity(0.4)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Soundscapes Ambient
              const Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      SoundscapeWidget(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLedgerLine(String label, String value, Color? valColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 8.5, color: Colors.grey)),
        Text(
          value,
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.bold,
            color: valColor ?? Colors.grey[700],
          ),
        ),
      ],
    );
  }

  Widget _buildAccessibilityFooter(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
          ),
        ),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 10, color: Colors.grey),
              SizedBox(width: 4),
              Text(
                'Sovereign Local Sandbox — Offline Only',
                style: TextStyle(fontSize: 8, color: Colors.grey),
              ),
            ],
          ),
          Text(
            'PRIVACY SANCTUARY',
            style: TextStyle(fontSize: 8, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1),
          )
        ],
      ),
    );
  }
}
