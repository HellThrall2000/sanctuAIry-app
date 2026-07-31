import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/journal_entry.dart';
import '../../services/database_service.dart';
import '../../services/memory_store.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';

/// "Secure Journal Vault" — the passcode gate and the entry list behind it.
///
/// The prototype unlocks on any non-empty passcode and shows two fixed cards.
/// This keeps its shape exactly — centred lock card, entry cards with a
/// dateline, title and snippet — over the app's real vault: a SHA-256 passcode
/// in [SharedPreferences], entries in SQLite, and the per-entry AI-visibility
/// toggle that decides what the companion is allowed to read.
///
/// That toggle has no counterpart in the design and could not be dropped: it is
/// the user's only control over what a diary entry teaches the companion, and
/// `MemoryStore.syncJournal` erases derived facts the moment it is revoked.
class DiaryPanel extends StatefulWidget {
  final ValueChanged<List<JournalEntry>> onAllowedEntriesChanged;

  const DiaryPanel({super.key, required this.onAllowedEntriesChanged});

  @override
  State<DiaryPanel> createState() => _DiaryPanelState();
}

class _DiaryPanelState extends State<DiaryPanel> {
  static const _passcodeKey = 'sanctuary_diary_vault_code_hash';

  final DatabaseService _db = DatabaseService();
  final MemoryStore _memory = MemoryStore();
  final _uuid = const Uuid();
  final TextEditingController _passcodeController = TextEditingController();

  bool _unlocked = false;
  bool _hasPasscode = false;
  String _error = '';
  List<JournalEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _checkPasscode();
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    super.dispose();
  }

  String _hash(String code) => sha256.convert(utf8.encode(code)).toString();

  Future<void> _checkPasscode() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString(_passcodeKey);
    if (!mounted) return;
    setState(() => _hasPasscode = hash != null && hash.isNotEmpty);
  }

  Future<void> _submitPasscode() async {
    final code = _passcodeController.text;
    if (code.isEmpty) {
      setState(() => _error = 'Enter a passcode to continue.');
      return;
    }

    final prefs = await SharedPreferences.getInstance();

    if (!_hasPasscode) {
      await prefs.setString(_passcodeKey, _hash(code));
      if (!mounted) return;
      setState(() {
        _hasPasscode = true;
        _unlocked = true;
        _error = '';
      });
      _passcodeController.clear();
      await _loadEntries();
      return;
    }

    if (prefs.getString(_passcodeKey) == _hash(code)) {
      if (!mounted) return;
      setState(() {
        _unlocked = true;
        _error = '';
      });
      _passcodeController.clear();
      await _loadEntries();
    } else {
      if (!mounted) return;
      setState(() => _error = 'That passcode does not match.');
      _passcodeController.clear();
    }
  }

  Future<void> _loadEntries() async {
    final list = await _db.getEntries();
    if (!mounted) return;
    setState(() => _entries = list);
    widget.onAllowedEntriesChanged(
      list.where((e) => e.allowAiAccess).toList(),
    );
  }

  Future<void> _toggleAiAccess(JournalEntry entry) async {
    final updated = entry.copyWith(allowAiAccess: !entry.allowAiAccess);
    await _db.updateEntry(updated);
    // Takes effect now, in both directions: granting access extracts facts,
    // revoking it deletes them. Anything else would make the toggle a lie.
    await _memory.syncJournal(updated);
    await _loadEntries();
  }

  Future<void> _deleteEntry(JournalEntry entry) async {
    await _db.deleteEntry(entry.id);
    // Deleting the entry must delete what was learned from it, or the companion
    // would keep knowing something the user believes they erased.
    await _memory.forgetSource(entry.id);
    await _loadEntries();
  }

  Future<void> _composeEntry() async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    var share = true;

    final saved = await OrganicDialog.show<bool>(
      context,
      StatefulBuilder(
        builder: (context, setModalState) => OrganicDialog(
          title: 'New Entry',
          body: 'Written to this device only.',
          children: [
            OrganicField(
              label: 'Title',
              child: OrganicInput(
                controller: titleController,
                hint: 'A name for this entry',
              ),
            ),
            OrganicField(
              label: 'Entry',
              child: OrganicInput(
                controller: contentController,
                hint: 'What happened, and how it felt',
                maxLines: 6,
                minLines: 4,
              ),
            ),
            // The design has no control for this, but writing an entry is
            // exactly when the decision should be made, not afterwards.
            Row(
              children: [
                OrganicTag(
                  label: share ? 'Companion may read this' : 'Private to you',
                  variant: share
                      ? OrganicTagVariant.accent2
                      : OrganicTagVariant.neutral,
                  onTap: () => setModalState(() => share = !share),
                ),
              ],
            ),
          ],
          actions: [
            OrganicButton(
              label: 'Cancel',
              variant: OrganicButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            OrganicButton(
              label: 'Save Entry',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );

    if (saved != true) {
      titleController.dispose();
      contentController.dispose();
      return;
    }

    final title = titleController.text.trim();
    final content = contentController.text.trim();
    titleController.dispose();
    contentController.dispose();
    if (title.isEmpty || content.isEmpty) return;

    final entry = JournalEntry(
      id: _uuid.v4(),
      title: title,
      content: content,
      date: DateTime.now().toUtc().toIso8601String(),
      allowAiAccess: share,
    );
    await _db.insertEntry(entry);
    // Only extracts when the entry permits AI access; syncJournal enforces that
    // rather than trusting each call site to check.
    await _memory.syncJournal(entry);
    await _loadEntries();
  }

  @override
  Widget build(BuildContext context) {
    return _unlocked ? _entryList() : _lockCard();
  }

  Widget _lockCard() {
    final t = context.tokens;

    return OrganicCard(
      crossAxisAlignment: CrossAxisAlignment.center,
      // `.card { padding: 28px 16px }` on the lock state in 1a; 1c uses 24/14.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      children: [
        OrganicCardTitle(
          _hasPasscode ? 'Unlock Private Logs' : 'Set a Passcode',
          size: 15,
        ),
        Text(
          _hasPasscode
              ? 'Enter your passcode to read and write private notes.'
              : 'Choose a passcode. It is hashed on this device and never '
                  'leaves it — there is no way to recover it.',
          textAlign: TextAlign.center,
          style: OrganicText.cardBody(t),
        ),
        OrganicInput(
          controller: _passcodeController,
          hint: '••••',
          obscureText: true,
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.go,
          // The field sits inside a surface-coloured card, so it takes the page
          // background to stay distinguishable.
          fillColor: t.bgApp,
          onSubmitted: (_) => _submitPasscode(),
        ),
        if (_error.isNotEmpty)
          Text(
            _error,
            textAlign: TextAlign.center,
            style: OrganicText.cardMeta(t).copyWith(color: Organic.danger),
          ),
        OrganicButton(
          label: _hasPasscode ? 'Unlock Diary' : 'Create Passcode',
          block: true,
          onPressed: _submitPasscode,
        ),
      ],
    );
  }

  Widget _entryList() {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _entries.isEmpty
                    ? 'No entries yet'
                    : '${_entries.length} '
                        '${_entries.length == 1 ? "entry" : "entries"}',
                style: OrganicText.cardMeta(t),
              ),
            ),
            OrganicButton(
              label: 'New Entry',
              fontSize: 11,
              onPressed: _composeEntry,
            ),
          ],
        ),
        const SizedBox(height: Organic.space3),
        if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Organic.space6),
            child: Text(
              'Nothing written yet. Entries you keep here stay on this device.',
              textAlign: TextAlign.center,
              style: OrganicText.cardBody(t),
            ),
          )
        else
          for (final entry in _entries) ...[
            _entryCard(entry),
            const SizedBox(height: Organic.space3),
          ],
      ],
    );
  }

  Widget _entryCard(JournalEntry entry) {
    final date = DateTime.tryParse(entry.date)?.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final label =
        date == null ? '' : '${months[date.month - 1]} ${date.day}';

    return OrganicCard(
      children: [
        Row(
          children: [
            Expanded(child: OrganicCardMeta(label)),
            OrganicIconButton(
              icon: Icons.close_rounded,
              size: 22,
              tooltip: 'Delete entry',
              color: context.tokens.muted,
              onPressed: () => _deleteEntry(entry),
            ),
          ],
        ),
        OrganicCardTitle(entry.title, size: 14),
        OrganicCardBody(entry.content, maxLines: 3),
        Row(
          children: [
            OrganicTag(
              label: entry.allowAiAccess
                  ? 'Companion may read this'
                  : 'Private to you',
              variant: entry.allowAiAccess
                  ? OrganicTagVariant.accent2
                  : OrganicTagVariant.neutral,
              onTap: () => _toggleAiAccess(entry),
            ),
          ],
        ),
      ],
    );
  }
}
