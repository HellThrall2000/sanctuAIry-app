import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../../models/chat_message.dart';
import '../../models/journal_entry.dart';
import '../../models/memory_fact.dart';
import '../../models/sentiment.dart';
import '../../services/chat_store.dart';
import '../../services/chunk_store.dart';
import '../../services/crisis_guard.dart';
import '../../services/event_store.dart';
import '../../services/guard.dart';
import '../../services/litert_service.dart';
import '../../services/memory_cache.dart';
import '../../services/memory_store.dart';
import '../../services/model_preference.dart';
import '../../services/model_settings.dart';
import '../../services/nudge_service.dart';
import '../../services/persona.dart';
import '../../services/quick_prompts.dart';
import '../../services/relationship_log.dart';
import '../../services/reply_sanitizer.dart';
import '../../services/sentiment_analyzer.dart';
import '../../services/topic_extractor.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../dev_settings_sheet.dart';
import '../organic/organic.dart';

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

  final ChatStore _chatStore = ChatStore.instance;
  final ChunkStore _chunks = ChunkStore.instance;
  final EventStore _events = EventStore.instance;
  final RelationshipLog _relationship = RelationshipLog.instance;
  final NudgeService _nudges = NudgeService.instance;
  final MemoryCache _cache = MemoryCache.instance;

  /// Screens the user's message in and the model's reply out. See [Guard] for
  /// why this is deterministic rather than a second classifier model.
  static const Guard _guard = LexicalGuard();

  /// How many past exchanges to prefill the model with when resuming.
  ///
  /// The screen shows the whole history; the model cannot. At 4096 tokens the
  /// context also has to hold the persona, the profile, the relationship block
  /// and room to generate, so continuity is bought with a short window plus
  /// retrieval over everything older — which is the entire reason `ChunkStore`
  /// exists.
  static const int _resumeExchanges = 6;

  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _chatStore.cleared.addListener(_onCleared);
    _restore();
  }

  @override
  void dispose() {
    _chatStore.cleared.removeListener(_onCleared);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Settings erased the transcript. Drop everything the conversation was
  /// built on, including the model's own history — leaving that behind would
  /// let the companion answer from a conversation the user can no longer see.
  void _onCleared() {
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _modelTranscript.clear();
      _recentOpeners.clear();
      _recentReplies.clear();
    });
  }

  /// Loads the conversation from disk and, if the user has been away, lets the
  /// companion open with something.
  Future<void> _restore() async {
    final stored = await _chatStore.recent();
    if (!mounted) return;

    if (stored.isEmpty) {
      // First run. The welcome line is stored like any other turn so it is
      // still there on the second launch rather than being re-announced.
      final welcome = _system(
        'Welcome to your private Sanctuary. Here, your thoughts can unfold '
        'freely — everything we discuss stays only on this device.',
      );
      await _chatStore.append(welcome);
      await _relationship.recordMilestoneOnce(
        MilestoneKind.firstConversation,
        'The first time they opened Sanctuary.',
      );
      if (!mounted) return;
      setState(() {
        _messages.add(welcome);
        _loadingHistory = false;
      });
      return;
    }

    setState(() {
      _messages.addAll(_withDerivedDelivery(stored));
      _loadingHistory = false;
      // Restoring the transcript also restores what the model will be told it
      // said, so a reseed after resuming replays a real conversation.
      _modelTranscript.addAll(_transcriptFrom(stored));
    });
    _scrollToBottom();

    await _deliverPendingNudge();
  }

  /// Shows a check-in if the user has been away long enough to warrant one.
  ///
  /// Runs on open regardless of whether they arrived via the notification, so
  /// the app and the notification shade never disagree about whether the
  /// companion reached out.
  Future<void> _deliverPendingNudge() async {
    await _nudges.load();
    final nudge = await _nudges.pendingNudge();
    if (nudge == null || !mounted) return;

    final message = _system(nudge.text);
    await _chatStore.append(message);
    await _nudges.markDelivered(nudge);
    if (nudge.about != null) {
      await _relationship.recordMilestone(
        MilestoneKind.returnedAfterAbsence,
        'Asked how ${nudge.about!.text} went.',
      );
    }
    if (!mounted) return;
    setState(() => _messages.add(message));
    _scrollToBottom();
  }

  /// The turns the model is allowed to believe it took part in.
  ///
  /// Only [ChatMessage.sentToModel] turns, and only the last
  /// [_resumeExchanges] of them. System text — banners, guard replies, nudges —
  /// is on screen but was never generated, and replaying it as model history
  /// would teach the companion to imitate the app's own voice.
  /// The restored transcript, trimmed to the resume window.
  ///
  /// [_modelTranscript] holds everything restored so that repeat detection and
  /// [_replayHistory] see the whole picture; only this much is actually
  /// prefilled into the engine.
  List<LiteLmMessage> _resumeHistory() {
    const limit = _resumeExchanges * 2;
    return _modelTranscript.length <= limit
        ? List.of(_modelTranscript)
        : _modelTranscript.sublist(_modelTranscript.length - limit);
  }

  /// Restores tick state without storing it.
  ///
  /// A user turn is [MessageDelivery.read] if anything follows it, and
  /// [MessageDelivery.sent] otherwise — which is exactly right for the one case
  /// that matters: an app killed mid-generation comes back showing the last
  /// message as never answered, because it never was.
  static List<ChatMessage> _withDerivedDelivery(List<ChatMessage> stored) {
    var answered = false;
    final out = <ChatMessage>[];
    // Backwards, so "is there anything after this" is a single pass.
    for (final message in stored.reversed) {
      if (message.isUser) {
        out.add(message.copyWith(
          delivery:
              answered ? MessageDelivery.read : MessageDelivery.sent,
        ));
      } else {
        answered = true;
        out.add(message);
      }
    }
    return out.reversed.toList(growable: false);
  }

  static List<LiteLmMessage> _transcriptFrom(List<ChatMessage> stored) {
    final usable = stored
        .where((m) => m.sentToModel && m.role != ChatRole.system)
        .toList();
    final window = usable.length <= _resumeExchanges * 2
        ? usable
        : usable.sublist(usable.length - _resumeExchanges * 2);
    return [
      for (final m in window)
        m.isUser ? LiteLmMessage.user(m.text) : LiteLmMessage.model(m.text),
    ];
  }

  ChatMessage _system(String text) => ChatMessage(
        id: _newId(),
        role: ChatRole.system,
        text: text,
        createdAt: DateTime.now(),
        sentToModel: false,
      );

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  static int _counter = 0;

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

    // One block, not four. Facts, diary, mood trend and past sessions used to
    // arrive under four separate headings, which cost four preambles out of a
    // 4096-token container and taught the model to cite its sources — asked
    // "do I swim" it replied *"You mentioned swimming in your diary"*. It is
    // all simply what the companion knows. See MemoryCache.knowledgeBlock.
    final knowledge = _cache.knowledgeBlock();
    if (persona == null && knowledge == null) return null;

    final buffer = StringBuffer(persona ?? '');
    if (knowledge != null) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(knowledge);
      _cache.markNotesSeen();
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
    // Blocked until the transcript is restored: sending first would append a
    // turn ahead of history that is still loading, and the conversation would
    // come back in the wrong order on the next launch.
    if (prompt.isEmpty || _isGenerating || _loadingHistory) return;

    _textController.clear();

    // Read the emotional register before anything else touches the message.
    // Cheap enough to be unconditional — see SentimentAnalyzer for why this is
    // lexical rather than a second inference pass.
    final mood = SentimentAnalyzer.read(prompt);
    final userMessage = ChatMessage(
      id: _newId(),
      role: ChatRole.user,
      text: prompt,
      createdAt: DateTime.now(),
      mood: mood,
      // One grey tick until the model is actually awake.
      delivery: MessageDelivery.sent,
    );

    setState(() {
      _messages.add(userMessage);
      _isGenerating = true;
    });
    _scrollToBottom();
    await _chatStore.append(userMessage);
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
      // Answered by the app rather than the model, but answered — the ticks
      // describe whether a reply exists, not which part of the app wrote it.
      _setDelivery(userMessage.id, MessageDelivery.read);
      await _emitSystem(CrisisGuard.response());
      setState(() => _isGenerating = false);
      return;
    }
    if (level == CrisisLevel.concern) _concernTurns++;

    // Everything CrisisGuard does not own: sexual content and abuse aimed at
    // the companion. Narrow on purpose — someone arriving angry is usually
    // distressed, and a companion that refuses them has failed at its job. See
    // LexicalGuard for where that line is drawn.
    final inputVerdict = _guard.screenInput(prompt);
    if (!inputVerdict.isAllowed) {
      _setDelivery(userMessage.id, MessageDelivery.read);
      await _emitSystem(inputVerdict.replacement!);
      setState(() => _isGenerating = false);
      return;
    }

    // Learn from what the user just said. Deterministic and instant, so it
    // costs nothing on the turn — see FactExtractor for why this is not a model
    // pass. Not awaited into the reply path: a failed write must never block a
    // conversation.
    unawaited(_memory.learnFromMessage(prompt).catchError((Object e) {
      debugPrint('Memory write failed: $e');
      return <MemoryFact>[];
    }));

    // The relationship log, and anything the user said is coming up. Both feed
    // later turns and later check-ins rather than this reply, so neither is
    // awaited into the response path.
    unawaited(() async {
      try {
        await _relationship.recordMood(mood);
        await _relationship.noteTopics(TopicExtractor.extract(prompt));
        await _events.learnFrom(prompt);
        if (mood.label == MoodLabel.distressed) {
          await _relationship.recordMilestone(
            MilestoneKind.hardNight,
            'A conversation that started in real distress.',
          );
        } else if (mood.label == MoodLabel.bright) {
          await _relationship.recordMilestone(
            MilestoneKind.goodNews,
            'They came with something good.',
          );
        }
      } catch (e) {
        debugPrint('Relationship write failed: $e');
      }
    }());

    if (!_liteRtService.isInitialized) {
      // No banner here. The single grey tick already says the message has been
      // written down but not delivered, which is the whole of what a loading
      // notice used to say — and it says it without putting a line of app
      // housekeeping into the middle of someone's conversation. Only genuine
      // failures below still speak up, because those need an explanation the
      // ticks cannot give.

      // Which model is present decides the persona and the sampler, so the
      // profile has to be resolved before the instruction is built.
      final located = await _liteRtService.findLocalModelFile(
        preferredProfileId: await ModelPreference.load(),
      );
      if (located != null) {
        _settings = await ModelSettings.load(located.profile);
        // Both loaded before the instruction is built — this is the whole point
        // of the cache, that a new session starts already knowing the user and
        // already knowing how the two of them have been.
        // Already in memory — warmed at launch, so this costs nothing here.
        await _cache.warm();
        final error = await _liteRtService.initializeModel(
          path: located.path,
          settings: _settings,
          systemInstruction: _buildSystemInstruction(),
          // Resume where the conversation left off. Exemplars only seed a
          // conversation that has no history of its own to learn the register
          // from — real history is always the better demonstration.
          initialMessages:
              _modelTranscript.isEmpty ? Persona.exemplars() : _resumeHistory(),
        );
        if (!mounted) return;
        if (error != null) {
          await _emitSystem('The companion could not start: $error');
          setState(() => _isGenerating = false);
          return;
        }
      } else {
        await _emitSystem(
          'Companion offline — the model file is not on this device.',
        );
        setState(() => _isGenerating = false);
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

    // Past conversations that bear on this message. Separate from `recall`
    // above: that returns slot-keyed facts ("they are allergic to peanuts"),
    // this returns what was actually said months ago. Usually null — most
    // turns should retrieve nothing, or the prompt fills with irrelevance.
    final episodic =
        await _chunks.recallBlock(prompt).catchError((Object e) => null);

    final hint = Persona.repetitionHint(_recentOpeners);
    // How they sound *in this message*, placed immediately before it. The
    // system instruction is fixed for the conversation and cannot track a turn
    // where the news reverses — which is exactly how the companion came to
    // celebrate a job offer the user had just said they did not get.
    final cue = Persona.moodCue(mood);

    // Diary entries shared *after* this conversation was created. The system
    // instruction is fixed once the model starts, so an entry permitted
    // mid-session has no other way in — which is precisely why the companion
    // appeared to ignore notes the user had just given it access to. Carried
    // once, on the next turn, then marked seen.
    String? freshNotes;
    if (_cache.hasUnseenNotes) {
      freshNotes = _cache.knowledgeBlock();
      _cache.markNotesSeen();
    }

    final fullPrompt = [
      if (freshNotes != null) freshNotes,
      if (episodic != null) episodic,
      if (recall != null) recall,
      if (cue != null) cue,
      prompt,
      if (hint != null) hint,
    ].join('\n\n');

    // Two grey ticks: the companion has it and is composing.
    _setDelivery(userMessage.id, MessageDelivery.processing);

    String reply;
    try {
      reply = await _generate(fullPrompt);

      // The sampler seed is fixed for the life of a conversation, so a reply
      // that has already been given will keep being given. Rebuilding on a
      // fresh seed is the only lever the runtime offers — see
      // LiteRtService.reseed. Once only: if it repeats twice the problem is the
      // model's distribution, not the seed, and retrying again just costs the
      // user another re-prefill.
      if (_isRepeat(reply)) {
        final err = await _liteRtService.reseed(history: _replayHistory());
        if (err == null && mounted) {
          reply = await _generate(fullPrompt);
        }
      }
    } catch (err) {
      if (!mounted) return;
      await _emitSystem('Something went wrong during inference: $err');
      setState(() => _isGenerating = false);
      return;
    }

    if (!mounted) return;

    // Boundary enforcement, after generation and before the screen. A prompt
    // instruction makes "I'm a real person" rare; only this makes it never
    // arrive. Offending sentences are removed rather than the whole reply
    // regenerated — regeneration costs another 15–30 s and may violate again.
    //
    // Cheaper than it used to be, too: the reply is no longer on screen while
    // it is being written, so a rewritten sentence is never seen and then
    // retracted.
    final outputVerdict = _guard.screenOutput(reply);
    if (!outputVerdict.isAllowed) {
      debugPrint('Guard rewrote a reply: ${outputVerdict.reason}');
      reply = outputVerdict.replacement!;
    }

    // Blue: the reply exists. Only now does the companion appear to start
    // typing — the order matters, because "read, then typing, then a message"
    // is the sequence a person produces, and the old behaviour (typing dots
    // appearing the instant you hit send, then a reply assembling itself word
    // by word) is the sequence a machine produces.
    _setDelivery(userMessage.id, MessageDelivery.read);
    await _showTyping(reply);
    if (!mounted) return;

    final replyMessage = ChatMessage(
      id: _newId(),
      role: ChatRole.companion,
      text: reply,
      createdAt: DateTime.now(),
    );
    setState(() {
      _messages
        ..removeWhere((m) => m.id == _typingSlotId)
        ..add(replyMessage);
    });
    _scrollToBottom();
    await _chatStore.append(replyMessage);

    // The user's own words, not `fullPrompt`: the recalled-facts block is
    // scaffolding for one turn, and replaying it on a reseed would re-inject
    // facts chosen for a message that is no longer the current one.
    _remember(prompt, reply);

    // Index the completed exchange so it can be retrieved months from now, and
    // push the check-in timer out. Neither belongs in the reply path.
    unawaited(() async {
      try {
        await _chunks.addExchange(userText: prompt, replyText: reply);
        // Anything learned this turn becomes visible to the *next* conversation
        // without another database read on the send path.
        await _cache.refreshProfile();
        await _nudges.rearm();
      } catch (e) {
        debugPrint('Post-turn write failed: $e');
      }
    }());

    setState(() => _isGenerating = false);

    // Offered *after* the companion has answered, so the user gets a real
    // reply first and the resource reads as an addition rather than a
    // deflection. Once per session — repeating it would nag.
    if (_concernTurns >= _concernBeforeOffer && !_offeredSupport) {
      _offeredSupport = true;
      await _emitSystem(CrisisGuard.gentleOffer());
    }
    _scrollToBottom();
  }

  /// Appends an app-authored line, on screen and on disk.
  ///
  /// Stored with `sentToModel: false` so it survives a restart like any other
  /// turn but is never replayed to the model as something it said.
  Future<void> _emitSystem(String text) async {
    final message = _system(text);
    await _chatStore.append(message);
    if (!mounted) return;
    setState(() => _messages.add(message));
    _scrollToBottom();
  }

  /// Moves a user message's ticks on.
  void _setDelivery(String id, MessageDelivery delivery) {
    if (!mounted) return;
    final index = _messages.indexWhere((m) => m.id == id);
    if (index < 0) return;
    setState(() {
      _messages[index] = _messages[index].copyWith(delivery: delivery);
    });
  }

  /// The id of the transient "…" bubble, if one is showing.
  String? _typingSlotId;

  /// Shows the typing indicator for a believable length of time.
  ///
  /// The reply is already complete when this runs — this is purely the pause
  /// before it lands. Scaled by length, because a paragraph arriving as fast as
  /// "yeah, same" is the tell that nobody is really there. Bounded at both
  /// ends: under [_typingMin] it flickers, and past [_typingMax] the user is
  /// being made to wait for a message that already exists.
  Future<void> _showTyping(String reply) async {
    final slot = ChatMessage(
      id: _newId(),
      role: ChatRole.companion,
      text: '',
      createdAt: DateTime.now(),
      sentToModel: false,
    );
    _typingSlotId = slot.id;
    if (!mounted) return;
    setState(() => _messages.add(slot));
    _scrollToBottom();

    final ms = (_typingMin.inMilliseconds + reply.length * 11)
        .clamp(_typingMin.inMilliseconds, _typingMax.inMilliseconds);
    await Future.delayed(Duration(milliseconds: ms));
  }

  static const Duration _typingMin = Duration(milliseconds: 700);
  static const Duration _typingMax = Duration(milliseconds: 2600);

  /// Streams one reply into the last message slot, completing with the raw text.
  ///
  /// The slot is rewritten on every chunk with [ReplySanitizer] applied to the
  /// accumulated text, so `_comma_` artifacts never reach the screen. The raw
  /// text is what completes, because that is what the model actually said and
  /// what repeat detection and the replay transcript should be based on.
  Future<String> _generate(String prompt) {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    StreamSubscription<String>? subscription;

    // Both of these exist only for the fine-tune's defects, so on stock they
    // are skipped entirely rather than run to no effect. See
    // ModelProfile.repairsOutput.
    final repairs = _settings.profile.repairsOutput;

    /// Reports whether the model has started looping.
    ///
    /// The expensive one: it re-scans the whole accumulated reply on every
    /// chunk. Worth it on a model that mode-collapses and will otherwise repeat
    /// one sentence to the token limit; pure waste on one that does not.
    bool isLooping() {
      if (!repairs) return false;
      final sanitized =
          ReplySanitizer.cleanDetailed(buffer.toString(), streaming: true);
      return sanitized.droppedSentences >= _loopTolerance;
    }

    subscription = _liteRtService.generateResponseStream(prompt).listen(
      (chunk) {
        buffer.write(chunk);
        // Once it is repeating there is nothing left to wait for — it will run
        // to the token limit saying the same thing. Cutting it short saves the
        // user waiting out the rest of a generation that has nothing to add.
        if (isLooping()) {
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.complete(_finish(buffer, repairs: repairs));
          }
        }
      },
      onError: (err) {
        subscription?.cancel();
        if (!completer.isCompleted) completer.completeError(err);
      },
      onDone: () {
        subscription?.cancel();
        if (!completer.isCompleted) completer.complete(buffer.toString());
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  /// The finished reply.
  ///
  /// With [repairs], escapes are decoded and degenerate repeats dropped —
  /// applied once here rather than on every painted frame. That also closes a
  /// bug the streaming version had: the screen showed sanitized text while
  /// `ChatStore` was written the *raw* string, so `_comma_` artifacts that were
  /// never displayed reappeared when the conversation was restored.
  ///
  /// Without it, the model's own words go through untouched. `_comma_` is an
  /// artifact of the fine-tune's training corpus and stock Gemma cannot produce
  /// it, so there is nothing here to repair — and rewriting a healthy model's
  /// output is a way to introduce faults, not remove them.
  ///
  /// Note this is *not* a relaxation of the guardrails: `LexicalGuard` screens
  /// every reply regardless of profile, and that is the layer that enforces
  /// boundaries.
  static String _finish(StringBuffer buffer, {required bool repairs}) {
    final raw = buffer.toString();
    if (!repairs) return raw.trim();
    return ReplySanitizer.cleanDetailed(raw, streaming: false).text;
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
    final longest = keys.reduce((a, b) => b.length > a.length ? b : a);
    // Too short to be evidence of a loop. Now that the companion talks like a
    // friend rather than a clinician, replies are often a single line, and a
    // person genuinely does say "that sounds rough" twice in a conversation
    // without malfunctioning. Without this floor that natural repetition
    // triggers a reseed — several seconds of re-prefill, and the companion
    // loses the thread — as a penalty for sounding human.
    return longest.length < _minSubstanceLength ? '' : longest;
  }

  /// Shortest reply that can count as a repeat.
  static const int _minSubstanceLength = 30;

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
        // reconfigure() discards conversation history, so the replay transcript
        // and repeat history go with it — otherwise they describe a
        // conversation the model is no longer in.
        _recentOpeners.clear();
        _recentReplies.clear();
        _modelTranscript.clear();
      });
      await _emitSystem(
        err == null
            ? 'Sampler updated ($updated). The companion has lost the '
                'earlier thread.'
            : 'Could not apply sampler settings: $err',
      );
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  msg.text,
                  style: OrganicText.bubble(
                    isUser ? t.userBubbleFg : t.assistantBubbleFg,
                    size: s.bubbleFontSize,
                  ),
                ),
                if (isUser) ...[
                  const SizedBox(height: 3),
                  _DeliveryTicks(
                    delivery: msg.delivery,
                    pending: t.userBubbleFg.withValues(alpha: 0.55),
                    size: s.bubbleFontSize,
                  ),
                ],
              ],
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
          for (final p in QuickPrompt.all)
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
                  enabled: !_isGenerating && !_loadingHistory,
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

/// Delivery ticks on a user's own bubble.
///
/// One grey tick while the model is still loading, two once it is composing,
/// two blue once the reply exists. Drawn with Material's `done` / `done_all`
/// rather than a custom glyph — the shape is the part people recognise, and it
/// is one they have read a thousand times without being taught.
class _DeliveryTicks extends StatelessWidget {
  final MessageDelivery delivery;

  /// Colour before the reply exists — the bubble's own foreground, faded, so
  /// the ticks stay quiet until they have something to say.
  final Color pending;

  final double size;

  const _DeliveryTicks({
    required this.delivery,
    required this.pending,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final read = delivery == MessageDelivery.read;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Icon(
        delivery == MessageDelivery.sent ? Icons.done : Icons.done_all,
        // Keyed so the switcher animates between states rather than treating
        // a recoloured icon as the same widget.
        key: ValueKey(delivery),
        size: size,
        color: read ? Organic.tickRead : pending,
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
