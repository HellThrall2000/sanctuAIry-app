import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../models/wellness.dart';
import '../../models/weekdays.dart';
import '../../services/plan_store.dart';
import '../../services/tracker_feed.dart';
import '../../services/wellness_log.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';

/// The shape of a normal week — which habits run on which day, and what else
/// repeats.
///
/// **Habits come first here.** A habit is not always a daily one: "gym on
/// Tuesdays and Thursdays" is the ordinary case rather than an advanced one,
/// and until a goal could carry weekdays the only way to express it was to
/// accept a broken streak on every day off. This is where that is set, one day
/// at a time, because "what do I do on Wednesdays" is the question people
/// actually open a week view to answer.
///
/// **A routine, not a calendar.** There is no calendar integration and this
/// should not imitate one: what a companion can actually be useful about is the
/// pattern — "you usually run on Wednesdays" — rather than a synced list of
/// appointments it would immediately be wrong about. One-off commitments are
/// picked up from conversation instead, by `EventExtractor`.
class ScheduleView extends StatefulWidget {
  final VoidCallback? onChanged;

  const ScheduleView({super.key, this.onChanged});

  @override
  State<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  final PlanStore _store = PlanStore.instance;
  final WellnessLog _log = WellnessLog.instance;

  List<RoutineBlock> _blocks = const [];
  List<Goal> _goals = const [];
  bool _loading = true;

  /// Which day is being viewed. Defaults to today, because the question people
  /// open this screen with is "what have I got on".
  late int _weekday = DateTime.now().weekday;

  @override
  void initState() {
    super.initState();
    // **The panel is never unmounted.** It is a drawer that slides off-screen,
    // and on a wide screen it sits beside the conversation while a change is
    // being made in it — so it cannot rely on being rebuilt to notice a write.
    // The stores announce their own; this listens.
    WellnessLog.instance.revision.addListener(_onStoreChanged);
    PlanStore.instance.revision.addListener(_onStoreChanged);
    _load();
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
    if (mounted) _load();
  }

  Future<void> _load() async {
    final blocks = await _store.allBlocks();
    final goals = await _log.activeGoals();
    if (!mounted) return;
    setState(() {
      _blocks = blocks;
      _goals = goals;
      _loading = false;
    });
  }

  /// Adds or removes [goal] from the day on screen.
  ///
  /// An every-day goal has no stored weekdays at all, so switching one *off*
  /// has to write the other six explicitly — otherwise "not Wednesday" would
  /// be indistinguishable from "no preference" and the goal would come back
  /// the next time anything touched it.
  Future<void> _toggleOnDay(Goal goal) async {
    final days = goal.isEveryDay
        ? Set<int>.from(Weekdays.all)
        : Set<int>.from(goal.weekdays);

    if (!days.remove(_weekday)) days.add(_weekday);

    // Back to every day: store it as "no preference" rather than all seven, so
    // it reads as unscheduled everywhere else.
    final now = days.length >= 7 ? const <int>{} : days;
    await _log.setGoal(goal.copyWith(weekdays: now));
    TrackerFeed.instance.record(
      '${goal.label} now runs ${Weekdays.label(now).toLowerCase()}',
    );
    await _refresh();
  }

  Future<void> _refresh() async {
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _add() async {
    final draft = await OrganicDialog.show<_BlockDraft>(
      context,
      _BlockDialog(initialWeekday: _weekday),
    );
    if (draft == null) return;
    await _store.addBlock(
      label: draft.label,
      startMinute: draft.startMinute,
      endMinute: draft.endMinute,
      weekdays: draft.weekdays,
    );
    TrackerFeed.instance.record('put ${draft.label} in your week');
    await _refresh();
  }

  Future<void> _remove(RoutineBlock block) async {
    await _store.deleteBlock(block.id);
    TrackerFeed.instance.record('took ${block.label} out of your week');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Organic.space8),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    final forDay = _blocks.where((b) => b.weekdays.contains(_weekday)).toList();
    // A goal with no weekday preference runs every day, so it is on here too.
    final onDay = _goals
        .where((g) => g.isEveryDay || g.weekdays.contains(_weekday))
        .toList();
    final offDay = _goals.where((g) => !onDay.contains(g)).toList();
    final nowMinute = DateTime.now().hour * 60 + DateTime.now().minute;
    final isToday = _weekday == DateTime.now().weekday;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _DayPicker(
          selected: _weekday,
          onSelect: (d) => setState(() => _weekday = d),
        ),
        const SizedBox(height: Organic.space3),
        Text('🔁 HABITS ON THIS DAY', style: OrganicText.h6(t)),
        const SizedBox(height: Organic.space2),
        if (_goals.isEmpty)
          Text(
            'No habits yet. Add one under Habits, or just tell me in the chat.',
            style: OrganicText.cardBody(t),
          )
        else ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final goal in onDay)
                OrganicTag(
                  label: goal.label,
                  variant: OrganicTagVariant.accent,
                  onTap: () => _toggleOnDay(goal),
                ),
            ],
          ),
          if (offDay.isNotEmpty) ...[
            const SizedBox(height: Organic.space2),
            Text('Not on this day — tap to add', style: OrganicText.cardMeta(t)),
            const SizedBox(height: Organic.space1),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final goal in offDay)
                  OrganicTag(
                    label: goal.label,
                    variant: OrganicTagVariant.neutral,
                    onTap: () => _toggleOnDay(goal),
                  ),
              ],
            ),
          ],
        ],
        const SizedBox(height: Organic.space4),
        Text('🕘 REPEATS', style: OrganicText.h6(t)),
        const SizedBox(height: Organic.space2),
        Row(
          children: [
            Expanded(
              child: Text(
                forDay.isEmpty
                    ? 'Nothing scheduled'
                    : '${forDay.length} ${forDay.length == 1 ? 'thing' : 'things'}',
                style: OrganicText.cardMeta(t),
              ),
            ),
            OrganicButton(
              label: 'Add block',
              variant: OrganicButtonVariant.secondary,
              fontSize: 11,
              onPressed: _add,
            ),
          ],
        ),
        const SizedBox(height: Organic.space3),
        if (forDay.isEmpty)
          OrganicCard(
            crossAxisAlignment: CrossAxisAlignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
            children: [
              const Text('🌤️', style: TextStyle(fontSize: 30)),
              const SizedBox(height: Organic.space2),
              const OrganicCardTitle('An open day', size: 15),
              const OrganicCardBody(
                'Add the things that repeat — a class, a walk, when you want '
                'to wind down.',
              ),
            ],
          )
        else
          for (final block in forDay) ...[
            _BlockRow(
              block: block,
              // Only dim the past on the day it is actually the past.
              past: isToday && (block.endMinute ?? block.startMinute) < nowMinute,
              onRemove: () => _remove(block),
            ),
            const SizedBox(height: Organic.space2),
          ],
      ],
    );
  }
}

/// Seven pills, one per weekday.
class _DayPicker extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;

  const _DayPicker({required this.selected, required this.onSelect});

  static const _names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final today = DateTime.now().weekday;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var day = 1; day <= 7; day++)
          GestureDetector(
            onTap: () => onSelect(day),
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: day == selected ? t.accentBg : Colors.transparent,
                    border: day == selected
                        ? null
                        : Border.all(color: t.border, width: 1.4),
                  ),
                  child: Center(
                    child: Text(
                      _names[day - 1],
                      style: OrganicText.navLabel(
                        day == selected ? t.onAccent : t.muted,
                        size: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // A small dot marks today, so the selected day and the actual
                // day are never confused with each other.
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: day == today ? t.accentText : Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BlockRow extends StatelessWidget {
  final RoutineBlock block;
  final bool past;
  final VoidCallback onRemove;

  const _BlockRow({
    required this.block,
    required this.past,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Past blocks fade rather than disappear: the day's shape is still useful
    // information at nine in the evening.
    final fade = past ? 0.45 : 1.0;

    return Opacity(
      opacity: fade,
      child: OrganicCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        children: [
          Row(
            children: [
              SizedBox(
                width: 58,
                child: Text(
                  RoutineBlock.formatMinute(block.startMinute),
                  style: OrganicText.cardTitle(t, size: 14),
                ),
              ),
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(
                  color: t.accentBg,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(block.label, style: OrganicText.body(t).copyWith(fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      block.endMinute == null
                          ? block.repeatLabel
                          : '${block.timeLabel} · ${block.repeatLabel}',
                      style: OrganicText.cardMeta(t),
                    ),
                  ],
                ),
              ),
              OrganicIconButton(
                icon: Icons.close_rounded,
                size: 20,
                color: t.muted,
                tooltip: 'Remove',
                onPressed: onRemove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BlockDraft {
  final String label;
  final int startMinute;
  final int? endMinute;
  final Set<int> weekdays;

  const _BlockDraft(this.label, this.startMinute, this.endMinute, this.weekdays);
}

class _BlockDialog extends StatefulWidget {
  final int initialWeekday;

  const _BlockDialog({required this.initialWeekday});

  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  final TextEditingController _label = TextEditingController();
  late final Set<int> _days = {widget.initialWeekday};
  int _start = 8 * 60;

  static const _names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _start ~/ 60, minute: _start % 60),
    );
    if (picked == null) return;
    setState(() => _start = picked.hour * 60 + picked.minute);
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty || _days.isEmpty) return;
    Navigator.of(context).pop(_BlockDraft(label, _start, null, _days));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return OrganicDialog(
      title: 'Add to your week',
      body: 'Something that repeats, not a one-off.',
      children: [
        OrganicField(
          label: 'What is it?',
          child: OrganicInput(
            controller: _label,
            hint: 'Morning walk',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
        ),
        OrganicField(
          label: 'When',
          child: GestureDetector(
            onTap: _pickTime,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: t.bgSurface,
                borderRadius: BorderRadius.circular(Organic.radiusPill),
                border: Border.all(color: t.border),
              ),
              child: Row(
                children: [
                  Text(
                    RoutineBlock.formatMinute(_start),
                    style: OrganicText.input(t),
                  ),
                  const Spacer(),
                  Icon(Icons.schedule_rounded, size: 18, color: t.muted),
                ],
              ),
            ),
          ),
        ),
        OrganicField(
          label: 'Which days',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var day = 1; day <= 7; day++)
                OrganicTag(
                  label: _names[day - 1],
                  variant: _days.contains(day)
                      ? OrganicTagVariant.accent2
                      : OrganicTagVariant.neutral,
                  onTap: () => setState(() {
                    if (!_days.remove(day)) _days.add(day);
                  }),
                ),
            ],
          ),
        ),
      ],
      actions: [
        OrganicButton(
          label: 'Cancel',
          variant: OrganicButtonVariant.secondary,
          fontSize: 12,
          onPressed: () => Navigator.of(context).pop(),
        ),
        OrganicButton(label: 'Add', fontSize: 12, onPressed: _submit),
      ],
    );
  }
}
