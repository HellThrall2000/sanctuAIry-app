import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/model_settings.dart';

/// Sampler tuning panel, debug builds only.
///
/// Voice tuning is an iterative loop and a full rebuild-and-reinstall cycle is
/// ~2 minutes, so being able to move temperature on the device and immediately
/// hear the difference is worth the small amount of UI. [show] is a no-op in
/// release builds.
class DevSettingsSheet extends StatefulWidget {
  final ModelSettings initial;

  const DevSettingsSheet({Key? key, required this.initial}) : super(key: key);

  /// Returns the edited settings, or null if cancelled / not a debug build.
  static Future<ModelSettings?> show(BuildContext context, ModelSettings current) {
    if (!kDebugMode) return Future.value(null);
    return showModalBottomSheet<ModelSettings>(
      context: context,
      backgroundColor: const Color(0xFF0A0A0A),
      isScrollControlled: true,
      builder: (_) => DevSettingsSheet(initial: current),
    );
  }

  @override
  State<DevSettingsSheet> createState() => _DevSettingsSheetState();
}

class _DevSettingsSheetState extends State<DevSettingsSheet> {
  static const _accent = Color(0xFF00E5FF);
  static const _text = Color(0xFFE2E6E9);
  static const _muted = Color(0xFF878F96);

  late ModelSettings _draft = widget.initial.copy();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Sampler",
            style: TextStyle(
                color: _accent, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            "Applying these restarts the conversation — the companion loses the current thread.",
            style: TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 12),
          // Which model is loaded decides the persona and the sampler defaults,
          // so surfacing it here removes the main "why is it behaving like that"
          // question during development.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF1A1A1A)),
              color: const Color(0xFF050505),
            ),
            child: Row(
              children: [
                const Icon(Icons.memory, size: 14, color: _muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _draft.profile.label,
                    style: const TextStyle(color: _text, fontSize: 12),
                  ),
                ),
                Text(
                  "persona: ${_draft.profile.personaMode.name}",
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Switching model requires a restart — it remaps 2.5 GB of weights. "
            "Defaults for ${_draft.profile.label}: "
            "temp ${_draft.profile.temperature}, "
            "topK ${_draft.profile.topK}, "
            "topP ${_draft.profile.topP}.",
            style: const TextStyle(color: _muted, fontSize: 10),
          ),
          const SizedBox(height: 16),
          _slider(
            // Below 1.0 this *sharpens* the distribution — the fine-tune is
            // already far too confident, so anything under 1.0 makes the
            // repetition worse rather than better.
            label: "Temperature",
            hint: "Below 1.0 sharpens; above 1.0 flattens",
            value: _draft.temperature,
            min: 0.1,
            max: ModelSettings.maxTemperature,
            divisions: 38,
            display: _draft.temperature.toStringAsFixed(2),
            onChanged: (v) => setState(() => _draft.temperature = v),
          ),
          _slider(
            label: "Top-K",
            hint: "Candidate pool size",
            value: _draft.topK.toDouble(),
            min: 1,
            max: 128,
            divisions: 127,
            display: '${_draft.topK}',
            onChanged: (v) => setState(() => _draft.topK = v.round()),
          ),
          _slider(
            label: "Top-P",
            hint: "Nucleus cutoff",
            value: _draft.topP,
            min: 0.1,
            max: 1.0,
            divisions: 18,
            display: _draft.topP.toStringAsFixed(2),
            onChanged: (v) => setState(() => _draft.topP = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _draft = ModelSettings()),
                child: const Text("Defaults", style: TextStyle(color: _muted)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel", style: TextStyle(color: _muted)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.pop(context, _draft),
                child: const Text("Apply"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(
                    color: _text, fontSize: 13, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(display, style: const TextStyle(color: _accent, fontSize: 13)),
          ],
        ),
        Text(hint, style: const TextStyle(color: _muted, fontSize: 10)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: _accent,
          inactiveColor: const Color(0xFF1A1A1A),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
