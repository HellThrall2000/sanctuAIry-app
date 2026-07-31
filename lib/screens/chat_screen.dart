import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import '../models/journal_entry.dart';
import '../models/memory_fact.dart';
import '../services/memory_store.dart';
import '../services/crisis_guard.dart';
import '../services/litert_service.dart';
import '../services/model_preference.dart';
import '../services/model_profile.dart';
import '../services/model_settings.dart';
import '../services/persona.dart';
import '../services/reply_sanitizer.dart';
import '../widgets/dev_settings_sheet.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({required this.text, required this.isUser, required this.timestamp});
}

class ChatScreen extends StatefulWidget {
  final List<JournalEntry> allowedJournals;

  const ChatScreen({Key? key, required this.allowedJournals}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
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

  /// Cached personal facts, rendered for the prompt. Read once when the model is
  /// initialised — see [MemoryStore] for why it is not refreshed mid-session.
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
  /// file is located and its profile is known — see [_prepareModel].
  ModelSettings _settings = ModelSettings();

  @override
  void initState() {
    super.initState();

    // Add welcome greeting
    _messages.add(ChatMessage(
      text: "Welcome to your personal Sanctuary companion. I am an on-device, fully-offline intelligence. I have zero access to the cloud, meaning our conversation never leaves this mobile device.\n\nHow can I support your reflections or mindfulness today?",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  /// Persona plus any journals the user unlocked for this session.
  ///
  /// How much persona the model can take depends on which model it is — see
  /// [Persona.instructionFor] and [ModelProfile]. Stock Gemma 4 E2B follows a
  /// full persona; the fine-tune answers substantive prompts with session-opener
  /// boilerplate when given one, so it gets safety text only.
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

    // Cached personal facts, carried across sessions. Unlike the journal dump
    // below this is bounded (MemoryStore.maxProfileFacts) and does not grow with
    // use.
    if (_profileBlock != null) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(_profileBlock);
    }

    if (widget.allowedJournals.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(
        "The user unlocked these private journal entries and approved them "
        "for this conversation:",
      );
      for (final entry in widget.allowedJournals) {
        buffer.writeln();
        buffer.writeln("Title: ${entry.title}");
        buffer.writeln("Date: ${entry.date.split('T').first}");
        buffer.writeln("Content: ${entry.content}");
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
      _messages.add(ChatMessage(text: prompt, isUser: true, timestamp: DateTime.now()));
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

    // Learn from what the user just said. Deterministic and instant, so it costs
    // nothing on the turn — see FactExtractor for why this is not a model pass.
    // Not awaited into the reply path: a failed write must never block a
    // conversation.
    unawaited(_memory.learnFromMessage(prompt).catchError((Object e) {
      debugPrint('Memory write failed: $e');
      return <MemoryFact>[];
    }));

    // Lazy load the model on first prompt
    if (!_liteRtService.isInitialized) {
      final statusMessageIndex = _messages.length;
      setState(() {
        _messages.add(ChatMessage(
          text: "⚡ Initializing local LiteRT Engine (mapping 2.5GB model file into memory, please wait a few seconds)...",
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
        if (error != null) {
          setState(() {
            _messages[statusMessageIndex] = ChatMessage(
              text: "Failed to initialize companion: $error",
              isUser: false,
              timestamp: DateTime.now(),
            );
            _isGenerating = false;
          });
          _scrollToBottom();
          return;
        } else {
          // Remove initialization status message once ready
          setState(() {
            _messages.removeAt(statusMessageIndex);
          });
        }
      } else {
        setState(() {
          _messages[statusMessageIndex] = ChatMessage(
            text: "Companion Offline: Could not find the model file on device.",
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
    // The only addition is a one-line nudge when the companion has been opening
    // replies the same way. It is omitted entirely when there is nothing to
    // avoid, so we don't pay the tokens on every turn.
    // Facts relevant to *this* message. The pinned profile is fixed at
    // conversation creation, so anything beyond it has to arrive with the turn —
    // rebuilding the system instruction per turn would mean re-prefilling the
    // whole history. Usually null: FactRanker only fires on a real match, which
    // keeps short messages from being swamped by meta-text.
    final recall = await _memory
        .recallBlock(prompt)
        .catchError((Object e) => null);

    final hint = Persona.repetitionHint(_recentOpeners);
    final fullPrompt = [
      if (recall != null) recall,
      prompt,
      if (hint != null) hint,
    ].join('\n\n');

    // Initialize blank message slot for streaming output
    final streamingMessage = ChatMessage(text: "", isUser: false, timestamp: DateTime.now());
    setState(() {
      _messages.add(streamingMessage);
    });

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
          text: "Failed during edge inference: $err",
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

    /// Repaints the slot and reports whether the model has started looping.
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

    // Bound the re-prefill and let old attractors age out of context.
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
  /// [DevSettingsSheet]). Reachable by long-pressing the input field, which
  /// keeps it out of the way of normal use.
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
              ? "Sampler updated ($updated). The companion has lost the earlier thread."
              : "Could not apply sampler settings: $err",
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

  @override
  Widget build(BuildContext context) {
    // Strictly dark themed per specs
    const accentColor = Color(0xFF00E5FF);
    const inputBg = Color(0xFF0A0A0A);

    return Scaffold(
      backgroundColor: Colors.transparent, // Inherits deep black from main.dart
      body: Column(
        children: [
          // Conversation Area
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg, accentColor);
              },
            ),
          ),

          // First token loading indicator
          if (_isGenerating && _messages.isNotEmpty && _messages.last.text.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: accentColor, strokeWidth: 2),
              ),
            ),

          // Typing Input Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: inputBg,
              border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
            ),
            child: Row(
              children: [
                Expanded(
                  // Long-press opens the sampler panel in debug builds; it is a
                  // no-op in release, so normal users never see it.
                  child: GestureDetector(
                    onLongPress: _openDevSettings,
                    child: TextField(
                    controller: _textController,
                    maxLines: null,
                    enabled: !_isGenerating,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: "Write your thoughts...",
                      hintStyle: TextStyle(fontSize: 14, color: Color(0xFF555555)),
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(fontSize: 14, color: Color(0xFFE2E6E9)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _isGenerating ? null : _sendMessage,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                    child: _isGenerating
                        ? const Icon(Icons.stop_rounded, color: Colors.black, size: 20)
                        : const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildMessageBubble(ChatMessage msg, Color accentColor) {
    final textColor = const Color(0xFFE2E6E9);
    final align = msg.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    // Don't show an empty bubble when first token is loading
    if (!msg.isUser && msg.text.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: BoxDecoration(
              border: Border(
                left: !msg.isUser ? BorderSide(color: accentColor, width: 2) : BorderSide.none,
                right: msg.isUser ? BorderSide(color: accentColor, width: 2) : BorderSide.none,
              ),
              color: const Color(0xFF0A0A0A),
            ),
            child: Text(
              msg.text,
              style: TextStyle(fontSize: 14, height: 1.45, color: textColor),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            msg.isUser ? "You" : "Sanctuary On-Device Model",
            style: const TextStyle(fontSize: 9, color: Color(0xFF555555), fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
