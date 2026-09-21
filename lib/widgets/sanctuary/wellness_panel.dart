import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../services/memory_cache.dart';
import '../../services/plan_store.dart';
import '../../services/wellness_log.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';
import 'habits_view.dart';
import 'schedule_view.dart';
import 'tasks_view.dart';

/// The tracker surface: how today is going, then habits, the week, and the list.
///
/// **One surface with three views, not three tabs.** The phone shell's tab bar
/// is a 58px pill holding `Expanded` children; a fourth tab already crowds it at
/// 12px Caprasimo and a sixth would be unreadable. Segmenting inside one
/// destination also matches how the three are actually used — you come here
/// asking "how am I doing", and the answer spans all three.
enum WellnessTab { habits, schedule, tasks }

class WellnessPanel extends StatefulWidget {
  const WellnessPanel({super.key});

  @override
  State<WellnessPanel> createState() => _WellnessPanelState();
}

class _WellnessPanelState extends State<WellnessPanel> {
  WellnessTab _tab = WellnessTab.habits;

  final WellnessLog _log = WellnessLog.instance;
  final PlanStore _plan = PlanStore.instance;

  int _goalsMet = 0;
  int _goalCount = 0;
  int _loggingStreak = 0;
  int _openTodos = 0;
  RoutineBlock? _nextBlock;

  @override
  void initState() {
    super.initState();
    // **The panel is never unmounted.** It is a drawer that slides off-screen,
    // and on a wide screen it sits beside the conversation while a change is
    // being made in it — so it cannot rely on being rebuilt to notice a write.
    // The stores announce their own; this listens.
    WellnessLog.instance.revision.addListener(_onStoreChanged);
    PlanStore.instance.revision.addListener(_onStoreChanged);
    _loadSummary();
  }

  @override
  void dispose() {
    WellnessLog.instance.revision.removeListener(_onStoreChanged);
    PlanStore.instance.revision.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Something wrote to the tracker — from this screen, another tab, or the
  /// conversation. Reloads rather than patching state, because the write could
  /// have come from anywhere and this screen cannot know what changed.
  void _onStoreChanged() {
    if (mounted) _loadSummary();
  }

  /// The hero numbers only. Each view loads its own detail — this stays cheap
  /// because it runs again after every log, tick and edit.
  Future<void> _loadSummary() async {
    final goals = await _log.activeGoals();
    final today = await _log.forDay();
    var met = 0;
    for (final goal in goals) {
      final value = today[goal.metric];
      if (value != null && goal.isMetBy(value)) met++;
    }
    final streak = await _log.loggingStreak();
    final open = await _plan.openCount();
    final next = await _plan.nextBlockToday();

    // The system instruction is already fixed for this conversation, so the
    // refreshed block has to ride the next user turn instead. See
    // MemoryCache.onPlanChanged.
    await MemoryCache.instance.onPlanChanged();

    if (!mounted) return;
    setState(() {
      _goalsMet = met;
      _goalCount = goals.length;
      _loggingStreak = streak;
      _openTodos = open;
      _nextBlock = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Hero(
          met: _goalsMet,
          total: _goalCount,
          streak: _loggingStreak,
          openTodos: _openTodos,
          nextBlock: _nextBlock,
        ),
        const SizedBox(height: Organic.space4),
        OrganicSegmented<WellnessTab>(
          options: const [
            (value: WellnessTab.habits, label: 'Habits'),
            (value: WellnessTab.schedule, label: 'Week'),
            (value: WellnessTab.tasks, label: 'Tasks'),
          ],
          selected: _tab,
          onChanged: (v) => setState(() => _tab = v),
        ),
        const SizedBox(height: Organic.space4),
        // Keyed so switching tabs rebuilds from scratch rather than reusing the
        // previous view's element and its stale loaded state.
        switch (_tab) {
          WellnessTab.habits =>
            HabitsView(key: const ValueKey('habits'), onChanged: _loadSummary),
          WellnessTab.schedule => ScheduleView(
              key: const ValueKey('schedule'), onChanged: _loadSummary),
          WellnessTab.tasks =>
            TasksView(key: const ValueKey('tasks'), onChanged: _loadSummary),
        },
      ],
    );
  }
}

/// Today at a glance.
///
/// A ring rather than a number, because the question is "how much of today is
/// done" and a proportion answers that in one look. Everything beside it is a
/// single line — a hero that needs reading is not a hero.
class _Hero extends StatelessWidget {
  final int met;
  final int total;
  final int streak;
  final int openTodos;
  final RoutineBlock? nextBlock;

  const _Hero({
    required this.met,
    required this.total,
    required this.streak,
    required this.openTodos,
    required this.nextBlock,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ratio = total == 0 ? 0.0 : met / total;

    return OrganicCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      children: [
        Row(
          children: [
            OrganicRing(
              value: ratio,
              size: 96,
              label: total == 0 ? '–' : '$met/$total',
              caption: total == 0 ? 'no goals' : 'today',
            ),
            const SizedBox(width: Organic.space4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_greeting(), style: OrganicText.cardTitle(t, size: 16)),
                  const SizedBox(height: 6),
                  _Line(
                    icon: Icons.local_fire_department_rounded,
                    text: streak >= WellnessLog.minStreakToMention
                        ? '$streak days running'
                        : total == 0
                            ? 'Add a goal to begin'
                            : 'Log something today',
                  ),
                  if (nextBlock != null) ...[
                    const SizedBox(height: 4),
                    _Line(
                      icon: Icons.schedule_rounded,
                      text:
                          '${nextBlock!.label} at ${RoutineBlock.formatMinute(nextBlock!.startMinute)}',
                    ),
                  ],
                  if (openTodos > 0) ...[
                    const SizedBox(height: 4),
                    _Line(
                      icon: Icons.check_circle_outline_rounded,
                      text:
                          '$openTodos ${openTodos == 1 ? 'thing' : 'things'} to do',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Time-of-day rather than a fixed title. Cheap, and it makes the screen feel
  /// like it knows when you opened it.
  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Line({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Icon(icon, size: 14, color: t.accentText),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: OrganicText.cardMeta(t).copyWith(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
