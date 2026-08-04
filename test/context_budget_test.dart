import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/context_budget.dart';

void main() {
  group('token estimation', () {
    test('empty text costs nothing', () {
      expect(ContextBudget.estimateTokens(''), 0);
    });

    test('any non-empty text costs at least one token', () {
      expect(ContextBudget.estimateTokens('a'), greaterThanOrEqualTo(1));
    });

    test('estimates pessimistically rather than optimistically', () {
      // Under-counting is the dangerous direction: it is what lets the window
      // overflow, and overflow does not raise an error — it degrades into
      // unreadable output. The usual 4.0 chars/token would give 25 here.
      final text = 'x' * 100;
      expect(ContextBudget.estimateTokens(text), greaterThan(25));
    });

    test('scales with length', () {
      final short = ContextBudget.estimateTokens('x' * 100);
      final long = ContextBudget.estimateTokens('x' * 1000);
      expect(long, greaterThan(short * 8));
    });
  });

  group('history budget', () {
    test('a small system instruction leaves room for a real conversation', () {
      final budget = ContextBudget.availableForHistory(
        systemInstructionChars: 2000,
        promptChars: 200,
      );
      expect(budget, greaterThan(ContextBudget.minimumHistoryTokens));
      expect(budget, lessThan(ContextBudget.maxTokens));
    });

    test('reserves are actually subtracted', () {
      // A budget that ignored them would leave the reply nowhere to go.
      final budget = ContextBudget.availableForHistory(
        systemInstructionChars: 0,
        promptChars: 0,
      );
      expect(
        budget,
        ContextBudget.maxTokens -
            ContextBudget.reserveForReply -
            ContextBudget.reserveForTemplate,
      );
    });

    test('a longer prompt leaves less room for history', () {
      final small = ContextBudget.availableForHistory(
        systemInstructionChars: 1000,
        promptChars: 100,
      );
      final large = ContextBudget.availableForHistory(
        systemInstructionChars: 1000,
        promptChars: 3000,
      );
      expect(large, lessThan(small));
    });

    test('an enormous system instruction is flagged, not silently accepted', () {
      // Facts, digests, the relationship trend and session summaries each have
      // a cap; their sum does not. This is the tripwire for that.
      expect(ContextBudget.isSystemInstructionOversized(2000), isFalse);
      expect(ContextBudget.isSystemInstructionOversized(12000), isTrue);
    });

    test('the budget can go negative rather than pretending to be zero', () {
      // Callers check the sign; clamping here would hide the real problem.
      final budget = ContextBudget.availableForHistory(
        systemInstructionChars: 20000,
        promptChars: 0,
      );
      expect(budget, lessThan(0));
    });
  });

  group('the whole window is accounted for', () {
    test('a full prompt plus reserves never exceeds the model window', () {
      // The invariant the conversation depends on: whatever is carried, there
      // is always room left to answer in.
      const systemChars = 3000;
      const promptChars = 400;
      final history = ContextBudget.availableForHistory(
        systemInstructionChars: systemChars,
        promptChars: promptChars,
      );

      final total = ContextBudget.estimateTokens(' ' * systemChars) +
          ContextBudget.estimateTokens(' ' * promptChars) +
          history +
          ContextBudget.reserveForReply +
          ContextBudget.reserveForTemplate;

      expect(total, lessThanOrEqualTo(ContextBudget.maxTokens));
    });
  });
}
