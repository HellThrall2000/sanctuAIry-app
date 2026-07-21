import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/journal_entry.dart';
import '../services/database_service.dart';

class JournalScreen extends StatefulWidget {
  final Function(List<JournalEntry>) onAllowedEntriesChanged;

  const JournalScreen({Key? key, required this.onAllowedEntriesChanged}) : super(key: key);

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  final DatabaseService _dbService = DatabaseService();
  final _uuid = const Uuid();

  bool _isUnlocked = false;
  bool _hasPasscodeSet = false;
  String _enteredCode = "";
  String _passcodeError = "";

  List<JournalEntry> _entries = [];
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  bool _allowAiAccess = true;

  @override
  void initState() {
    super.initState();
    _checkPasscodeStatus();
  }

  Future<void> _checkPasscodeStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString('sanctuary_diary_vault_code_hash');
    setState(() {
      _hasPasscodeSet = hash != null && hash.isNotEmpty;
    });
  }

  String _hashPasscode(String code) {
    final bytes = utf8.encode(code);
    return sha256.convert(bytes).toString();
  }

  Future<void> _savePasscode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = _hashPasscode(code);
    await prefs.setString('sanctuary_diary_vault_code_hash', hash);
    setState(() {
      _hasPasscodeSet = true;
      _isUnlocked = true;
      _passcodeError = "";
    });
    _loadEntries();
  }

  Future<void> _unlockVault(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final savedHash = prefs.getString('sanctuary_diary_vault_code_hash');
    final enteredHash = _hashPasscode(code);

    if (savedHash == enteredHash) {
      setState(() {
        _isUnlocked = true;
        _passcodeError = "";
        _enteredCode = "";
      });
      _loadEntries();
    } else {
      setState(() {
        _passcodeError = "Incorrect passcode. Please try again.";
        _enteredCode = "";
      });
    }
  }

  Future<void> _loadEntries() async {
    final list = await _dbService.getEntries();
    setState(() {
      _entries = list;
    });
    _propagateAllowedEntries(list);
  }

  void _propagateAllowedEntries(List<JournalEntry> list) {
    final allowed = list.where((e) => e.allowAiAccess).toList();
    widget.onAllowedEntriesChanged(allowed);
  }

  Future<void> _addEntry() async {
    if (_titleController.text.trim().isEmpty || _contentController.text.trim().isEmpty) {
      return;
    }

    final newEntry = JournalEntry(
      id: _uuid.v4(),
      title: _titleController.text.trim(),
      content: _contentController.text.trim(),
      date: DateTime.now().toUtc().toIso8601String(),
      allowAiAccess: _allowAiAccess,
    );

    await _dbService.insertEntry(newEntry);
    _titleController.clear();
    _contentController.clear();
    _loadEntries();
  }

  Future<void> _deleteEntry(String id) async {
    await _dbService.deleteEntry(id);
    _loadEntries();
  }

  Future<void> _toggleAiAccess(JournalEntry entry) async {
    final updated = entry.copyWith(allowAiAccess: !entry.allowAiAccess);
    await _dbService.updateEntry(updated);
    _loadEntries();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1A1D20) : const Color(0xFFFAF8F5);
    final accentColor = isDark ? const Color(0xFFA3B1BC) : const Color(0xFF536250);

    if (!_isUnlocked) {
      return _buildLockScreen(isDark, accentColor);
    }

    return _buildJournalPanel(isDark, cardBg, accentColor);
  }

  Widget _buildLockScreen(bool isDark, Color accentColor) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1A1D20) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                  ),
                ),
                child: Icon(
                  Icons.lock_outline,
                  color: accentColor,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _hasPasscodeSet ? 'ENTER DIARY PASSCODE' : 'SET NEW DIARY PASSCODE',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _hasPasscodeSet 
                    ? 'Enter your PIN to decrypt local journal vaults'
                    : 'Create a 4-to-6 digit secure PIN code',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              
              // Code Indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (index) {
                  final active = index < _enteredCode.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? accentColor : Colors.transparent,
                      border: Border.all(
                        color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
              if (_passcodeError.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  _passcodeError,
                  style: const TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
              const SizedBox(height: 32),
              
              // Custom Numeric Keypad
              SizedBox(
                width: 240,
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 1.2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    if (index == 9) {
                      return IconButton(
                        onPressed: () {
                          if (_enteredCode.isNotEmpty) {
                            setState(() {
                              _enteredCode = _enteredCode.substring(0, _enteredCode.length - 1);
                            });
                          }
                        },
                        icon: const Icon(Icons.backspace_outlined, size: 18),
                      );
                    }
                    if (index == 11) {
                      return IconButton(
                        onPressed: () {
                          if (_enteredCode.length >= 4) {
                            if (_hasPasscodeSet) {
                              _unlockVault(_enteredCode);
                            } else {
                              _savePasscode(_enteredCode);
                            }
                          } else {
                            setState(() {
                              _passcodeError = "PIN must be at least 4 digits";
                            });
                          }
                        },
                        icon: Icon(Icons.check_circle_outline, color: accentColor, size: 24),
                      );
                    }
                    final number = index == 10 ? 0 : index + 1;
                    return GestureDetector(
                      onTap: () {
                        if (_enteredCode.length < 6) {
                          setState(() {
                            _enteredCode += number.toString();
                            _passcodeError = "";
                          });
                        }
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF111315) : const Color(0xFFFAF8F5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            number.toString(),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJournalPanel(bool isDark, Color cardBg, Color accentColor) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('SECURE DIARY LOCKBOX', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _isUnlocked = false;
              });
            },
            icon: const Icon(Icons.lock_open, size: 18),
            tooltip: "Lock Diary",
          )
        ],
      ),
      body: Column(
        children: [
          // Add Entry Block
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                ),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      hintText: "Entry Title",
                      hintStyle: TextStyle(fontSize: 12),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const Divider(height: 12),
                  TextField(
                    controller: _contentController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: "How are you feeling today? Write with absolute privacy...",
                      hintStyle: TextStyle(fontSize: 11),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Transform.scale(
                            scale: 0.7,
                            child: Switch(
                              value: _allowAiAccess,
                              onChanged: (val) {
                                setState(() {
                                  _allowAiAccess = val;
                                });
                              },
                              activeColor: accentColor,
                            ),
                          ),
                          const Text(
                            "Allow Private Companion Access",
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: _addEntry,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: isDark ? const Color(0xFF111315) : Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        ),
                        child: const Text("Save Securely", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      )
                    ],
                  ),
                ],
              ),
            ),
          ),

          // List of Entries
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      "No secure logs recorded yet.\nYour writings are fully encrypted locally on this phone.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: isDark ? Colors.grey[600] : Colors.grey[500]),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      final dateStr = entry.date.split("T").first;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.title,
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                Text(
                                  dateStr,
                                  style: const TextStyle(fontSize: 9, color: Colors.grey),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              entry.content,
                              style: const TextStyle(fontSize: 11, height: 1.4),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      entry.allowAiAccess 
                                          ? Icons.visibility_outlined 
                                          : Icons.visibility_off_outlined,
                                      size: 11,
                                      color: entry.allowAiAccess ? Colors.green : Colors.orange,
                                    ),
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: () => _toggleAiAccess(entry),
                                      child: Text(
                                        entry.allowAiAccess 
                                            ? "Shared with Companion (Tap to Disable)" 
                                            : "Locked from Companion (Tap to Allow)",
                                        style: TextStyle(
                                          fontSize: 8.5, 
                                          fontWeight: FontWeight.bold,
                                          color: entry.allowAiAccess ? Colors.green : Colors.orange,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                IconButton(
                                  onPressed: () => _deleteEntry(entry.id),
                                  icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                )
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
