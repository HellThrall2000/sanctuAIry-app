import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../../models/journal_entry.dart';
import '../../models/memory_fact.dart';
import '../../services/crisis_guard.dart';
import '../../services/litert_service.dart';
import '../../services/memory_store.dart';
import '../../services/model_preference.dart';
import '../../services/model_settings.dart';
import '../../services/persona.dart';
import '../../services/reply_sanitizer.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../dev_settings_sheet.dart';
import '../organic/organic.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}

/// The measurements that differ between the two shells.
///
/// 1a and 1c share every pixel of chat behaviour and none of its dimensions —
/// the phone layout runs wider bubbles at a smaller size and swaps the "Send"
/// pill for a circular arrow. Carrying that as data keeps one [ChatView].
class ChatViewStyle {
  final double bubbleFontSize;
  final double bubbleMaxWidthFactor;
  final double bubbleRadius;
  final EdgeInsets bubblePadding;
  final EdgeInsets listPadding;
  final EdgeInsets promptsPadding;
  final double promptsGap;
  final double promptFontSize;
  final bool centerPrompts;
  final EdgeInsets composerPadding;

  /// 1a docks the composer on a panel-coloured bar with a top rule; 1c lets it
  /// float on the page background.
  final bool composerOnPanel;

  /// 1c sends with a 40px circular arrow instead of a "Send" pill.
  final bool circularSend;

  /// Widest the conversation column is allowed to get.
  ///
  /// 1a is drawn against a 960px card. Letting it stretch to a 2800px tablet
  /// would put a 70%-width bubble at ~1960px — several times a readable
  /// measure — so the column caps at the width the design was composed for and
  /// centres in anything wider. 1c is phone-width already and takes no cap.
  final double maxContentWidth;

  const ChatViewStyle.warmCompanion()
      : maxContentWidth = 960,
        bubbleFontSize = 13.5,
        bubbleMaxWidthFactor = 0.70,
        bubbleRadius = 16,
        bubblePadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        listPadding = const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
        promptsPadding = const EdgeInsets.fromLTRB(26, 0, 26, 10),
        promptsGap = 8,
        promptFontSize = 11,
        centerPrompts = false,
        composerPadding =
            const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        composerOnPanel = true,
        circularSend = false;

  const ChatViewStyle.focusBloom()
      : maxContentWidth = double.infinity,
        bubbleFontSize = 13,
        bubbleMaxWidthFactor = 0.78,
        bubbleRadius = 18,
        bubblePadding = const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        listPadding = const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
        promptsPadding = const EdgeInsets.fromLTRB(22, 6, 22, 4),
        promptsGap = 6,
        promptFontSize = 10,
        centerPrompts = true,
        composerPadding = const EdgeInsets.fromLTRB(22, 10, 22, 0),
        composerOnPanel = false,
        circularSend = true;
}

/// The companion conversation.
///
/// Deliberately not a [Scaffold]: 1a stacks it under a header between two
/// drawers, 1c floats it above a pill tab bar. The shell owns the chrome.
///
/// The generation logic below — crisis triage, memory recall, reseeding,
/// repeat detection — is carried over unchanged from the previous
/// `ChatScreen`. Only the presentation is new. Each piece of it was arrived at
/// against a specific on-device failure and the comments record which.
class ChatView extends StatefulWidget {
  final List<JournalEntry> allowedJournals;
  final ChatViewStyle style;

  const ChatView({
    super.key,
    required this.allowedJournals,
    required this.style,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final LiteRtService _liteRtService = LiteRtService();
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isGenerating = false;

  /// The three seed phrases offered above the composer.
  static const _quickPrompts = <({String label, String text})>[
    (
      label: 'Deep Reflection',
      text: "I'd like to sit with something that's been weighing on me...",
    ),
    (
      label: 'Stream of Consciousness',
      text:
          "Let's write down my raw, unfiltered thoughts and see where they lead...",
    ),
    (
      label: 'Focus on Wonder',
      text: 'I want to notice something small and good today...',
    ),
  ];

  /// Openers from the last few replies. The runtime exposes no repetition
  /// penalty, so we discourage reuse in the prompt instead — without this the
  /// companion opens nearly every turn with "I am here for you".
  final Queue<String> _recentOpeners = Queue<String>();
  static const int _openerMemory = 3;

  /// The substance of recent replies (see [_substanceOf]), for repeat detection.
  final Queue<String> _recentReplies = Queue<String>();
  static const int _replyMemory = 4;

  /// How many repeated sentences to allow inside one reply before abandoning it.
  ///
  /// Two rather than one: a companion legitimately echoing a short phrase back
  /// to the user is not a loop, but three occurrences of the same sentence
  /// always is.
  static const int _loopTolerance = 2;

  /// How many exchanges to replay when reseeding. Caps the re-prefill cost and
  /// lets stale attractors fall out of context.
  static const int _replayExchangeLimit = 12;

  /// Turns this session carrying ambiguous distress (`CrisisLevel.concern`).
  ///
  /// One is a figure of speech. A pattern across a session is worth responding
  /// to — but by *offering*, once, after the companion has already engaged.
  int _concernTurns = 0;
  bool _offeredSupport = false;
  static const int _concernBeforeOffer = 3;

  final MemoryStore _memory = MemoryStore();

  /// Cached personal facts, rendered for the prompt. Read once when the model
  /// is initialised — see [MemoryStore] for why it is not refreshed mid-session.
  String? _profileBlock;

  /// The turns actually sent to the model, in order.
  ///
  /// Deliberately separate from [_messages], which also holds the welcome
  /// banner, initialisation status lines and crisis responses — none of which
  /// the model ever saw. [LiteRtService.reseed] replays this to rebuild an
  /// equivalent conversation, so it has to reflect the model's real history
  /// rather than what is on screen.
  final List<LiteLmMessage> _modelTranscript = [];

  /// Sampler values plus the profile they belong to. Replaced once the model
  /// file is located and its profile is known.
  ModelSettings _settings = ModelSettings();

  @override
  void initState() {
    super.initState();
    _messages.add(ChatMessage(
      text: 'Welcome to your private Sanctuary. Here, your thoughts can '
          'unfold freely — everything we discuss stays only on this device.',
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Persona plus any journals the user unlocked for this session.
  ///
  /// How much persona the model can take depends on which model it is — see
  /// [Persona.instructionFor] and `ModelProfile`. Stock Gemma 4 E2B follows a
  /// full persona; the fine-tune answers substantive prompts with
  /// session-opener boilerplate when given one, so it gets safety text only.
  ///
  /// The journal dump below does not scale: every allowed entry is pasted in
  /// full, so a user with 50 entries blows the 4096-token context. It is
  /// replaced in P3/P4 by retrieval — see ROADMAP.md.
  String? _buildSystemInstruction() {
    final persona = Persona.instructionFor(_settings.profile);
    if (persona == null &&
        widget.allowedJournals.isEmpty &&
        _profileBlock == null) {
      return null;
    }

    final buffer = StringBuffer(persona ?? '');

    if (_profileBlock != null) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(_profileBlock);
    }

    if (widget.allowedJournals.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(
        'The user unlocked these private journal entries and approved them '
        'for this conversation:',
      );
      for (final entry in widget.allowedJournals) {
        buffer.writeln();
        buffer.writeln('Title: ${entry.title}');
        buffer.writeln('Date: ${entry.date.split('T').first}');
        buffer.writeln('Content: ${entry.content}');
      }
    }

    return buffer.toString();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _sendMessage() async {
    final prompt = _textController.text.trim();
    if (prompt.isEmpty || _isGenerating) return;

    _textController.clear();
    setState(() {
      _messages.add(ChatMessage(
        text: prompt,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isGenerating = true;
    });
    _scrollToBottom();
    await Future.delayed(const Duration(milliseconds: 150));

    // Only an *unambiguous* statement of intent short-circuits: no model, no
    // sampling, no memory. That reply must be identical every time, and a
    // sampling process cannot promise that.
    //
    // Ambiguous distress deliberately does not interrupt. The companion answers
    // it normally and, being CBT-tuned, asks what is behind it — which is how
    // risk is actually assessed. See CrisisGuard for why this is two tiers.
    final level = CrisisGuard.assess(prompt);
    if (level == CrisisLevel.explicit) {
      setState(() {
        _messages.add(ChatMessage(
          text: CrisisGuard.response(),
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isGenerating = false;
      });
      _scrollToBottom();
      return;
    }
    if (level == CrisisLevel.concern) _concernTurns++;

    // Learn from what the user just said. Deterministic and instant, so it
    // costs nothing on the turn — see FactExtractor for why this is not a model
    // pass. Not awaited into the reply path: a failed write must never block a
    // conversation.
    unawaited(_memory.learnFromMessage(prompt).catchError((Object e) {
      debugPrint('Memory write failed: $e');
      return <MemoryFact>[];
    }));

    if (!_liteRtService.isInitialized) {
      final statusMessageIndex = _messages.length;
      setState(() {
        _messages.add(ChatMessage(
          text: 'Waking the companion — mapping the model into memory. '
              'This takes a few seconds the first time.',
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
      await Future.delayed(const Duration(milliseconds: 150));

      // Which model is present decides the persona and the sampler, so the
      // profile has to be resolved before the instruction is built.
      final located = await _liteRtService.findLocalModelFile(
        preferredProfileId: await ModelPreference.load(),
      );
      if (located != null) {
        _settings = await ModelSettings.load(located.profile);
        // Loaded before the instruction is built — this is the whole point of
        // the cache, that a new session starts already knowing the user.
        _profileBlock = await _memory.profileBlock();
        final error = await _liteRtService.initializeModel(
          path: located.path,
          settings: _settings,
          systemInstruction: _buildSystemInstruction(),
          initialMessages: Persona.exemplars(),
        );
        if (!mounted) return;
        if (error != null) {
          setState(() {
            _messages[statusMessageIndex] = ChatMessage(
              text: 'The companion could not start: $error',
              isUser: false,
              timestamp: DateTime.now(),
            );
            _isGenerating = false;
          });
          _scrollToBottom();
          return;
        }
        setState(() => _messages.removeAt(statusMessageIndex));
      } else {
        setState(() {
          _messages[statusMessageIndex] = ChatMessage(
            text: 'Companion offline — the model file is not on this device.',
            isUser: false,
            timestamp: DateTime.now(),
          );
          _isGenerating = false;
        });
        _scrollToBottom();
        return;
      }
    }

    // The persona and journal context are supplied once as the conversation's
    // system instruction (see _buildSystemInstruction), and the runtime applies
    // the chat template stored in the model's own metadata. So the model gets
    // the user's plain text here — hand-writing turn tags would be tokenized as
    // literal text and corrupt the prompt.
    //
    // Facts relevant to *this* message. The pinned profile is fixed at
    // conversation creation, so anything beyond it has to arrive with the turn
    // — rebuilding the system instruction per turn would mean re-prefilling the
    // whole history. Usually null: FactRanker only fires on a real match, which
    // keeps short messages from being swamped by meta-text.
    final recall =
        await _memory.recallBlock(prompt).catchError((Object e) => null);

    final hint = Persona.repetitionHint(_recentOpeners);
    final fullPrompt = [
      if (recall != null) recall,
      prompt,
      if (hint != null) hint,
    ].join('\n\n');

    final streamingMessage =
        ChatMessage(text: '', isUser: false, timestamp: DateTime.now());
    setState(() => _messages.add(streamingMessage));

    String reply;
    try {
      reply = await _streamInto(fullPrompt, streamingMessage.timestamp);

      // The sampler seed is fixed for the life of a conversation, so a reply
      // that has already been given will keep being given. Rebuilding on a
      // fresh seed is the only lever the runtime offers — see
      // LiteRtService.reseed. Once only: if it repeats twice the problem is the
      // model's distribution, not the seed, and retrying again just costs the
      // user another re-prefill.
      if (_isRepeat(reply)) {
        final err = await _liteRtService.reseed(history: _replayHistory());
        if (err == null && mounted) {
          reply = await _streamInto(fullPrompt, streamingMessage.timestamp);
        }
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _messages[_messages.length - 1] = ChatMessage(
          text: 'Something went wrong during inference: $err',
          isUser: false,
          timestamp: streamingMessage.timestamp,
        );
        _isGenerating = false;
      });
      _scrollToBottom();
      return;
    }

    if (!mounted) return;
    // The user's own words, not `fullPrompt`: the recalled-facts block is
    // scaffolding for one turn, and replaying it on a reseed would re-inject
    // facts chosen for a message that is no longer the current one.
    _remember(prompt, reply);
    setState(() {
      _isGenerating = false;

      // Offered *after* the companion has answered, so the user gets a real
      // reply first and the resource reads as an addition rather than a
      // deflection. Once per session — repeating it would nag.
      if (_concernTurns >= _concernBeforeOffer && !_offeredSupport) {
        _offeredSupport = true;
        _messages.add(ChatMessage(
          text: CrisisGuard.gentleOffer(),
          isUser: false,
          timestamp: DateTime.now(),
        ));
      }
    });
    _scrollToBottom();
  }

  /// Streams one reply into the last message slot, completing with the raw text.
  ///
  /// The slot is rewritten on every chunk with [ReplySanitizer] applied to the
  /// accumulated text, so `_comma_` artifacts never reach the screen. The raw
  /// text is what completes, because that is what the model actually said and
  /// what repeat detection and the replay transcript should be based on.
  Future<String> _streamInto(String prompt, DateTime slotTimestamp) {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    StreamSubscription<String>? subscription;

    bool paint({required bool streaming}) {
      final sanitized =
          ReplySanitizer.cleanDetailed(buffer.toString(), streaming: streaming);
      if (mounted) {
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            text: sanitized.text,
            isUser: false,
            timestamp: slotTimestamp,
          );
        });
        _scrollToBottom();
      }
      return sanitized.droppedSentences >= _loopTolerance;
    }

    subscription = _liteRtService.generateResponseStream(prompt).listen(
      (chunk) {
        buffer.write(chunk);
        // Once it is repeating there is nothing left to wait for — it will run
        // to the token limit saying the same thing. Cutting it short saves the
        // user staring at a spinner for the rest of the generation.
        if (paint(streaming: true)) {
          subscription?.cancel();
          paint(streaming: false);
          if (!completer.isCompleted) completer.complete(buffer.toString());
        }
      },
      onError: (err) {
        subscription?.cancel();
        if (!completer.isCompleted) completer.completeError(err);
      },
      onDone: () {
        paint(streaming: false);
        subscription?.cancel();
        if (!completer.isCompleted) completer.complete(buffer.toString());
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  /// Whether the companion has just said this, or opened this way, recently.
  ///
  /// Two triggers, because the failure has two shapes: verbatim repetition
  /// (measured at 1/3 identical replies to the same prompt within a single
  /// conversation) and the softer case of every turn starting with the same
  /// stock phrase.
  bool _isRepeat(String reply) {
    // Compared on substance, not on the raw string: on-device the companion
    // followed "I'm so glad you got promoted" with "Yes! I'm so glad you got
    // promoted", which a whole-string comparison reads as a different reply and
    // lets through.
    final substance = _substanceOf(reply);
    if (substance.isNotEmpty && _recentReplies.contains(substance)) return true;

    final opener = Persona.openerOf(reply);
    return opener != null && _recentOpeners.contains(opener);
  }

  /// The history to replay when reseeding — deliberately *not* the full
  /// transcript.
  ///
  /// A reseed happens because the companion repeated itself, and by then the
  /// offending sentence is in the transcript several times over. Replaying all
  /// of them rebuilds the exact context that produced them, and a fresh seed
  /// cannot outvote a history that demonstrates the pattern repeatedly — the
  /// first version of this did replay everything, and both retries on-device
  /// came back with the same sentence.
  ///
  /// So exchanges are dropped when the companion's reply repeats the substance
  /// of an earlier one, keeping the first occurrence. Whole exchanges rather
  /// than lone replies, to leave user turns paired with an answer.
  List<LiteLmMessage> _replayHistory() {
    final kept = <LiteLmMessage>[];
    final seen = <String>{};

    // Even indices are user turns, odd are the replies to them — see [_remember].
    for (var i = 0; i + 1 < _modelTranscript.length; i += 2) {
      final key = _substanceOf(_modelTranscript[i + 1].text);
      if (key.isNotEmpty && !seen.add(key)) continue;
      kept
        ..add(_modelTranscript[i])
        ..add(_modelTranscript[i + 1]);
    }

    const limit = _replayExchangeLimit * 2;
    return kept.length <= limit ? kept : kept.sublist(kept.length - limit);
  }

  /// A reply's longest sentence, normalised — its substance, ignoring the
  /// interjection it happens to be wearing. `"I'm so glad you got promoted"`
  /// and `"Yes! I'm so glad you got promoted"` reduce to the same key.
  static String _substanceOf(String reply) {
    final keys = ReplySanitizer.sentenceKeys(reply);
    if (keys.isEmpty) return '';
    return keys.reduce((a, b) => b.length > a.length ? b : a);
  }

  /// Records a completed exchange for replay and repeat detection.
  void _remember(String prompt, String reply) {
    _modelTranscript
      ..add(LiteLmMessage.user(prompt))
      ..add(LiteLmMessage.model(reply));

    final substance = _substanceOf(reply);
    if (substance.isNotEmpty) {
      _recentReplies.addLast(substance);
      while (_recentReplies.length > _replyMemory) {
        _recentReplies.removeFirst();
      }
    }

    final opener = Persona.openerOf(reply);
    if (opener != null) {
      _recentOpeners.addLast(opener);
      while (_recentOpeners.length > _openerMemory) {
        _recentOpeners.removeFirst();
      }
    }
  }

  /// Opens the sampler tuning panel (debug builds only — see
  /// [DevSettingsSheet]). Reachable by long-pressing the composer, which keeps
  /// it out of the way of normal use.
  Future<void> _openDevSettings() async {
    final updated = await DevSettingsSheet.show(context, _settings);
    if (updated == null || !mounted) return;

    setState(() => _settings = updated);
    await updated.save();

    if (_liteRtService.isInitialized) {
      final err = await _liteRtService.reconfigure(updated);
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: err == null
              ? 'Sampler updated ($updated). The companion has lost the '
                  'earlier thread.'
              : 'Could not apply sampler settings: $err',
          isUser: false,
          timestamp: DateTime.now(),
        ));
        // reconfigure() discards conversation history, so the replay transcript
        // and repeat history go with it — otherwise they describe a
        // conversation the model is no longer in.
        _recentOpeners.clear();
        _recentReplies.clear();
        _modelTranscript.clear();
      });
      _scrollToBottom();
    }
  }

  // ---------------------------------------------------------------- rendering

  @override
  Widget build(BuildContext context) {
    final s = widget.style;

    return Column(
      // Stretch, not the default centre: without it the quick-prompt row
      // shrink-wraps its chips and centres them, and 1a aligns them left.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _capped(
            ListView.builder(
              controller: _scrollController,
              padding: s.listPadding,
              itemCount: _messages.length,
              itemBuilder: (context, index) => _bubble(_messages[index]),
            ),
          ),
        ),
        _capped(_quickPromptRow()),
        // The composer bar's background spans the full width — it is chrome,
        // and a floating 960px strip would leave the rule hanging in mid-air —
        // so only its contents are capped.
        _composer(),
      ],
    );
  }

  /// Centres [child] in anything wider than the design's own canvas.
  ///
  /// Sized tightly rather than merely constrained: a loose `maxWidth` lets a
  /// [Wrap] shrink-wrap its children, which silently centres the quick-prompt
  /// chips no matter what `WrapAlignment` they are given.
  Widget _capped(Widget child) {
    final max = widget.style.maxContentWidth;
    if (max == double.infinity) return child;
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SizedBox(
          width: math.min(constraints.maxWidth, max),
          child: child,
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage msg) {
    final t = context.tokens;
    final s = widget.style;

    // An empty assistant slot is the moment between sending and the first
    // token. The prototype has no such state; showing the pending indicator
    // here is what keeps the wait from looking like a dropped message.
    if (!msg.isUser && msg.text.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            padding: s.bubblePadding,
            decoration: BoxDecoration(
              color: t.assistantBubbleBg,
              borderRadius: BorderRadius.circular(s.bubbleRadius),
            ),
            child: _TypingDots(color: t.assistantBubbleFg),
          ),
        ),
      );
    }

    final isUser = msg.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        // `gap: 12px` between bubbles.
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // Measured against the column the bubble actually lives in, not the
            // window — once the conversation is capped at 960 those differ, and
            // using the window would let a bubble overflow its own column.
            maxWidth: (math.min(
                      MediaQuery.sizeOf(context).width,
                      s.maxContentWidth,
                    ) -
                    s.listPadding.horizontal) *
                s.bubbleMaxWidthFactor,
          ),
          child: Container(
            padding: s.bubblePadding,
            decoration: BoxDecoration(
              color: isUser ? t.userBubbleBg : t.assistantBubbleBg,
              borderRadius: BorderRadius.circular(s.bubbleRadius),
            ),
            child: SelectableText(
              msg.text,
              style: OrganicText.bubble(
                isUser ? t.userBubbleFg : t.assistantBubbleFg,
                size: s.bubbleFontSize,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickPromptRow() {
    final s = widget.style;
    return Padding(
      padding: s.promptsPadding,
      child: Wrap(
        spacing: s.promptsGap,
        runSpacing: s.promptsGap,
        alignment: s.centerPrompts ? WrapAlignment.center : WrapAlignment.start,
        children: [
          for (final p in _quickPrompts)
            OrganicTag(
              label: p.label,
              variant: OrganicTagVariant.outline,
              fontSize: s.promptFontSize,
              // "click sets the input field's text to a seed phrase (does not
              // auto-send)".
              onTap: _isGenerating
                  ? null
                  : () => setState(() {
                        _textController.text = p.text;
                        _textController.selection =
                            TextSelection.collapsed(offset: p.text.length);
                      }),
            ),
        ],
      ),
    );
  }

  Widget _composer() {
    final t = context.tokens;
    final s = widget.style;

    return Container(
      padding: s.composerPadding,
      decoration: s.composerOnPanel
          ? BoxDecoration(
              color: t.bgPanel,
              border: Border(top: BorderSide(color: t.border)),
            )
          : null,
      child: SafeArea(
        top: false,
        child: _capped(Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              // Long-press opens the sampler panel in debug builds; it is a
              // no-op in release, so normal users never see it.
              child: GestureDetector(
                onLongPress: _openDevSettings,
                child: OrganicInput(
                  controller: _textController,
                  enabled: !_isGenerating,
                  hint: s.circularSend
                      ? "What's on your mind..."
                      : "Explore what's on your mind...",
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            SizedBox(width: s.circularSend ? 8 : 10),
            _sendButton(),
          ],
        )),
      ),
    );
  }

  Widget _sendButton() {
    final t = context.tokens;

    if (!widget.style.circularSend) {
      return OrganicButton(
        label: 'Send',
        onPressed: _isGenerating ? null : _sendMessage,
      );
    }

    // 1c: a 40px circle carrying the "→" glyph, drawn with text rather than an
    // icon font exactly as the prototype does.
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: _isGenerating
            ? Color.lerp(t.accentBg, t.bgApp, 0.45)!
            : t.accentBg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _isGenerating ? null : _sendMessage,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.black.withValues(alpha: 0.14),
          child: Center(
            child: Text(
              '→',
              style: TextStyle(
                fontFamily: Organic.headingFont,
                fontSize: 17,
                height: 1.0,
                color: t.onAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three dots that fade in sequence while the first token is pending.
class _TypingDots extends StatefulWidget {
  final Color color;

  const _TypingDots({required this.color});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          // Each dot peaks a third of a cycle after the one before it.
          final phase = (_controller.value - i * 0.2) % 1.0;
          final opacity = 0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
          return Container(
            width: 5,
            height: 5,
            margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: opacity.clamp(0.0, 1.0)),
              shape: BoxShape.circle,
            ),
          );
        }),
      ),
    );
  }
}
