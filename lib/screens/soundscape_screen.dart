import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class SoundscapeWidget extends StatefulWidget {
  const SoundscapeWidget({Key? key}) : super(key: key);

  @override
  State<SoundscapeWidget> createState() => _SoundscapeWidgetState();
}

class _SoundscapeWidgetState extends State<SoundscapeWidget> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  String _activeSound = 'rain'; // 'rain', 'resonance', 'bells'
  double _volume = 0.5;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      // Set looping mode to true for seamless playback
      await _player.setLoopMode(LoopMode.one);
      await _loadSound(_activeSound);
    } catch (e) {
      print("Error initializing audio engine: $e");
    }
  }

  Future<void> _loadSound(String soundType) async {
    try {
      // On mobile devices, we use high-quality, pre-recorded, gapless loop tracks
      // rather than heavy, battery-draining CPU oscillators.
      String assetPath = 'assets/audio/rain.mp3';
      if (soundType == 'resonance') {
        assetPath = 'assets/audio/resonance.mp3';
      } else if (soundType == 'bells') {
        assetPath = 'assets/audio/bells.mp3';
      }

      // If assets are not compiled yet, we fall back to web-hosted ambient loops
      // so the user can hear beautiful soundscapes immediately!
      try {
        await _player.setAsset(assetPath);
      } catch (_) {
        String fallbackUrl = 'https://assets.mixkit.co/active_storage/sfx/2568/2568-84.wav'; // Rain fallback
        if (soundType == 'resonance') {
          fallbackUrl = 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3'; // Drone fallback
        } else if (soundType == 'bells') {
          fallbackUrl = 'https://assets.mixkit.co/active_storage/sfx/1814/1814-84.wav'; // Bell chimes fallback
        }
        await _player.setUrl(fallbackUrl);
      }
      
      await _player.setVolume(_isMuted ? 0.0 : _volume);
    } catch (e) {
      print("Error loading sound source: $e");
    }
  }

  void _togglePlay() async {
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
      setState(() {
        _isPlaying = !_isPlaying;
      });
    } catch (e) {
      print("Playback error: $e");
    }
  }

  void _changeSound(String soundType) async {
    if (soundType == _activeSound) return;
    setState(() {
      _activeSound = soundType;
    });
    
    final wasPlaying = _isPlaying;
    if (wasPlaying) {
      await _player.stop();
    }
    
    await _loadSound(soundType);
    
    if (wasPlaying) {
      await _player.play();
    }
  }

  void _updateVolume(double value) {
    setState(() {
      _volume = value;
      _isMuted = value == 0;
    });
    _player.setVolume(_isMuted ? 0.0 : _volume);
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _player.setVolume(_isMuted ? 0.0 : _volume);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF111315) : Colors.white;
    final accentColor = isDark ? const Color(0xFFA3B1BC) : const Color(0xFF536250);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'AMBIENT RESONANCE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: isDark ? const Color(0xFF878F96) : const Color(0xFF786E63),
                ),
              ),
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  size: 32,
                  color: accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Sound Selector Row
          Row(
            children: [
              _soundTab('Rain', 'rain', Icons.cloud_queue),
              const SizedBox(width: 8),
              _soundTab('Resonance', 'resonance', Icons.waves),
              const SizedBox(width: 8),
              _soundTab('Chimes', 'bells', Icons.notifications_none),
            ],
          ),
          const SizedBox(height: 16),

          // Volume Row
          Row(
            children: [
              IconButton(
                onPressed: _toggleMute,
                icon: Icon(
                  _isMuted || _volume == 0
                      ? Icons.volume_off_outlined
                      : Icons.volume_up_outlined,
                  size: 18,
                  color: isDark ? const Color(0xFF878F96) : const Color(0xFF786E63),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: accentColor,
                    inactiveTrackColor: isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8),
                    thumbColor: accentColor,
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: _volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: _updateVolume,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _soundTab(String name, String type, IconData icon) {
    final isSelected = _activeSound == type;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    Color bg;
    Color border;
    Color text;

    if (isSelected) {
      bg = isDark ? const Color(0xFF24292D) : const Color(0xFF536250);
      border = isDark ? const Color(0xFF24292D) : const Color(0xFF536250);
      text = isDark ? const Color(0xFFE2E6E9) : Colors.white;
    } else {
      bg = isDark ? const Color(0xFF1A1D20) : const Color(0xFFFAF8F5);
      border = isDark ? const Color(0xFF24292D) : const Color(0xFFEAE4D8);
      text = isDark ? const Color(0xFF878F96) : const Color(0xFF786E63);
    }

    return Expanded(
      child: GestureDetector(
        onTap: () => _changeSound(type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 12, color: text),
              const SizedBox(width: 4),
              Text(
                name,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
