import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../../models/chat_message.dart';
import '../../models/journal_entry.dart';
import '../../models/memory_fact.dart';
import '../../models/sentiment.dart';
import '../../services/background_generation.dart';
import '../../services/chat_store.dart';
import '../../services/chunk_store.dart';
import '../../services/context_budget.dart';
import '../../services/crisis_guard.dart';
import '../../services/event_store.dart';
import '../../services/guard.dart';
import '../../services/litert_service.dart';
import '../../services/memory_cache.dart';
import '../../services/memory_store.dart';
import '../../services/model_preference.dart';
import '../../services/model_settings.dart';
import '../../services/notification_service.dart';
import '../../services/nudge_service.dart';
import '../../services/persona.dart';
import '../../services/quick_prompts.dart';
import '../../services/relationship_log.dart';
import '../../services/reply_sanitizer.dart';
import '../../services/sentiment_analyzer.dart';
import '../../services/session_summarizer.dart';
import '../../services/topic_extractor.dart';
import '../../services/usage_metrics.dart';
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

    await _answerUnansweredMessage();
    await _deliverPendingNudge();
  }

  /// Answers the last message if the app closed before the reply arrived.
  ///
  /// **Every message gets a reply, without exception.** Generation takes 15–30
  /// seconds, and anything can happen in that window: the user switches apps,
  /// the screen locks, Android reclaims the process for memory — which, with a
  /// 2.5 GB model resident, it does readily. The reply was lost and nothing
  /// ever retried, so the message sat on a single grey tick permanently and the
  /// conversation had a hole in it.
  ///
  /// [_withDerivedDelivery] already *detects* this — a trailing user turn with
  /// nothing after it is marked `sent` rather than `read` — so the state was
  /// visible on screen and simply never acted on. This acts on it.
  ///
  /// Deliberately runs before the nudge check: answering what the user actually
  /// said comes before the companion volunteering something new.
  Future<void> _answerUnansweredMessage() async {
    if (_messages.isEmpty || _isGenerating) return;

    final last = _messages.last;
    if (!last.isUser || last.delivery == MessageDelivery.read) return;

    // Re-read rather than trusting the stored value: mood is cheap, lexical,
    // and a message restored from an older build may predate the column.
    final mood = last.mood ?? SentimentAnalyzer.read(last.text);

    setState(() => _isGenerating = true);
    await _respondTo(last, mood, afterRestart: true);
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
    final recent = _modelTranscript.length <= limit
        ? List.of(_modelTranscript)
        : _modelTranscript.sublist(_modelTranscript.length - limit);

    // Six exchanges is a count, not a size, and six long ones do not fit. On
    // device this prefilled ~1300 tokens of history before a word was typed,
    // which the budget never saw because it only ever measured what it was
    // about to add. Bound it the same way everything else is bounded.
    return _withinBudget(recent, _budgetForHistory(null));
  }

  /// Tokens left for conversation history once the fixed costs are counted.
  ///
  /// [prompt] is the turn about to be sent, or null when budgeting before one
  /// exists — see [ContextBudget.assumedPromptChars].
  int _budgetForHistory(String? prompt) => ContextBudget.availableForHistory(
        systemInstructionChars: _buildSystemInstruction()?.length ?? 0,
        promptChars: prompt?.length ?? ContextBudget.assumedPromptChars,
      );

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

    final instruction = buffer.toString();

    // What the fixed part of every prompt actually costs.
    //
    // This is carried on every single turn whether or not it bears on what was
    // just said, so it is the first thing to look at when the companion seems
    // to be attending to background rather than to the user. Reading it as a
    // share of the 4096-token window is the number that matters — a 2B model
    // given far more background than message will answer the background.
    assert(() {
      final personaTokens = ContextBudget.estimateTokens(persona ?? '');
      final knowledgeTokens = ContextBudget.estimateTokens(knowledge ?? '');
      final total = personaTokens + knowledgeTokens;
      debugPrint(
        'System instruction: $total tokens '
        '(${(total / ContextBudget.maxTokens * 100).round()}% of the window) '
        '— persona $personaTokens, knowledge $knowledgeTokens',
      );
      return true;
    }());

    return instruction;
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
    // A count, nothing more. UsageMetrics is given no argument here on purpose:
    // there is no parameter through which the message itself could ever reach
    // it, by accident or otherwise.
    UsageMetrics.instance.recordMessageSent();
    await _chatStore.append(userMessage);
    await Future.delayed(const Duration(milliseconds: 150));

    await _respondTo(userMessage, mood);
  }

  /// Answers a user turn that is already on screen and already stored.
  ///
  /// Split out of [_sendMessage] so the identical pipeline — crisis triage,
  /// guards, memory, context budget, generation, repair — serves both a message
  /// just typed and one left unanswered when the app closed. Two code paths
  /// would drift, and the one that drifted would be the rarely-exercised one.
  ///
  /// [afterRestart] marks the second case — the reply is arriving in a session
  /// the user did not watch it being written in, which is what decides whether
  /// it quotes the message it answers. See [_shouldQuote].
  Future<void> _respondTo(
    ChatMessage userMessage,
    MoodReading mood, {
    bool afterRestart = false,
  }) async {
    final prompt = userMessage.text;

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
          // Resolve the tick. Without this the message sits on a single grey
          // tick forever — "written down, never delivered" — which is exactly
          // what a user reported after a long conversation. The failure is
          // explained in the system line; leaving the tick unresolved on top of
          // that just makes the app look broken in a second way.
          _setDelivery(userMessage.id, MessageDelivery.read);
          await _emitSystem('The companion could not start: $error');
          setState(() => _isGenerating = false);
          return;
        }
        UsageMetrics.instance.recordModelReady();
      } else {
        _setDelivery(userMessage.id, MessageDelivery.read);
        await _emitSystem(
          'The companion has not been downloaded yet — you can start that in '
          'Settings.',
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

    // Make room before generating rather than discovering there was none.
    // Overflow does not fail loudly — it degrades — so it has to be prevented
    // rather than detected.
    await _trimContextIfNeeded(fullPrompt);

    // Hold the process alive for the duration. Without this, switching away
    // mid-generation loses the reply outright: a backgrounded app holding a
    // 2.5 GB model is the first thing Android reclaims. Started here, while the
    // app is definitely foreground, which is what `shortService` requires.
    await BackgroundGeneration.instance.begin();

    String reply;
    try {
      reply = await _generateWithinWindow(
        fullPrompt,
        onStart: () => _beginTyping(userMessage.id),
      );

      // The sampler seed is fixed for the life of a conversation, so a reply
      // that has already been given will keep being given. Rebuilding on a
      // fresh seed is the only lever the runtime offers — see
      // LiteRtService.reseed. Once only: if it repeats twice the problem is the
      // model's distribution, not the seed, and retrying again just costs the
      // user another re-prefill.
      // A reply that sanitises down to almost nothing is the same underlying
      // fault as a repeat and takes the same remedy. The model pads to fill a
      // length, `ReplySanitizer` strips the padding, and what is left can be a
      // fragment — the stress run produced a companion turn containing the
      // single character "I", which reached the screen because nothing checked.
      //
      // Reseeding is the only lever the runtime offers: the sampler seed is
      // fixed for the life of a conversation, so regenerating without it returns
      // the same text. Once only — if it comes back short twice the problem is
      // the model's distribution rather than the seed, and a third attempt just
      // costs the user another re-prefill.
      if (_isRepeat(reply) || !ReplySanitizer.cleanDetailed(reply).isUsable) {
        final err =
            await _liteRtService.reseed(history: _replayHistory(fullPrompt));
        if (err == null && mounted) {
          final retry = await _generateWithinWindow(
            fullPrompt,
            onStart: () => _beginTyping(userMessage.id),
          );
          // Keep the retry only if it is actually better. A worse second
          // attempt should not replace a usable first one.
          if (ReplySanitizer.cleanDetailed(retry).isUsable ||
              retry.trim().length > reply.trim().length) {
            reply = retry;
          }
        }
      }
    } catch (err) {
      if (!mounted) return;
      // Otherwise this one stalls on two grey ticks — delivery was already set
      // to `processing` before generation began.
      _setDelivery(userMessage.id, MessageDelivery.read);
      // A failure after the first token leaves the dots animating over a reply
      // that is never coming.
      _clearTypingSlot();
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

    // Both already happened, at the first token — see [_beginTyping]. This is
    // the backstop for the paths that reach here without one: a reply repaired
    // from an empty generation, or a guard replacement. Setting a delivery that
    // is already `read` is a no-op.
    _setDelivery(userMessage.id, MessageDelivery.read);
    await _settleTyping();
    if (!mounted) return;

    final replyMessage = ChatMessage(
      id: _newId(),
      role: ChatRole.companion,
      text: reply,
      createdAt: DateTime.now(),
      replyToId: _shouldQuote(userMessage, afterRestart: afterRestart)
          ? userMessage.id
          : null,
    );
    _clearTypingSlot();
    setState(() => _messages.add(replyMessage));
    _scrollToBottom();
    await _chatStore.append(replyMessage);

    // If they walked away while this was being written, tell them it arrived.
    // Checked here rather than at send time because what matters is where they
    // are *now* — a reply that lands while they are watching needs no
    // notification, and one for a message already on screen is just noise.
    if (BackgroundGeneration.instance.isAppInBackground) {
      unawaited(NotificationService.instance.showReply(reply).catchError(
        (Object e) => debugPrint('Reply notification failed: $e'),
      ));
    }

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

    // Released however generation ended. Leaving it running would pin a
    // permanent notification and hold the process awake.
    await BackgroundGeneration.instance.end();

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

  /// When the typing indicator went up, for [_settleTyping].
  DateTime? _typingStartedAt;

  /// Marks the message read and starts the typing indicator.
  ///
  /// Called from [_generate] on the first chunk, so both signals mean the same
  /// thing: **the companion is writing, right now.** They used to fire on
  /// completion instead, which put them in the wrong place — the ticks turned
  /// blue and the dots appeared after the reply already existed, so the dots
  /// were an animation of nothing and the long, genuinely uncertain wait was
  /// the part with no feedback at all. Two pale ticks now cover exactly the
  /// stretch where the model has the message but has not started, and blue
  /// covers exactly the stretch where it is producing text.
  ///
  /// Idempotent: the repeat-breaker and the overflow recovery both call
  /// [_generate] a second time, and the companion does not stop writing in
  /// between.
  void _beginTyping(String userMessageId) {
    if (!mounted || _typingSlotId != null) return;

    _setDelivery(userMessageId, MessageDelivery.read);

    final slot = ChatMessage(
      id: _newId(),
      role: ChatRole.companion,
      text: '',
      createdAt: DateTime.now(),
      sentToModel: false,
    );
    _typingSlotId = slot.id;
    _typingStartedAt = DateTime.now();
    setState(() => _messages.add(slot));
    _scrollToBottom();
  }

  /// Holds the indicator on screen long enough to have been seen.
  ///
  /// Generation takes tens of seconds, so in practice this waits for nothing.
  /// It exists for the paths that finish almost immediately — a cached refusal,
  /// a reply cut short by the loop detector — where dots that appear and vanish
  /// inside one frame read as a glitch rather than as thinking.
  Future<void> _settleTyping() async {
    final since = _typingStartedAt;
    if (since == null) return;
    final shown = DateTime.now().difference(since);
    if (shown < _typingMin) await Future.delayed(_typingMin - shown);
  }

  /// Takes the "…" bubble down, wherever the turn ended.
  ///
  /// Also clears the id, which the old code did not — leaving it set made
  /// [_beginTyping] a no-op forever after the first reply.
  void _clearTypingSlot() {
    final slot = _typingSlotId;
    _typingSlotId = null;
    _typingStartedAt = null;
    if (slot == null || !mounted) return;
    setState(() => _messages.removeWhere((m) => m.id == slot));
  }

  static const Duration _typingMin = Duration(milliseconds: 700);

  /// Streams one reply into the last message slot, completing with the raw text.
  ///
  /// The slot is rewritten on every chunk with [ReplySanitizer] applied to the
  /// accumulated text, so `_comma_` artifacts never reach the screen. The raw
  /// text is what completes, because that is what the model actually said and
  /// what repeat detection and the replay transcript should be based on.
  /// [onStart] fires the moment the model has actually produced something —
  /// the first chunk with text in it. That is the only honest signal that
  /// generation began: the runtime can accept a prompt and then fail before
  /// emitting a token, so anything earlier would be a promise the app cannot
  /// keep.
  Future<String> _generate(String prompt, {VoidCallback? onStart}) {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    StreamSubscription<String>? subscription;
    var started = false;

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
        if (!started && buffer.isNotEmpty) {
          started = true;
          onStart?.call();
        }
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
  List<LiteLmMessage> _replayHistory(String prompt) {
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
    final capped =
        kept.length <= limit ? kept : kept.sublist(kept.length - limit);

    // Twelve exchanges is a count, and the window is measured in tokens. This
    // reseed happens mid-turn with the prompt already in hand, so there is no
    // excuse for guessing at what fits.
    return _withinBudget(capped, _budgetForHistory(prompt));
  }

  /// The most recent exchanges that fit the context window, newest kept.
  ///
  /// Whole exchanges, so a user turn is never left without the reply it
  /// received — a dangling question reads to the model as one it still has to
  /// answer.
  List<LiteLmMessage> _historyWithinBudget(int budgetTokens) =>
      _withinBudget(_modelTranscript, budgetTokens);

  /// [turns] reduced to the most recent whole exchanges that fit
  /// [budgetTokens].
  ///
  /// Applied to *every* list of turns handed to the engine, because a reseed
  /// rebuilds the conversation from exactly what it is given — so any unbounded
  /// list is an unbounded context window. Both callers used to be unbounded in
  /// their own way: the resume window was a fixed six exchanges regardless of
  /// how long each one was, and the repeat-breaker replayed up to twelve.
  static List<LiteLmMessage> _withinBudget(
    List<LiteLmMessage> turns,
    int budgetTokens,
  ) {
    if (turns.length < 2) return const [];

    final kept = <LiteLmMessage>[];
    var used = 0;

    // Backwards in pairs: recency is what the window is for.
    for (var i = turns.length - 2; i >= 0; i -= 2) {
      final cost = ContextBudget.estimateTokens(turns[i].text) +
          ContextBudget.estimateTokens(turns[i + 1].text);

      // **The newest exchange is kept whatever it costs.** It is the one the
      // next reply actually has to answer — summarising it would compact away
      // the very thing being responded to, and a companion that has forgotten
      // the sentence it is replying to is worse than one that has forgotten
      // last week. Everything above it is fair game for compaction.
      final isNewest = i == turns.length - 2;
      if (!isNewest && used + cost > budgetTokens) break;

      used += cost;
      kept.insertAll(0, [turns[i], turns[i + 1]]);
    }
    return kept;
  }

  /// Rebuilds the conversation on a shorter history when the window is full.
  ///
  /// **The live conversation had no bound at all.** Resuming after a restart
  /// replayed six exchanges, but within one session `LiteLmConversation`
  /// accumulated every turn until the 4096-token KV cache overflowed — which
  /// does not raise an error, it degrades: grammar decays, then tokens from
  /// unrelated scripts appear, then nothing parses. A tester's screenshots
  /// showed that whole progression.
  ///
  /// Nothing is lost. Dropped exchanges remain in `ChunkStore` and return
  /// through retrieval when they are relevant, which is what episodic memory is
  /// for. The window carries recency; retrieval carries the rest.
  ///
  /// Reseeding is the only mechanism the runtime offers — there is no way to
  /// evict turns from a conversation in place, so it is rebuilt from a trimmed
  /// history. That costs a re-prefill, so it is done only when the next turn
  /// would genuinely not fit.
  Future<void> _trimContextIfNeeded(String prompt) async {
    if (!_liteRtService.isInitialized) return;

    final systemChars = _buildSystemInstruction()?.length ?? 0;
    if (ContextBudget.isSystemInstructionOversized(systemChars)) {
      // The caps on facts, digests and summaries are individually sound but
      // nothing caps their sum. If this fires, that is the bug.
      debugPrint(
        'System instruction is $systemChars chars — too large to hold a '
        'conversation. Check MemoryCache caps.',
      );
    }

    final budget = _budgetForHistory(prompt);

    var used = 0;
    for (final message in _modelTranscript) {
      used += ContextBudget.estimateTokens(message.text);
    }
    if (used <= budget) return;

    // Leave room for the compaction summary itself, or adding it would push
    // the rebuilt conversation straight back over the line.
    final trimmed = _historyWithinBudget(budget - _compactionReserve);

    // Everything about to fall out of the window, compacted rather than
    // discarded. Without this the companion forgets, mid-conversation,
    // something the user said ten minutes ago — retrieval only brings it back
    // if a later message happens to match it lexically, which is not something
    // the thread of a live conversation can rely on.
    final droppedUserTurns = <String>[];
    for (var i = 0; i + 1 < _modelTranscript.length - trimmed.length; i += 2) {
      droppedUserTurns.add(_modelTranscript[i].text);
    }
    final summary = SessionSummarizer.compact(droppedUserTurns);

    final rebuilt = <LiteLmMessage>[
      if (summary != null) ...[
        LiteLmMessage.user(summary),
        // A brief acknowledgement so the summary sits in the conversation as a
        // completed exchange. Seeding the model's side is the same mechanism
        // Persona.exemplars uses; an unanswered turn reads as one still owed a
        // reply.
        LiteLmMessage.model('Got it — I remember all of that.'),
      ],
      ...trimmed,
    ];

    debugPrint(
      'Context full (~$used tokens, budget $budget). Compacting '
      '${droppedUserTurns.length} older turns into '
      '${summary == null ? 'nothing' : '${ContextBudget.estimateTokens(summary)} tokens'}, '
      'keeping ${trimmed.length ~/ 2} exchanges.',
    );

    // Sampling stays where it was. `reseed` defaults to the escape multiplier
    // because its original caller was the repeat-breaker, but running out of
    // window is not evidence of a peaked distribution — it is just a long
    // conversation. Widening temperature here would make the companion audibly
    // stranger every time the context filled, for no reason at all.
    final err = await _liteRtService.reseed(
      history: rebuilt,
      temperatureMultiplier: 1.0,
    );
    if (err != null) {
      debugPrint('Context compaction failed, continuing uncut: $err');
    }
  }

  /// Whether this reply should name the message it answers.
  ///
  /// Messaging apps quote sparingly, and for one reason: the message being
  /// answered is no longer obviously the one above. In a strict back-and-forth
  /// it always is, so quoting every turn would be clutter on a screen whose
  /// whole job is to feel calm. Two situations genuinely break that:
  ///
  ///  * **[afterRestart]** — the app closed before the reply was written and
  ///    this is the relaunch answering it. The message can be hours old with a
  ///    session boundary in between, and an unattributed reply appearing under
  ///    it reads as the companion raising something new rather than finally
  ///    getting back to them.
  ///  * **A run of unanswered turns** — the user kept typing while the model
  ///    was still loading or still composing, so there are several candidates
  ///    for what "this" refers to.
  bool _shouldQuote(ChatMessage target, {required bool afterRestart}) =>
      afterRestart || _unansweredUserTurns(target) > _quoteAfterUserTurns;

  /// A run of user turns longer than this is treated as ambiguous.
  ///
  /// Three is the point at which a reply stops obviously belonging to the line
  /// above it. Below that, quoting says less than the position already does.
  static const int _quoteAfterUserTurns = 3;

  /// How many user turns are waiting on a reply, counting back from [target].
  ///
  /// App-authored lines are skipped rather than counted or treated as a break:
  /// a banner or a nudge sitting between two user messages answers neither of
  /// them, so it must not end the run.
  int _unansweredUserTurns(ChatMessage target) {
    final index = _messages.indexWhere((m) => m.id == target.id);
    if (index < 0) return 1;

    var count = 0;
    for (var i = index; i >= 0; i--) {
      final message = _messages[i];
      if (message.role == ChatRole.companion) break;
      if (message.isUser) count++;
    }
    return count;
  }

  /// Generates, and if the window overflows anyway, answers from an empty one.
  ///
  /// The budget is an estimate. The SentencePiece vocabulary lives inside the
  /// `.litertlm` and is not reachable from Dart, so [ContextBudget] counts
  /// characters and divides — which can be wrong in the dangerous direction on
  /// text that tokenises badly. When it is, the runtime refuses the prompt with
  /// `Input token ids are too long`, and before this that cost the user the
  /// turn outright: two grey ticks, no reply, no error on screen. **A companion
  /// is allowed to forget the conversation. It is not allowed to not answer.**
  ///
  /// Dropping the history entirely rather than trimming it again is deliberate.
  /// Being here means the estimate has already been proved wrong once, so a
  /// second estimate is not worth betting the reply on. Nothing is destroyed —
  /// the dropped turns are still in `ChunkStore` and come back through
  /// retrieval on the next message, which is what episodic memory is for.
  Future<String> _generateWithinWindow(
    String prompt, {
    VoidCallback? onStart,
  }) async {
    try {
      return await _generate(prompt, onStart: onStart);
    } catch (err) {
      if (!LiteRtService.isContextOverflow(err)) rethrow;
      debugPrint('Context overflowed past the budget; answering unaided.');
      final failed = await _liteRtService.reseed(
        history: const [],
        temperatureMultiplier: 1.0,
      );
      if (failed != null) rethrow;
      return _generate(prompt, onStart: onStart);
    }
  }

  /// Tokens held back for the compaction summary when trimming.
  ///
  /// [SessionSummarizer.compact] quotes at most three lines capped at 160
  /// characters each, plus a topic line — so this is a ceiling on its output,
  /// not a guess.
  static const int _compactionReserve = 220;

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

    // Resolved by id rather than by position, so deleting or inserting a
    // message cannot silently re-point a quote at the wrong line. A message
    // that is no longer there renders as an ordinary reply — see
    // [ChatMessage.replyToId] for why this is not a foreign key.
    final quoted = msg.replyToId == null
        ? null
        : _messages.where((m) => m.id == msg.replyToId).firstOrNull;

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
              // Ticks hang off the right of a user bubble; a quote block spans
              // the width of a companion one. With a single child these were
              // indistinguishable, which is why this used to be `.end` for both.
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (quoted != null) ...[
                  _QuotedMessage(
                    text: quoted.text,
                    foreground: t.assistantBubbleFg,
                    size: s.bubbleFontSize,
                  ),
                  const SizedBox(height: 8),
                ],
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
/// The message a reply is answering, quoted above it.
///
/// Deliberately static — there is no tap target. Making it scroll to the
/// original would need per-message keys that resolve for items `ListView`
/// has not built, which this list cannot offer; an affordance that works only
/// when the target happens to be on screen is worse than none. It costs
/// little: a quoted message is by construction the one just answered, so it is
/// almost always a short distance up the same screen.
///
/// Never rendered for user bubbles. The companion is the only participant that
/// can answer out of order.
class _QuotedMessage extends StatelessWidget {
  final String text;

  /// The bubble's own foreground, which this tints itself from — so the quote
  /// reads as a quieter register of the same voice rather than a second colour
  /// introduced into the palette.
  final Color foreground;

  final double size;

  const _QuotedMessage({
    required this.text,
    required this.foreground,
    required this.size,
  });

  /// Two lines is enough to identify a message without repeating it. The point
  /// is recognition, not re-reading — the original is directly above.
  static const int _maxLines = 2;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The accent rule, the one convention every messaging app shares for
          // this. Stretched to the quote's height by IntrinsicHeight.
          Container(
            width: 2.5,
            decoration: BoxDecoration(
              color: foreground.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                text,
                maxLines: _maxLines,
                overflow: TextOverflow.ellipsis,
                // Not selectable, unlike the reply itself: the quote is a
                // pointer to text that is already on screen and selectable
                // there. Two selectable copies of one sentence is a confusing
                // thing to hand someone.
                style: OrganicText.bubble(
                  foreground.withValues(alpha: 0.7),
                  size: size * 0.88,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
