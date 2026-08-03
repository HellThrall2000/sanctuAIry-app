import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// One of the ambient loops offered in "Environment Resonance".
enum Soundscape {
  rain(
    'Rain',
    'assets/audio/Glass_and_Petrichor.mp3',
    bundled: true,
  ),

  // Not shipped yet. Kept as declarations rather than deleted so that adding a
  // file and flipping `bundled` is the whole change — [SoundscapeController]
  // and the settings UI already handle any number of loops.
  resonance('Resonance', 'assets/audio/resonance.ogg'),
  bells('Temple Bells', 'assets/audio/bells.ogg');

  final String label;
  final String asset;

  /// Whether the audio file is actually in the bundle.
  ///
  /// Filtering the UI on this rather than listing every enum value is the
  /// difference between a control that does nothing and a control that is not
  /// there — an ambient tag that silently fails is worse than one absent.
  final bool bundled;

  const Soundscape(this.label, this.asset, {this.bundled = false});

  /// The loops this build can actually play. What the settings panel renders.
  static List<Soundscape> get available =>
      values.where((s) => s.bundled).toList(growable: false);
}

/// Owns the ambient audio player.
///
/// Extracted from the old `SoundscapeWidget` so the design's resonance tags can
/// drive playback from wherever they are rendered — the settings drawer in 1a,
/// the settings sheet in 1c — without each copy owning its own [AudioPlayer]
/// and fighting the others for the output.
///
/// **Local assets only.** The previous implementation fell back to streaming
/// from `soundhelix.com` whenever `setAsset` failed, which it always did
/// because the audio files are commented out of `pubspec.yaml`. An app whose
/// premise is that nothing leaves the device must not quietly open a socket to
/// a third party for background music, so a missing asset now surfaces as
/// [unavailable] instead.
class SoundscapeController extends ChangeNotifier {
  static final SoundscapeController instance = SoundscapeController._();

  SoundscapeController._();

  final AudioPlayer _player = AudioPlayer();

  Soundscape? _active;
  bool _playing = false;
  bool _unavailable = false;
  double _volume = 0.5;

  /// The selected loop, or null when none is chosen.
  Soundscape? get active => _active;

  bool get playing => _playing;

  /// True once a loop has been asked for and its asset was not in the bundle.
  bool get unavailable => _unavailable;

  double get volume => _volume;

  /// Selects [scape], or stops if it is already the active one.
  ///
  /// Tapping the active tag again is the only way to stop from the tag row,
  /// which is what the design's single-control-per-loop layout implies.
  Future<void> toggle(Soundscape scape) async {
    if (_active == scape && _playing) {
      await stop();
      return;
    }

    _active = scape;
    _unavailable = false;
    notifyListeners();

    try {
      await _player.setLoopMode(LoopMode.one);
      await _player.setAsset(scape.asset);
      await _player.setVolume(_volume);
      await _player.play();
      _playing = true;
    } catch (e) {
      // Missing bundle entry, unsupported codec, or no audio focus. All of
      // them mean "no sound", and none of them justify a network call.
      debugPrint('Soundscape ${scape.name} unavailable: $e');
      _unavailable = true;
      _playing = false;
      _active = null;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // Already stopped or never started; nothing to recover from.
    }
    _playing = false;
    _active = null;
    notifyListeners();
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    try {
      await _player.setVolume(_volume);
    } catch (_) {
      // Volume before a source is set is a no-op, not a failure.
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
