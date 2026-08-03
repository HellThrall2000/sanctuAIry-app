import 'package:flutter/material.dart';

import '../../models/memory_fact.dart';
import '../../services/chunk_store.dart';
import '../../services/memory_cache.dart';
import '../../services/memory_store.dart';
import '../../services/relationship_log.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';

/// Everything the companion has cached about the user, with its source, and a
/// way to delete any of it.
///
/// Not optional. The app's promise is that nothing leaves the device; that is
/// not the same as the user knowing what is *on* it. A silent profile assembled
/// from chat and diary entries is exactly the thing a privacy-first app has to
/// be able to show on demand — including the sentence each fact came from, so
/// the answer to "how do you know that" is the user's own words rather than a
/// paraphrase they have to trust.
///
/// The Organic handoff has no destination for this — its three are Companion,
/// Diary and Settings. Rather than drop the feature it is reached from
/// Settings, and drawn with the same components as everything else.
class MemoryPanel extends StatefulWidget {
  const MemoryPanel({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MemoryPanel()),
    );
  }

  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
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
    final confirmed = await OrganicDialog.show<bool>(
      context,
      OrganicDialog(
        title: 'Forget everything?',
        body: 'Everything the companion has learned — from chat and from diary '
            'entries you shared — is erased, including anything it kept after '
            'you stopped sharing an entry. This is the only true erase. Your '
            'diary entries themselves are not affected.',
        actions: [
          OrganicButton(
            label: 'Cancel',
            variant: OrganicButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          OrganicButton(
            label: 'Forget all',
            foreground: Organic.danger,
            variant: OrganicButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // The true erase, so it has to reach every store that holds derived
      // memory — facts, episodic chunks and the relationship log. Clearing only
      // `memory_facts` used to leave the companion able to quote a diary entry
      // through retrieval after the user had been told it forgot everything.
      await _memory.forgetAll();
      await ChunkStore.instance.clear();
      await RelationshipLog.instance.clear();
      await MemoryCache.instance.reset();
      await MemoryCache.instance.warm(force: true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.bgApp,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  OrganicIconButton(
                    icon: Icons.arrow_back_rounded,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Organic.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'What I Remember',
                          style: OrganicText.h4(t).copyWith(fontSize: 17),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Stored on this device only.',
                          style: OrganicText.cardMeta(t),
                        ),
                      ],
                    ),
                  ),
                  if (_facts.isNotEmpty)
                    OrganicButton(
                      label: 'Forget all',
                      variant: OrganicButtonVariant.ghost,
                      fontSize: 11,
                      foreground: Organic.danger,
                      onPressed: _forgetAll,
                    ),
                ],
              ),
            ),
            Expanded(child: _body(t)),
          ],
        ),
      ),
    );
  }

  Widget _body(SanctuaryTokens t) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(color: t.accentBg, strokeWidth: 2),
        ),
      );
    }

    if (_facts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing yet.\n\nThe companion picks things up as you talk, and '
            'from diary entries you have shared with it.',
            textAlign: TextAlign.center,
            style: OrganicText.cardBody(t),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: _facts.length,
      separatorBuilder: (_, __) => const SizedBox(height: Organic.space3),
      itemBuilder: (context, i) => _factCard(_facts[i], t),
    );
  }

  Widget _factCard(MemoryFact fact, SanctuaryTokens t) {
    final fromJournal = fact.source == FactSource.journal;

    return OrganicCard(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(fact.text, style: OrganicText.cardBody(t)),
            ),
            OrganicIconButton(
              icon: Icons.close_rounded,
              size: 22,
              tooltip: 'Forget this',
              color: t.muted,
              onPressed: () => _forget(fact),
            ),
          ],
        ),
        Row(
          children: [
            OrganicTag(
              label: fromJournal ? 'from your diary' : 'from chat',
              variant: fromJournal
                  ? OrganicTagVariant.accent2
                  : OrganicTagVariant.neutral,
              fontSize: 10,
            ),
            const SizedBox(width: Organic.space2),
            Text(_ago(fact.updatedAt), style: OrganicText.cardMeta(t)),
          ],
        ),
        if (fact.evidence.isNotEmpty)
          // The user's own sentence, so "how do you know that" has a literal
          // answer.
          Text(
            '“${_truncate(fact.evidence)}”',
            style: OrganicText.cardMeta(t)
                .copyWith(fontStyle: FontStyle.italic),
          ),
      ],
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
