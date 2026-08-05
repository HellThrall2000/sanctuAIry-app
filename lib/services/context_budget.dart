import 'package:flutter/foundation.dart';

/// How much of the model's context window is spoken for, and what has to give
/// when it runs out.
///
/// **Why this exists.** The runtime reports `max_tokens: 4096`, fixed at
/// conversion time and not settable from Dart. Everything competes for it: the
/// persona, the pinned profile, diary digests, the relationship trend, past
/// session summaries, retrieved episodes, the whole conversation so far, and
/// room to actually generate a reply. Until now nothing counted any of it.
///
/// A conversation was bounded in exactly one place — six exchanges replayed when
/// the app restarts. Within a single session it grew without limit, so a long
/// enough conversation walked past 4096 and the KV cache overflowed. What that
/// looks like on screen is not an error message: it is grammar decaying, then
/// tokens from unrelated scripts, then nothing that parses. A tester's
/// screenshots showed exactly that progression.
///
/// **This is a budget, not a limit.** Nothing is deleted. Turns that fall out of
/// the window stay in `ChunkStore` and come back through BM25 retrieval when
/// something in them is relevant — which is the entire reason episodic memory
/// exists. The window holds recency; retrieval holds everything else.
@immutable
class ContextBudget {
  /// The model's context window, from the runtime's own load log.
  ///
  /// `flutter_litert_lm`'s `LiteLmEngineConfig` exposes no way to change this —
  /// it is baked into the `.litertlm` at conversion. Treat it as a hard ceiling
  /// rather than a tuning knob.
  static const int maxTokens = 4096;

  /// Held back for the reply itself.
  ///
  /// Prompt tokens and generated tokens share the window, so a full prompt
  /// leaves nothing to answer with. 700 is roughly a long text message with
  /// headroom — replies now average about 300 characters.
  static const int reserveForReply = 700;

  /// Safety margin for the chat template's own tokens.
  ///
  /// The runtime wraps every turn in `<|turn>role\n … <turn|>\n` from the
  /// template inside the model, which [estimateTokens] cannot see because it
  /// never sees the templated text. Roughly 8 tokens per turn, and being wrong
  /// in the optimistic direction is what overflow looks like.
  static const int reserveForTemplate = 250;

  /// Characters per token, for estimating without a tokenizer.
  ///
  /// The SentencePiece vocabulary is inside the `.litertlm` and is not reachable
  /// from Dart, so this is a heuristic. 3.6 rather than the usual 4.0 because
  /// under-counting is the dangerous direction: a slightly pessimistic estimate
  /// costs one extra dropped exchange, an optimistic one costs the conversation.
  static const double charsPerToken = 3.6;

  /// Rough token count for [text]. Never returns less than 1 for non-empty
  /// input.
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    final n = (text.length / charsPerToken).ceil();
    return n < 1 ? 1 : n;
  }

  /// Tokens available for conversation history, given a system instruction of
  /// [systemInstructionChars] and a turn about to be sent of [promptChars].
  ///
  /// Can be negative, which means the fixed parts alone do not fit and no
  /// history can be carried at all — see [isSystemInstructionOversized].
  static int availableForHistory({
    required int systemInstructionChars,
    required int promptChars,
  }) {
    final fixed = estimateTokens(' ' * systemInstructionChars) +
        estimateTokens(' ' * promptChars) +
        reserveForReply +
        reserveForTemplate;
    return maxTokens - fixed;
  }

  /// Whether the system instruction has grown so large that a conversation
  /// cannot be held at all.
  ///
  /// Facts, digests, the relationship trend and session summaries all accrete
  /// into it, and each is individually capped — but nothing caps the total. This
  /// is the tripwire for that: if it ever fires, the caps are wrong, not the
  /// conversation.
  static bool isSystemInstructionOversized(int systemInstructionChars) =>
      availableForHistory(
        systemInstructionChars: systemInstructionChars,
        promptChars: 0,
      ) <
      minimumHistoryTokens;

  /// Below this much room for history, the companion has no continuity worth
  /// the name and something upstream needs to shrink.
  static const int minimumHistoryTokens = 400;

  /// A stand-in prompt size, for budgeting before the prompt exists.
  ///
  /// The conversation is opened when the app starts, but the message that will
  /// be sent into it is not known until the user writes one — and by then the
  /// history has already been prefilled. Sizing the resume window against zero
  /// fills the window with old turns and leaves nowhere to put the new one.
  ///
  /// 2400 characters is not a guess: it is the size of the prompt that actually
  /// overflowed on device, a long user message plus the retrieved-episode,
  /// recalled-fact and mood-cue blocks that ride with it.
  static const int assumedPromptChars = 2400;
}
