import 'package:flutter/material.dart';

import '../../models/weekdays.dart';
import '../../models/wellness.dart';
import '../../services/tracker_feed.dart';
import '../../services/wellness_log.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../organic/organic.dart';

/// Everything the user is trying to do, and how it is going.
///
/// One card per goal: today's value, a meter against the target, the last seven
/// days, and the streak. The card *is* the log button — tapping it opens the
/// entry sheet — because a tracker with a separate "add" flow is a tracker
/// people stop using by Thursday.
class HabitsView extends StatefulWidget {
  /// Called after anything is written, so the surrounding surface can refresh
  /// its summary without this widget knowing what that summary is.
  final VoidCallback? onChanged;

  const HabitsView({super.key, this.onChanged});

  @override
  State<HabitsView> createState() => _HabitsViewState();
}

class _HabitsViewState extends State<HabitsView> {
  final WellnessLog _log = WellnessLog.instance;

  List<Goal> _goals = const [];
  Map<String, double> _today = const {};
  final Map<String, List<double?>> _history = {};
  final Map<String, int> _streaks = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // **The panel is never unmounted.** It is a drawer that slides off-screen,
    // and on a wide screen it sits beside the conversation while a change is
    // being made in it — so it cannot rely on being rebuilt to notice a write.
    // The stores announce their own; this listens.
    WellnessLog.instance.revision.addListener(_onStoreChanged);
    _load();
  }

  @override
  void dispose() {
    WellnessLog.instance.revision.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Something wrote to the tracker — from this screen, another tab, or the
  /// conversation. Reloads rather than patching state, because the write could
  /// have come from anywhere and this screen cannot know what changed.
  void _onStoreChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final goals = await _log.activeGoals();
    final today = await _log.forDay();
    final history = <String, List<double?>>{};
    final streaks = <String, int>{};
    for (final goal in goals) {
      history[goal.metric] = await _log.history(goal.metric);
      streaks[goal.metric] = await _log.streak(goal);
    }
    if (!mounted) return;
    setState(() {
      _goals = goals;
      _today = today;
      _history
        ..clear()
        ..addAll(history);
      _streaks
        ..clear()
        ..addAll(streaks);
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _logGoal(Goal goal) async {
    final before = _today[goal.metric] ?? 0;

    if (goal.isBinary) {
      // A habit has one bit of information in it. Asking for a number would be
      // three taps to say "yes".
      final now = before > 0 ? 0.0 : 1.0;
      await _log.log(goal.metric, now);
      _announceIfMet(goal, before: before, after: now);
      await _refresh();
      return;
    }

    final entered = await OrganicDialog.show<double>(
      context,
      _LogValueDialog(goal: goal, current: _today[goal.metric]),
    );
    if (entered == null) return;
    await _log.log(goal.metric, entered);
    _announceIfMet(goal, before: before, after: entered);
    await _refresh();
  }

  /// Says something only when a log *crosses* the target.
  ///
  /// **Not on every log.** Someone drinking water taps this five times a day,
  /// and five "noted" lines in the conversation is the retention-notification
  /// failure `NudgeService` exists to avoid. Crossing the target happens at
  /// most once per goal per day and is the only moment in logging that is
  /// actually worth a word — the rest the companion reads silently from the
  /// wellness block, and the evening review covers the reflection.
  void _announceIfMet(Goal goal, {required double before, required double after}) {
    if (goal.isMetBy(before) || !goal.isMetBy(after)) return;
    TrackerFeed.instance.record(
      goal.isBinary ? 'ticked off ${goal.label}' : 'hit ${goal.label}',
    );
  }

  Future<void> _addGoal() async {
    final draft = await OrganicDialog.show<_GoalDraft>(
      context,
      _GoalDialog(existing: _goals.map((g) => g.metric).toSet()),
    );
    if (draft == null) return;
    await _log.setGoal(Goal.forMetric(
      metric: draft.metric,
      target: draft.target,
      label: draft.label,
      cadence: draft.cadence,
      unit: draft.unit,
      weekdays: draft.weekdays,
      emoji: draft.emoji,
    ));
    TrackerFeed.instance.record('added ${draft.label}');
    await _refresh();
  }

  Future<void> _removeGoal(Goal goal) async {
    final ok = await OrganicDialog.show<bool>(
      context,
      OrganicDialog(
        title: 'Stop tracking this?',
        body: 'The days you have already logged are kept — only the goal goes.',
        actions: [
          OrganicButton(
            label: 'Cancel',
            variant: OrganicButtonVariant.secondary,
            fontSize: 12,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          OrganicButton(
            label: 'Stop tracking',
            variant: OrganicButtonVariant.secondary,
            fontSize: 12,
            foreground: context.tokens.danger,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _log.archiveGoal(goal.id);
    TrackerFeed.instance.record('stopped tracking ${goal.label}');
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
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _goals.isEmpty
                    ? 'Nothing tracked yet'
                    : '${_goals.length} being tracked',
                style: OrganicText.cardMeta(t),
              ),
            ),
            OrganicButton(
              label: 'Add goal',
              variant: OrganicButtonVariant.secondary,
              fontSize: 11,
              onPressed: _addGoal,
            ),
          ],
        ),
        const SizedBox(height: Organic.space3),
        if (_goals.isEmpty)
          _EmptyState(onAdd: _addGoal)
        else
          for (final goal in _goals) ...[
            _GoalCard(
              goal: goal,
              today: _today[goal.metric],
              history: _history[goal.metric] ?? const [],
              streak: _streaks[goal.metric] ?? 0,
              onLog: () => _logGoal(goal),
              onRemove: () => _removeGoal(goal),
            ),
            const SizedBox(height: Organic.space3),
          ],
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return OrganicCard(
      crossAxisAlignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
      children: [
        const Text('🌱', style: TextStyle(fontSize: 34)),
        const SizedBox(height: Organic.space2),
        const OrganicCardTitle('Pick one thing', size: 15),
        const OrganicCardBody(
          'Start with a single goal you could keep this week. You can always '
          'add more once it sticks.',
        ),
        const SizedBox(height: Organic.space1),
        OrganicButton(label: 'Add your first goal', block: true, onPressed: onAdd),
      ],
    );
  }
}

/// One goal, with its week.
class _GoalCard extends StatelessWidget {
  final Goal goal;
  final double? today;
  final List<double?> history;
  final int streak;
  final VoidCallback onLog;
  final VoidCallback onRemove;

  const _GoalCard({
    required this.goal,
    required this.today,
    required this.history,
    required this.streak,
    required this.onLog,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isBool = goal.isBinary;
    final value = today ?? 0;
    final done = goal.isMetBy(value);
    final progress = goal.target <= 0 ? 0.0 : value / goal.target;

    return OrganicCard(
      onTap: onLog,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Only when the user gave it one. A placeholder in every empty
            // slot would be a column of grey boxes, which is worse than the
            // plain list this started as.
            if (goal.emoji != null) ...[
              Text(goal.emoji!, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: Organic.space2),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    goal.label,
                    style: OrganicText.cardTitle(t, size: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    today == null
                        ? 'Not logged today'
                        : 'Today: ${goal.renderValue(value)}',
                    style: OrganicText.cardMeta(t),
                  ),
                ],
              ),
            ),
            if (isBool)
              OrganicCheck(value: done, onChanged: (_) => onLog())
            else
              OrganicIconButton(
                icon: Icons.add_rounded,
                size: 30,
                bordered: true,
                tooltip: 'Log ${Metric.label(goal.metric)}',
                onPressed: onLog,
              ),
          ],
        ),
        if (!isBool) ...[
          const SizedBox(height: 2),
          OrganicMeter(value: progress),
        ],
        const SizedBox(height: Organic.space1),
        OrganicWeekStrip(
          days: [
            for (final v in history) v == null ? null : goal.isMetBy(v),
          ],
          dotSize: 22,
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                streak >= WellnessLog.minStreakToMention
                    ? '$streak days running'
                    : goal.cadence == GoalCadence.weekly
                        ? goal.label
                        : 'Target ${goal.targetLabel}',
                style: OrganicText.cardMeta(t),
              ),
            ),
            OrganicIconButton(
              icon: Icons.close_rounded,
              size: 20,
              color: t.muted,
              tooltip: 'Stop tracking',
              onPressed: onRemove,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Dialogs ────────────────────────────────────────────────────────────────
//
// Both own their controllers. The diary's compose dialog documents why: a
// controller owned by the caller and disposed when the dialog future completes
// is still bound to a mounted TextField during the 200ms exit fade, which threw
// `'_dependents.isEmpty': is not true` and put a red screen over the app.

class _LogValueDialog extends StatefulWidget {
  final Goal goal;
  final double? current;

  const _LogValueDialog({required this.goal, this.current});

  @override
  State<_LogValueDialog> createState() => _LogValueDialogState();
}

class _LogValueDialogState extends State<_LogValueDialog> {
  late final TextEditingController _value = TextEditingController(
    text: widget.current == null ? '' : _trim(widget.current!),
  );
  final TextEditingController _hours = TextEditingController();
  final TextEditingController _minutes = TextEditingController();

  /// Durations get the clock; everything else gets one box.
  bool get _isDuration =>
      widget.goal.unit == Unit.minutes || widget.goal.unit == Unit.hours;

  @override
  void initState() {
    super.initState();
    if (_isDuration && widget.current != null) {
      _ClockField.write(_hours, _minutes,
          value: widget.current!, unit: widget.goal.unit);
    }
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  @override
  void dispose() {
    _value.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _submit() {
    if (_isDuration) {
      final read = _ClockField.read(_hours, _minutes);
      // Zero is a real answer here — it is how a miss is recorded — so an empty
      // clock logs nothing rather than refusing, and 0 is returned explicitly.
      Navigator.of(context).pop(read == null
          ? 0.0
          : (read.$2 == Unit.hours ? read.$1 * 60 : read.$1) /
              (widget.goal.unit == Unit.hours ? 60 : 1));
      return;
    }
    final parsed = double.tryParse(_value.text.trim().replaceAll(',', '.'));
    if (parsed == null || parsed < 0) return;
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return OrganicDialog(
      title: 'Log ${Metric.label(widget.goal.metric)}',
      body: widget.goal.label,
      children: [
        OrganicField(
          // Derived from the goal's own unit rather than a switch over known
          // metrics — a habit counted in pages says "Pages" without anything
          // here having heard of pages.
          label: _isDuration
              ? 'How long?'
              : widget.goal.unit == Unit.rating
                  ? 'How was today, 1 to 5'
                  : _capitalise(widget.goal.unit),
          child: _isDuration
              ? _ClockField(
                  hours: _hours, minutes: _minutes, onSubmit: _submit)
              : OrganicInput(
                  controller: _value,
                  hint: '0',
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
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
        OrganicButton(label: 'Save', fontSize: 12, onPressed: _submit),
      ],
    );
  }
}

class _GoalDraft {
  final String metric;
  final double target;
  final String label;
  final GoalCadence cadence;

  /// What [target] counts — see [Unit]. A habit is no longer a bare tick.
  final String unit;

  /// Empty means every day.
  final Set<int> weekdays;

  /// Whatever face the user picked, or null.
  final String? emoji;

  const _GoalDraft(
    this.metric,
    this.target,
    this.label,
    this.cadence, {
    required this.unit,
    this.weekdays = const {},
    this.emoji,
  });
}

class _GoalDialog extends StatefulWidget {
  /// Metrics already tracked, so the picker does not offer a duplicate. A
  /// second goal for the same metric would silently overwrite the first —
  /// correct behaviour, confusing UI.
  final Set<String> existing;

  const _GoalDialog({required this.existing});

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  final TextEditingController _target = TextEditingController();
  final TextEditingController _habit = TextEditingController();

  String? _metric;

  /// **A habit, unless they say otherwise.** The three built-ins are a
  /// convenience for the things most people track; everything else anybody
  /// wants is a habit, so that is where the dialog opens rather than making
  /// the common case a second tap.
  bool _custom = true;

  /// What a typed amount is counted in. Minutes because that is what most
  /// habits people name are measured in.
  String _unit = Unit.minutes;

  final TextEditingController _hours = TextEditingController();
  final TextEditingController _minutes = TextEditingController();

  /// The clock is only right for a duration, and a unit the user typed is
  /// never one — asking for "0 : 00 reps" is nonsense. Reads the *chosen*
  /// unit rather than the last chip that happened to be selected.
  bool get _isDuration =>
      !_ownUnit && (_unit == Unit.minutes || _unit == Unit.hours);

  /// True while the unit is being typed rather than picked.
  bool _ownUnit = false;
  final TextEditingController _unitText = TextEditingController();

  /// The face for this goal. Empty is allowed and means none.
  final TextEditingController _emoji = TextEditingController();

  /// A handful to tap, and the field beside them takes anything at all — the
  /// point is that nobody is limited to a list somebody else wrote.
  static const _emojiChoices = [
    '🏃', '🧘', '📖', '💧', '😴', '🎸', '💪', '🧹', '✍️', '🌱', '☀️', '🎯',
  ];

  /// What the goal will be counted in, typed or picked.
  String get _chosenUnit {
    if (!_ownUnit) return _unit;
    final typed = _unitText.text.trim().toLowerCase();
    return typed.isEmpty ? Unit.times : typed;
  }

  /// Empty means every day, which is what most habits are.
  final Set<int> _days = <int>{};

  static const _defaults = {
    Metric.sleep: ('7', 'sleep 7 hours'),
    Metric.movement: ('30', 'move 30 minutes'),
    Metric.water: ('2', 'drink 2 litres'),
    Metric.mood: ('3', 'feel okay or better'),
  };

  @override
  void dispose() {
    _target.dispose();
    _habit.dispose();
    _hours.dispose();
    _minutes.dispose();
    _unitText.dispose();
    _emoji.dispose();
    super.dispose();
  }

  /// The first character of whatever is in the emoji box, or null.
  ///
  /// Trimmed to one glyph so a slip of the keyboard cannot put a sentence
  /// where a picture goes. `characters` rather than `substring`, because an
  /// emoji is routinely several code units and cutting one in half renders as
  /// a replacement box.
  String? get _pickedEmoji {
    final text = _emoji.text.trim();
    if (text.isEmpty) return null;
    return text.characters.first;
  }

  /// The amount the user entered, from whichever input was on screen.
  (double, String)? _amount() {
    if (_isDuration) return _ClockField.read(_hours, _minutes);
    final typed = _target.text.trim().replaceAll(',', '.');
    final value = typed.isEmpty ? null : double.tryParse(typed);
    if (value == null || value <= 0) return null;
    return (value, _chosenUnit);
  }

  void _pick(String metric) {
    setState(() {
      _metric = metric;
      _custom = false;
      final preset = _defaults[metric]?.$1 ?? '1';
      _target.text = preset;
      final unit = Unit.defaultFor(metric);
      if (unit == Unit.minutes || unit == Unit.hours) {
        _ClockField.write(_hours, _minutes,
            value: double.tryParse(preset) ?? 0, unit: unit);
      }
    });
  }

  void _submit() {
    if (_custom) {
      final name = _habit.text.trim();
      if (name.isEmpty) return;
      // Blank is allowed and means "just tell me you did it" — the old tick.
      // Only a *typed* amount turns it into a measured habit, so nobody is
      // forced to invent a number for something that does not have one.
      final amount = _amount();
      Navigator.of(context).pop(
        _GoalDraft(
          Metric.habit(name),
          amount?.$1 ?? 1,
          amount == null
              ? name
              : '$name ${Unit.render(amount.$1, amount.$2)}',
          GoalCadence.daily,
          unit: amount?.$2 ?? Unit.times,
          weekdays: _days,
          emoji: _pickedEmoji,
        ),
      );
      return;
    }
    final metric = _metric;
    if (metric == null) return;

    final metricUnit = Unit.defaultFor(metric);
    final isDuration = metricUnit == Unit.minutes || metricUnit == Unit.hours;
    final entered = isDuration
        ? _ClockField.read(_hours, _minutes)
        : (double.tryParse(_target.text.trim().replaceAll(',', '.')), metricUnit)
            .let((v) => v.$1 == null ? null : (v.$1!, v.$2));
    if (entered == null || entered.$1 <= 0) return;

    final target = entered.$1;
    final amount = Unit.render(target, entered.$2);
    final label = switch (metric) {
      Metric.sleep => 'sleep $amount',
      Metric.movement => 'move $amount',
      Metric.water => 'drink $amount',
      Metric.mood => 'feel okay or better',
      _ => amount,
    };
    Navigator.of(context).pop(
      _GoalDraft(
        metric,
        target,
        label,
        GoalCadence.daily,
        unit: entered.$2,
        weekdays: _days,
        emoji: _pickedEmoji,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Mood is not offered: it is read from how someone writes, not aimed at.
    // See Metric.trackable.
    final available =
        Metric.trackable.where((m) => !widget.existing.contains(m)).toList();

    return OrganicDialog(
      title: 'What are you working on?',
      body: 'One thing at a time works better than five.',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in available)
              OrganicTag(
                label: Metric.label(m),
                variant: (!_custom && _metric == m)
                    ? OrganicTagVariant.accent2
                    : OrganicTagVariant.neutral,
                onTap: () => _pick(m),
              ),
            OrganicTag(
              label: '✨ anything else',
              variant: _custom
                  ? OrganicTagVariant.accent2
                  : OrganicTagVariant.neutral,
              onTap: () => setState(() {
                _custom = true;
                _metric = null;
              }),
            ),
          ],
        ),
        if (_custom) ...[
          OrganicField(
            label: 'What is the habit?',
            child: OrganicInput(
              controller: _habit,
              hint: 'meditate',
              textInputAction: TextInputAction.next,
            ),
          ),
          OrganicField(
            // Optional on purpose: "how much" is the question the old boolean
            // habit could not answer, but plenty of habits genuinely have no
            // number and forcing one would make them all feel like homework.
            label: 'How much? (optional)',
            child: _isDuration
                ? _ClockField(
                    hours: _hours, minutes: _minutes, onSubmit: _submit)
                : OrganicInput(
                    controller: _target,
                    hint: '30',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final u in Unit.choices)
                OrganicTag(
                  label: u,
                  variant: (!_ownUnit && _unit == u)
                      ? OrganicTagVariant.accent
                      : OrganicTagVariant.neutral,
                  onTap: () => setState(() {
                    _unit = u;
                    _ownUnit = false;
                  }),
                ),
              // The list stops being a limit here. Reps, chapters, cigarettes
              // not smoked — the app has no business knowing in advance what
              // somebody counts, and Unit.render pluralises whatever it gets.
              OrganicTag(
                label: '✏️ my own',
                variant: _ownUnit
                    ? OrganicTagVariant.accent
                    : OrganicTagVariant.neutral,
                onTap: () => setState(() => _ownUnit = true),
              ),
            ],
          ),
          if (_ownUnit)
            OrganicField(
              label: 'Counted in',
              child: OrganicInput(
                controller: _unitText,
                hint: 'reps',
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
            ),
        ]
        else if (_metric != null)
          OrganicField(
            // From the metric's unit, not a switch over the metrics we happen
            // to ship. A new built-in needs no line here.
            label: switch (Unit.defaultFor(_metric!)) {
              Unit.minutes || Unit.hours => 'How long, a day?',
              Unit.rating => 'At least (1 to 5)',
              final u => '${_capitalise(u)} a day',
            },
            child: (Unit.defaultFor(_metric!) == Unit.minutes ||
                    Unit.defaultFor(_metric!) == Unit.hours)
                ? _ClockField(
                    hours: _hours, minutes: _minutes, onSubmit: _submit)
                : OrganicInput(
                    controller: _target,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
          ),
        if (_custom || _metric != null)
          OrganicField(
            label: 'Give it a face (optional)',
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: OrganicInput(
                    controller: _emoji,
                    hint: '🎯',
                    textAlign: TextAlign.center,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: Organic.space2),
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final e in _emojiChoices)
                        GestureDetector(
                          onTap: () => setState(() => _emoji.text = e),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Text(e, style: const TextStyle(fontSize: 19)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_custom || _metric != null)
          OrganicField(
            label: 'Which days? (all of them, unless you pick)',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var d = 1; d <= 7; d++)
                  OrganicTag(
                    label: Weekdays.shortNames[d - 1],
                    variant: _days.contains(d)
                        ? OrganicTagVariant.accent
                        : OrganicTagVariant.neutral,
                    onTap: () => setState(() {
                      if (!_days.remove(d)) _days.add(d);
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
        OrganicButton(label: 'Track it', fontSize: 12, onPressed: _submit),
      ],
    );
  }
}

/// Hours and minutes, as two fields with a colon between them.
///
/// **Because a duration is two numbers.** A single "minutes" box makes someone
/// asked for an hour and a half type 90, and a single "hours" box makes them
/// type 1.5 — both are arithmetic the user should not be doing, and 1.5 is not
/// a thing anybody says out loud. Splitting it is also what lets the tracker be
/// precise to the minute without ever showing a decimal.
///
/// Only shown for duration units. Litres and pages are one number and a second
/// box for them would be noise.
class _ClockField extends StatelessWidget {
  final TextEditingController hours;
  final TextEditingController minutes;
  final VoidCallback onSubmit;

  const _ClockField({
    required this.hours,
    required this.minutes,
    required this.onSubmit,
  });

  /// The duration these two fields describe, as a value and a unit.
  ///
  /// A whole number of hours stays in hours so "7 hours" is stored the way it
  /// is said; anything with minutes in it becomes minutes, which is the one
  /// canonical form the rest of the app compares and adds up.
  static (double, String)? read(
      TextEditingController hours, TextEditingController minutes) {
    final h = int.tryParse(hours.text.trim()) ?? 0;
    final m = int.tryParse(minutes.text.trim()) ?? 0;
    if (h <= 0 && m <= 0) return null;
    if (m == 0) return (h.toDouble(), Unit.hours);
    return ((h * 60 + m).toDouble(), Unit.minutes);
  }

  /// Fills the two fields from a stored amount.
  static void write(
    TextEditingController hours,
    TextEditingController minutes, {
    required double value,
    required String unit,
  }) {
    final total = unit == Unit.hours ? (value * 60).round() : value.round();
    final h = total ~/ 60;
    final m = total % 60;
    hours.text = h == 0 ? '' : '$h';
    minutes.text = m == 0 ? '' : '$m';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    Widget box(TextEditingController controller, String hint, String caption) =>
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              OrganicInput(
                controller: controller,
                hint: hint,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => onSubmit(),
              ),
              const SizedBox(height: 4),
              Text(caption, style: OrganicText.cardMeta(t)),
            ],
          ),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        box(hours, '0', 'hours'),
        Padding(
          // Sits on the inputs rather than the captions below them.
          padding: const EdgeInsets.only(top: 12, left: 8, right: 8),
          child: Text(':',
              style: OrganicText.h4(t).copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ),
        box(minutes, '00', 'minutes'),
      ],
    );
  }
}

/// "minutes" -> "Minutes". Used for field labels built from a unit name.
String _capitalise(String raw) =>
    raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);

extension<T> on T {
  /// Lets a value be reshaped in an expression instead of a temporary.
  R let<R>(R Function(T) transform) => transform(this);
}
