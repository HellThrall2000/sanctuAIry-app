import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../models/upcoming_event.dart';
import '../../services/event_store.dart';
import '../../services/plan_store.dart';
import '../../services/tracker_feed.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';

/// What is coming up, and what still needs doing.
///
/// Two lists that look alike and are not. **Upcoming** comes from
/// `EventExtractor` — things the user mentioned in conversation ("interview on
/// Friday") that were parsed into a dated event. They are read-only here on
/// purpose: they are a record of what was said, and letting the screen edit them
/// would put the transcript and the list out of step.
///
/// **To-dos** are the opposite: typed deliberately, ticked deliberately, with no
/// expiry. Folding the two together would mean either events you have to tick
/// off or to-dos that vanish on their own.
class TasksView extends StatefulWidget {
  final VoidCallback? onChanged;

  const TasksView({super.key, this.onChanged});

  @override
  State<TasksView> createState() => _TasksViewState();
}

class _TasksViewState extends State<TasksView> {
  final PlanStore _plan = PlanStore.instance;
  final EventStore _events = EventStore.instance;

  List<UpcomingEvent> _upcoming = const [];
  List<Todo> _open = const [];
  List<Todo> _done = const [];
  bool _loading = true;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    // **The panel is never unmounted.** It is a drawer that slides off-screen,
    // and on a wide screen it sits beside the conversation while a change is
    // being made in it — so it cannot rely on being rebuilt to notice a write.
    // The stores announce their own; this listens.
    PlanStore.instance.revision.addListener(_onStoreChanged);
    _load();
  }

  @override
  void dispose() {
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
    final now = DateTime.now();
    final all = await _events.all();
    final open = await _plan.openTodos();
    final done = await _plan.completedTodos(limit: 12);
    if (!mounted) return;
    setState(() {
      _upcoming = all
          .where((e) => e.dueAt != null && !e.hasPassed(now))
          .toList()
        ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
      _open = open;
      _done = done;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _addTodo() async {
    final draft = await OrganicDialog.show<_TodoDraft>(
      context,
      const _TodoDialog(),
    );
    if (draft == null) return;
    await _plan.addTodo(draft.text, dueAt: draft.dueAt, priority: draft.priority);
    TrackerFeed.instance.record('added "${draft.text}" to the list');
    await _refresh();
  }

  Future<void> _toggle(Todo todo) async {
    await _plan.updateTodo(todo.toggled());
    // Only on the way to done. Un-ticking is a correction, and announcing a
    // correction draws attention to a slip the user was quietly fixing.
    if (!todo.isDone) {
      TrackerFeed.instance.record('ticked off "${todo.text}"');
    }
    await _refresh();
  }

  Future<void> _delete(Todo todo) async {
    await _plan.deleteTodo(todo.id);
    TrackerFeed.instance.record('dropped "${todo.text}"');
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_upcoming.isNotEmpty) ...[
          const OrganicSectionLabel('Coming up'),
          const SizedBox(height: Organic.space2),
          for (final event in _upcoming.take(4)) ...[
            _EventRow(event: event),
            const SizedBox(height: Organic.space2),
          ],
          const SizedBox(height: Organic.space2),
        ],
        Row(
          children: [
            const Expanded(child: OrganicSectionLabel('To do')),
            OrganicButton(
              label: 'Add',
              variant: OrganicButtonVariant.secondary,
              fontSize: 11,
              onPressed: _addTodo,
            ),
          ],
        ),
        const SizedBox(height: Organic.space2),
        if (_open.isEmpty)
          OrganicCard(
            crossAxisAlignment: CrossAxisAlignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
            children: [
              OrganicCardTitle(
                _done.isEmpty ? '📝 Nothing on the list' : '🎉 All clear',
                size: 15,
              ),
              OrganicCardBody(
                _done.isEmpty
                    ? 'Add the things you keep meaning to get to.'
                    : 'Everything on the list is done.',
              ),
            ],
          )
        else
          for (final todo in _open) ...[
            _TodoRow(
              todo: todo,
              onToggle: () => _toggle(todo),
              onDelete: () => _delete(todo),
            ),
            const SizedBox(height: Organic.space2),
          ],
        if (_done.isNotEmpty) ...[
          const SizedBox(height: Organic.space2),
          GestureDetector(
            onTap: () => setState(() => _showDone = !_showDone),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(
                  '${_done.length} done',
                  style: OrganicText.cardMeta(t),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showDone ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 16,
                  color: t.muted,
                ),
                const Spacer(),
                if (_showDone)
                  OrganicButton(
                    label: 'Clear',
                    variant: OrganicButtonVariant.ghost,
                    fontSize: 11,
                    foreground: t.danger,
                    onPressed: () async {
                      await _plan.clearCompleted();
                      await _refresh();
                    },
                  ),
              ],
            ),
          ),
          if (_showDone) ...[
            const SizedBox(height: Organic.space2),
            for (final todo in _done) ...[
              _TodoRow(
                todo: todo,
                onToggle: () => _toggle(todo),
                onDelete: () => _delete(todo),
              ),
              const SizedBox(height: Organic.space2),
            ],
          ],
        ],
      ],
    );
  }
}

/// A dated thing the user mentioned in conversation. Read-only by design.
class _EventRow extends StatelessWidget {
  final UpcomingEvent event;

  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final due = event.dueAt!;
    final days = DateTime(due.year, due.month, due.day)
        .difference(DateTime.now().copyWith(
          hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0,
        ))
        .inDays;
    final when = switch (days) {
      <= 0 => 'Today',
      1 => 'Tomorrow',
      < 7 => 'In $days days',
      _ => _shortDate(due),
    };

    return OrganicCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      children: [
        Row(
          children: [
            Container(
              width: 3,
              height: 28,
              decoration: BoxDecoration(
                color: days <= 1 ? Organic.accent : t.accentBg,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _capitalise(event.text),
                    style: OrganicText.body(t).copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    event.rawWhen == null ? when : '$when · ${event.rawWhen}',
                    style: OrganicText.cardMeta(t),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _shortDate(DateTime d) => '${_months[d.month - 1]} ${d.day}';

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _TodoRow extends StatelessWidget {
  final Todo todo;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _TodoRow({
    required this.todo,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final overdue = todo.isOverdue();

    return OrganicCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onToggle,
      children: [
        Row(
          children: [
            OrganicCheck(value: todo.isDone, onChanged: (_) => onToggle()),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.text,
                    style: OrganicText.body(t).copyWith(
                      fontSize: 14,
                      // Struck through rather than removed — seeing what you
                      // finished is the only payoff for having done it.
                      decoration:
                          todo.isDone ? TextDecoration.lineThrough : null,
                      color: todo.isDone ? t.muted : t.text,
                    ),
                  ),
                  if (todo.dueAt != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      overdue ? 'Overdue' : 'Due ${_due(todo.dueAt!)}',
                      style: OrganicText.cardMeta(t).copyWith(
                        color: overdue ? t.danger : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (todo.priority == TodoPriority.high && !todo.isDone)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: OrganicTag(
                  label: '!',
                  variant: OrganicTagVariant.accent,
                  fontSize: 10,
                ),
              ),
            OrganicIconButton(
              icon: Icons.close_rounded,
              size: 20,
              color: t.muted,
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
          ],
        ),
      ],
    );
  }

  static String _due(DateTime d) {
    final today = DateTime.now();
    final days = DateTime(d.year, d.month, d.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    return switch (days) {
      0 => 'today',
      1 => 'tomorrow',
      < 7 when days > 0 => 'in $days days',
      _ => '${_EventRow._months[d.month - 1]} ${d.day}',
    };
  }
}

class _TodoDraft {
  final String text;
  final DateTime? dueAt;
  final TodoPriority priority;

  const _TodoDraft(this.text, this.dueAt, this.priority);
}

class _TodoDialog extends StatefulWidget {
  const _TodoDialog();

  @override
  State<_TodoDialog> createState() => _TodoDialogState();
}

class _TodoDialogState extends State<_TodoDialog> {
  final TextEditingController _text = TextEditingController();
  DateTime? _due;
  TodoPriority _priority = TodoPriority.normal;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked == null) return;
    // End of day: a task due "Friday" is not late at 00:01 on Friday.
    setState(() => _due = DateTime(picked.year, picked.month, picked.day, 23, 59));
  }

  void _submit() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(_TodoDraft(text, _due, _priority));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return OrganicDialog(
      title: 'Add to the list',
      children: [
        OrganicField(
          label: 'What needs doing?',
          child: OrganicInput(
            controller: _text,
            hint: 'Book the dentist',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
        ),
        OrganicField(
          label: 'By when (optional)',
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickDate,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      color: t.bgSurface,
                      borderRadius: BorderRadius.circular(Organic.radiusPill),
                      border: Border.all(color: t.border),
                    ),
                    child: Row(
                      children: [
                        Text(
                          _due == null
                              ? 'No date'
                              : '${_EventRow._months[_due!.month - 1]} ${_due!.day}',
                          style: OrganicText.input(
                            t,
                            color: _due == null ? t.muted : null,
                          ),
                        ),
                        const Spacer(),
                        Icon(Icons.event_rounded, size: 18, color: t.muted),
                      ],
                    ),
                  ),
                ),
              ),
              if (_due != null) ...[
                const SizedBox(width: 6),
                OrganicIconButton(
                  icon: Icons.close_rounded,
                  size: 28,
                  color: t.muted,
                  tooltip: 'Clear date',
                  onPressed: () => setState(() => _due = null),
                ),
              ],
            ],
          ),
        ),
        OrganicField(
          label: 'Priority',
          child: OrganicSegmented<TodoPriority>(
            options: const [
              (value: TodoPriority.low, label: 'Low'),
              (value: TodoPriority.normal, label: 'Normal'),
              (value: TodoPriority.high, label: 'High'),
            ],
            selected: _priority,
            onChanged: (p) => setState(() => _priority = p),
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
