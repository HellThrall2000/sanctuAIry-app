import 'package:flutter/material.dart';
import '../models/memory_fact.dart';
import '../services/memory_store.dart';

/// Everything the companion has cached about the user, with its source, and a
/// way to delete any of it.
///
/// Not optional. The app's promise is that nothing leaves the device; that is
/// not the same as the user knowing what is *on* it. A silent profile assembled
/// from chat and diary entries is exactly the thing a privacy-first app has to
/// be able to show on demand — including the sentence each fact came from, so
/// the answer to "how do you know that" is the user's own words rather than a
/// paraphrase they have to trust.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({Key? key}) : super(key: key);

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  static const _accent = Color(0xFF00E5FF);
  static const _text = Color(0xFFE2E6E9);
  static const _muted = Color(0xFF878F96);

  final MemoryStore _memory = MemoryStore();
  List<MemoryFact> _facts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final facts = await _memory.all();
    if (!mounted) return;
    setState(() {
      _facts = facts;
      _loading = false;
    });
  }

  Future<void> _forget(MemoryFact fact) async {
    await _memory.forget(fact.key);
    await _load();
  }

  Future<void> _forgetAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Forget everything?',
            style: TextStyle(color: _text, fontSize: 16)),
        content: const Text(
          'The companion will start from nothing next time you talk to it. '
          'Your journal entries are not affected.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget all',
                style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _memory.forgetAll();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('What the companion remembers',
                          style: TextStyle(
                              color: _accent,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text(
                        'Stored on this device only. Delete anything you would '
                        'rather it forgot.',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (_facts.isNotEmpty)
                  TextButton(
                    onPressed: _forgetAll,
                    child: const Text('Forget all',
                        style: TextStyle(color: Color(0xFFFF6B6B), fontSize: 12)),
                  ),
              ],
            ),
          ),
          if (_loading)
            const Expanded(
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: _accent, strokeWidth: 2),
                ),
              ),
            )
          else if (_facts.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nothing yet.\n\nThe companion picks things up as you talk, '
                    'and from diary entries you have shared with it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _facts.length,
                itemBuilder: (context, i) => _factTile(_facts[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _factTile(MemoryFact fact) {
    final fromJournal = fact.source == FactSource.journal;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        border: Border(left: BorderSide(color: _accent.withOpacity(0.4), width: 2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fact.text,
                    style: const TextStyle(
                        color: _text, fontSize: 13, height: 1.4)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(fromJournal ? Icons.book_outlined : Icons.chat_bubble_outline,
                        size: 11, color: _muted),
                    const SizedBox(width: 4),
                    Text(
                      fromJournal ? 'from your diary' : 'from chat',
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                    const SizedBox(width: 8),
                    Text(_ago(fact.updatedAt),
                        style: const TextStyle(color: _muted, fontSize: 10)),
                  ],
                ),
                if (fact.evidence.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // The user's own sentence, so "how do you know that" has a
                  // literal answer.
                  Text(
                    '“${_truncate(fact.evidence)}”',
                    style: const TextStyle(
                        color: _muted, fontSize: 11, fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: _muted),
            tooltip: 'Forget this',
            onPressed: () => _forget(fact),
          ),
        ],
      ),
    );
  }

  static String _truncate(String s) =>
      s.length <= 120 ? s : '${s.substring(0, 117)}...';

  static String _ago(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }
}
