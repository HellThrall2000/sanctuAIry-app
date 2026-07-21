import React, { useState, useEffect, useRef } from 'react';
import { motion } from 'motion/react';
import { 
  Play, Square, Volume2, VolumeX, CloudRain, Bell, Sparkles
} from 'lucide-react';

interface SoundscapeProps {
  theme?: 'light' | 'dark';
}

export default function Soundscape({ theme = 'light' }: SoundscapeProps) {
  const [isPlaying, setIsPlaying] = useState(false);
  const [activeSound, setActiveSound] = useState<'rain' | 'resonance' | 'bells'>('rain');
  const [volume, setVolume] = useState(0.5);
  const [isMuted, setIsMuted] = useState(false);

  // Web Audio Context reference
  const audioCtxRef = useRef<AudioContext | null>(null);
  
  // Node references for rain
  const noiseNodeRef = useRef<AudioWorkletNode | ScriptProcessorNode | null>(null);
  const rainFilterRef = useRef<BiquadFilterNode | null>(null);
  const rainGainRef = useRef<GainNode | null>(null);

  // Node references for resonance (drone)
  const oscillatorsRef = useRef<OscillatorNode[]>([]);
  const resonanceGainRef = useRef<GainNode | null>(null);

  // Interval reference for bells
  const bellTimerRef = useRef<NodeJS.Timeout | null>(null);
  const bellGainRef = useRef<GainNode | null>(null);

  // Master Gain reference
  const masterGainRef = useRef<GainNode | null>(null);

  // Clean up on unmount
  useEffect(() => {
    return () => {
      stopAllSoundscapes();
    };
  }, []);

  // Update master volume when state changes
  useEffect(() => {
    if (masterGainRef.current && audioCtxRef.current) {
      const targetVolume = isMuted ? 0 : volume;
      masterGainRef.current.gain.setValueAtTime(targetVolume, audioCtxRef.current.currentTime);
    }
  }, [volume, isMuted]);

  // Handle play/stop on active sound swap
  useEffect(() => {
    if (isPlaying) {
      stopActiveSoundNode();
      startActiveSoundNode();
    }
  }, [activeSound]);

  const initAudioContext = () => {
    if (!audioCtxRef.current) {
      // Create new AudioContext
      const AudioCtxClass = window.AudioContext || (window as any).webkitAudioContext;
      const ctx = new AudioCtxClass();
      audioCtxRef.current = ctx;

      // Master Gain setup
      const master = ctx.createGain();
      master.gain.setValueAtTime(isMuted ? 0 : volume, ctx.currentTime);
      master.connect(ctx.destination);
      masterGainRef.current = master;
    }
    
    // Unlock suspended context
    if (audioCtxRef.current.state === 'suspended') {
      audioCtxRef.current.resume();
    }
  };

  const handleTogglePlay = () => {
    try {
      initAudioContext();
      if (isPlaying) {
        stopAllSoundscapes();
        setIsPlaying(false);
      } else {
        startActiveSoundNode();
        setIsPlaying(true);
      }
    } catch (e) {
      console.error("Failed to boot interactive audio driver:", e);
    }
  };

  const startActiveSoundNode = () => {
    const ctx = audioCtxRef.current;
    const master = masterGainRef.current;
    if (!ctx || !master) return;

    if (activeSound === 'rain') {
      startRainSound(ctx, master);
    } else if (activeSound === 'resonance') {
      startResonanceSound(ctx, master);
    } else if (activeSound === 'bells') {
      startBellsSound(ctx, master);
    }
  };

  const stopActiveSoundNode = () => {
    // 1. Stop rain
    if (noiseNodeRef.current) {
      try {
        noiseNodeRef.current.disconnect();
      } catch (e) {}
      noiseNodeRef.current = null;
    }

    // 2. Stop resonance oscillators
    oscillatorsRef.current.forEach(osc => {
      try {
        osc.stop();
        osc.disconnect();
      } catch (e) {}
    });
    oscillatorsRef.current = [];

    // 3. Stop bells
    if (bellTimerRef.current) {
      clearInterval(bellTimerRef.current);
      bellTimerRef.current = null;
    }
  };

  const stopAllSoundscapes = () => {
    stopActiveSoundNode();
    if (audioCtxRef.current) {
      try {
        // We suspend context to conserve CPU
        audioCtxRef.current.suspend();
      } catch (e) {}
    }
  };

  // 1. RAIN SYNTHESIZER
  const startRainSound = (ctx: AudioContext, destination: AudioNode) => {
    // Generate pinkish noise using buffer
    const bufferSize = 2 * ctx.sampleRate;
    const noiseBuffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
    const output = noiseBuffer.getChannelData(0);
    
    // Simple filter coefficients for pink-brown noise simulation
    let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
    for (let i = 0; i < bufferSize; i++) {
      const white = Math.random() * 2 - 1;
      b0 = 0.99886 * b0 + white * 0.0555179;
      b1 = 0.99332 * b1 + white * 0.0750759;
      b2 = 0.96900 * b2 + white * 0.1538520;
      b3 = 0.86650 * b3 + white * 0.3104856;
      b4 = 0.55000 * b4 + white * 0.5329522;
      b5 = -0.7616 * b5 - white * 0.0168980;
      output[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362;
      output[i] *= 0.11; // rescale
      b6 = white * 0.115926;
    }

    const noiseSource = ctx.createBufferSource();
    noiseSource.buffer = noiseBuffer;
    noiseSource.loop = true;

    // Filter rain frequencies
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.setValueAtTime(1000, ctx.currentTime);

    const gain = ctx.createGain();
    gain.gain.setValueAtTime(0.4, ctx.currentTime);

    // Connect nodes
    noiseSource.connect(filter);
    filter.connect(gain);
    gain.connect(destination);
    
    noiseSource.start();

    // Store references
    noiseNodeRef.current = noiseSource as any; 
    rainFilterRef.current = filter;
    rainGainRef.current = gain;
  };

  // 2. COSMIC RESONANCE SYNTHESIZER
  const startResonanceSound = (ctx: AudioContext, destination: AudioNode) => {
    const frequencies = [110, 165, 220, 330]; // Rich major chord drones (A2, E3, A3, E4)
    const oscillators: OscillatorNode[] = [];

    const gainNode = ctx.createGain();
    gainNode.gain.setValueAtTime(0.12, ctx.currentTime);
    gainNode.connect(destination);
    resonanceGainRef.current = gainNode;

    frequencies.forEach((freq, idx) => {
      const osc = ctx.createOscillator();
      const lfo = ctx.createOscillator();
      const lfoGain = ctx.createGain();

      osc.type = 'sine';
      osc.frequency.setValueAtTime(freq, ctx.currentTime);

      // Low frequency modulator for gentle swell/waves
      lfo.frequency.setValueAtTime(0.08 + idx * 0.02, ctx.currentTime);
      lfoGain.gain.setValueAtTime(0.04, ctx.currentTime);

      // Connect LFO to modulate oscillator frequency slightly
      lfo.connect(lfoGain);
      lfoGain.connect(osc.frequency);

      osc.connect(gainNode);
      
      osc.start();
      lfo.start();

      oscillators.push(osc);
      oscillators.push(lfo); // store to stop both later
    });

    oscillatorsRef.current = oscillators;
  };

  // 3. RESONANT BELL SYNTHESIZER (PROCEDURAL SPORADIC BELLS)
  const triggerSingleBell = (ctx: AudioContext, destination: AudioNode, freq: number) => {
    const now = ctx.currentTime;
    
    // Resonant FM Bell Synthesis
    const carrier = ctx.createOscillator();
    const modulator = ctx.createOscillator();
    const modGain = ctx.createGain();
    const ampGain = ctx.createGain();

    carrier.type = 'sine';
    carrier.frequency.setValueAtTime(freq, now);

    modulator.type = 'sine';
    modulator.frequency.setValueAtTime(freq * 1.5, now); // Harmonic ratio
    modGain.gain.setValueAtTime(300, now); // Modulation index

    ampGain.gain.setValueAtTime(0, now);
    // Smooth bell strike attack and long, beautiful decay
    ampGain.gain.linearRampToValueAtTime(0.18, now + 0.05);
    ampGain.gain.exponentialRampToValueAtTime(0.0001, now + 4.5);

    // Connect FM chain
    modulator.connect(modGain);
    modGain.connect(carrier.frequency);
    carrier.connect(ampGain);
    ampGain.connect(destination);

    modulator.start(now);
    carrier.start(now);

    // Cleanup nodes after strike decays
    setTimeout(() => {
      try {
        carrier.stop();
        modulator.stop();
        carrier.disconnect();
        modulator.disconnect();
        modGain.disconnect();
        ampGain.disconnect();
      } catch (e) {}
    }, 5000);
  };

  const startBellsSound = (ctx: AudioContext, destination: AudioNode) => {
    const frequencies = [261.63, 329.63, 392.00, 523.25, 659.25]; // Pentatonic scale (C4, E4, G4, C5, E5)

    // Setup an gain for master bells
    const gainNode = ctx.createGain();
    gainNode.gain.setValueAtTime(0.6, ctx.currentTime);
    gainNode.connect(destination);
    bellGainRef.current = gainNode;

    // Trigger initial bell immediately
    triggerSingleBell(ctx, gainNode, frequencies[0]);

    // Interval triggers random bell pitch every 4.5 seconds
    const interval = setInterval(() => {
      const idx = Math.floor(Math.random() * frequencies.length);
      triggerSingleBell(ctx, gainNode, frequencies[idx]);
    }, 4500);

    bellTimerRef.current = interval;
  };

  // UI styling bindings
  const containerClass = 
    theme === 'dark' 
      ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' 
      : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]';

  const selectBtnClass = (active: boolean) => 
    active 
      ? (theme === 'dark' ? 'bg-[#A3B1BC] text-[#111315] border-[#8E9AA6] font-semibold' : 'bg-[#536250] text-white border-[#445242] font-semibold')
      : (theme === 'dark' ? 'bg-[#111315] hover:bg-[#24292D] text-[#878F96] border-[#24292D]' : 'bg-white hover:bg-[#FAF8F5] text-[#786E63] border-[#EAE4D8]');

  const controlBtnClass = 
    isPlaying 
      ? 'bg-red-500 hover:bg-red-600 text-white' 
      : (theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' : 'bg-[#536250] hover:bg-[#445242] text-white');

  return (
    <div className={`p-4 rounded-2xl border flex flex-col gap-4 transition-all duration-300 shadow-2xs ${containerClass}`}>
      
      {/* Sound scape description */}
      <div className="flex items-center gap-3">
        <div className={`w-8 h-8 rounded-xl flex items-center justify-center border ${
          theme === 'dark' ? 'bg-[#111315] border-[#24292D] text-[#A3B1BC]' : 'bg-white border-[#EAE4D8] text-[#536250]'
        }`}>
          <Volume2 className="w-4 h-4" />
        </div>
        <div>
          <h4 className="text-[10px] font-bold uppercase tracking-wider">Ambient Loop Synth</h4>
          <p className="text-[9px] text-stone-500">Procedural loops generated in real-time</p>
        </div>
      </div>

      {/* Preset selections */}
      <div className="flex gap-1.5 overflow-x-auto scrollbar-none">
        <button
          onClick={() => setActiveSound('rain')}
          className={`px-2.5 py-1 text-[8px] uppercase tracking-wider font-bold rounded-lg border cursor-pointer ${selectBtnClass(activeSound === 'rain')}`}
        >
          <CloudRain className="w-2.5 h-2.5 inline mr-1" /> Rain
        </button>
        <button
          onClick={() => setActiveSound('resonance')}
          className={`px-2.5 py-1 text-[8px] uppercase tracking-wider font-bold rounded-lg border cursor-pointer ${selectBtnClass(activeSound === 'resonance')}`}
        >
          <Sparkles className="w-2.5 h-2.5 inline mr-1" /> Resonance
        </button>
        <button
          onClick={() => setActiveSound('bells')}
          className={`px-2.5 py-1 text-[8px] uppercase tracking-wider font-bold rounded-lg border cursor-pointer ${selectBtnClass(activeSound === 'bells')}`}
        >
          <Bell className="w-2.5 h-2.5 inline mr-1" /> Temple Bells
        </button>
      </div>

      {/* Active Synth control widgets */}
      <div className="flex items-center gap-3">
        {/* Play State Button */}
        <button
          onClick={handleTogglePlay}
          className={`w-7 h-7 rounded-lg flex items-center justify-center shadow-xs transition-colors cursor-pointer ${controlBtnClass}`}
          title={isPlaying ? "Stop Loop" : "Play Loop"}
        >
          {isPlaying ? <Square className="w-3.5 h-3.5 fill-current" /> : <Play className="w-3.5 h-3.5 fill-current ml-0.5" />}
        </button>

        {/* Volume controls */}
        <div className="flex items-center gap-1.5">
          <button
            onClick={() => setIsMuted(!isMuted)}
            className="text-stone-400 hover:text-stone-600 transition-colors cursor-pointer"
          >
            {isMuted || volume === 0 ? <VolumeX className="w-3.5 h-3.5 text-red-500" /> : <Volume2 className="w-3.5 h-3.5" />}
          </button>
          <input
            type="range"
            min="0"
            max="1"
            step="0.05"
            value={volume}
            onChange={(e) => {
              setVolume(parseFloat(e.target.value));
              setIsMuted(false);
            }}
            className={`w-16 h-1 bg-stone-300 rounded-lg appearance-none cursor-pointer ${
              theme === 'dark' ? 'accent-[#A3B1BC]' : 'accent-[#536250]'
            }`}
          />
        </div>
      </div>

    </div>
  );
}
