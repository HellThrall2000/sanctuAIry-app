import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/models/chat_message.dart';
import 'package:sanctuary/services/context_budget.dart';
import 'package:sanctuary/services/litert_service.dart';

void main() {
  group('recognising a context overflow', () {
    // This is matched on message text because the runtime raises it as a
    // generic PlatformException carrying JNI output — there is no distinct
    // class to catch. If the wording ever changes upstream these tests fail,
    // which is the point: silently failing to recognise it costs the user a
    // reply.
    test('recognises the runtime error observed on device', () {
      const actual =
          'PlatformException(STREAM_ERROR, Status Code: 3. Message: Input '
          'token ids are too long. Exceeding the maximum number of tokens '
          'allowed: 4241 >= 4096, com.google.ai.edge.litertlm.'
          'LiteRtLmJniException, null)';
      expect(LiteRtService.isContextOverflow(actual), isTrue);
    });

    test('does not claim unrelated inference failures', () {
      expect(
        LiteRtService.isContextOverflow(
          StateError('LiteRT model is not initialized.'),
        ),
        isFalse,
      );
      expect(
        LiteRtService.isContextOverflow('Engine created on cpu'),
        isFalse,
      );
    });
  });

  group('budgeting before a prompt exists', () {
    test('leaves room for a long first message after a resume', () {
      // The conversation is opened at launch, before the user has written
      // anything, so the resume window has to be sized against a prompt that
      // does not exist yet. Sizing it against zero is what filled the window
      // with old turns and left nowhere to put the new one.
      final blind = ContextBudget.availableForHistory(
        systemInstructionChars: 3744,
        promptChars: ContextBudget.assumedPromptChars,
      );
      final naive = ContextBudget.availableForHistory(
        systemInstructionChars: 3744,
        promptChars: 0,
      );
      expect(blind, lessThan(naive));
      expect(blind, greaterThan(0));
    });

    test('the real system instruction still leaves usable history', () {
      // 3744 characters is the size measured on device. If the persona or the
      // memory blocks grow enough to break this, the companion has no room
      // left to remember the conversation it is having.
      expect(
        ContextBudget.isSystemInstructionOversized(3744),
        isFalse,
        reason: 'a 3744-char system instruction must still leave room to talk',
      );
    });
  });

  group('a reply that names the message it answers', () {
    test('survives a round trip through the database map', () {
      final reply = ChatMessage(
        id: 'reply-1',
        role: ChatRole.companion,
        text: 'That sounds like it has been building for a while.',
        createdAt: DateTime.now(),
        replyToId: 'user-7',
      );
      expect(ChatMessage.fromMap(reply.toMap()).replyToId, 'user-7');
    });

    test('reads rows written before the column existed', () {
      // Every message stored before v4. `replyToId` is simply absent from the
      // map, and must read as "no quote" rather than throwing.
      final legacy = ChatMessage.fromMap({
        'id': 'old-1',
        'role': 'companion',
        'text': 'I remember you saying that.',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'sentToModel': 1,
      });
      expect(legacy.replyToId, isNull);
    });

    test('copyWith keeps the link', () {
      final reply = ChatMessage(
        id: 'reply-2',
        role: ChatRole.companion,
        text: 'Still here.',
        createdAt: DateTime.now(),
        replyToId: 'user-9',
      );
      expect(reply.copyWith(text: 'Rewritten').replyToId, 'user-9');
    });
  });
}
