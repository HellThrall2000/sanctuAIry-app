import React from 'react';
import { motion } from 'motion/react';
import { Check, Sparkles, Compass, Eye, Moon, Sun } from 'lucide-react';

interface DesignSetupProps {
  currentTheme: 'light' | 'dark';
  onSelectTheme: (theme: 'light' | 'dark') => void;
  onEnter: () => void;
}

export default function DesignSetup({
  currentTheme,
  onSelectTheme,
  onEnter
}: DesignSetupProps) {
  
  const options = [
    {
      id: 'light' as const,
      name: 'Zen Earth',
      subtitle: 'The Pale Warm Organic',
      description: 'A crisp, beautiful warm-sand canvas inspired by natural clay, soft stones, and terracotta accents. Perfect for peaceful daytime clarity and modern minimalistic writing.',
      bgPreview: 'bg-[#F5F2EB]',
      cardBg: 'bg-[#FAF8F5] border-[#EAE4D8]',
      textColor: 'text-[#3D3830]',
      accentBg: 'bg-[#536250]',
      icon: Sun,
    },
    {
      id: 'dark' as const,
      name: 'Steel Monochrome',
      subtitle: 'The Matte Slate Night',
      description: 'A deep, light-shielding matte steel background with silver accents and clean high-contrast elements. Tailored for nocturnal focus and sensory tranquility.',
      bgPreview: 'bg-[#111315]',
      cardBg: 'bg-[#1A1D20] border-[#24292D]',
      textColor: 'text-[#E2E6E9]',
      accentBg: 'bg-[#A3B1BC]',
      icon: Moon,
    }
  ];

  return (
    <div className="min-h-screen flex flex-col justify-center items-center px-4 md:px-8 py-10 transition-colors duration-500 bg-[#FAF9F6] text-[#292524] overflow-y-auto">
      
      {/* Background Ambience Layer */}
      <div className="absolute inset-0 opacity-10 pointer-events-none transition-all duration-1000 bg-radial from-stone-500/10 via-transparent to-transparent" />
      
      <div className="max-w-4xl w-full z-10 space-y-8 text-center">
        
        {/* HEADER SECTION */}
        <div className="space-y-3">
          <motion.div 
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-stone-100 border border-stone-200 text-stone-700 text-[10px] font-bold uppercase tracking-wider"
          >
            <Compass className="w-3.5 h-3.5" /> SANCTUARY BUILDER
          </motion.div>
          
          <motion.h1 
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.1 }}
            className="text-3xl md:text-4xl font-bold tracking-tight text-stone-900"
          >
            Select your writing sanctuary aesthetic
          </motion.h1>
          
          <motion.p 
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.2 }}
            className="text-xs text-stone-500 max-w-xl mx-auto leading-relaxed"
          >
            Configure your space before starting. Choose between a warm organic earth mode or a cool steel monochrome night mode. Both themes feature a single, modern minimalistic typeface.
          </motion.p>
        </div>

        {/* DESIGN CHOICES GRID */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 pt-4 max-w-2xl mx-auto">
          {options.map((opt, idx) => {
            const isSelected = currentTheme === opt.id;
            const Icon = opt.icon;
            return (
              <motion.div
                key={opt.id}
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.1 + idx * 0.1 }}
                whileHover={{ y: -4 }}
                onClick={() => {
                  onSelectTheme(opt.id);
                  onEnter();
                }}
                className={`relative rounded-3xl p-6 border text-left cursor-pointer transition-all duration-300 shadow-sm flex flex-col justify-between min-h-[280px] ${
                  isSelected 
                    ? 'ring-2 ring-stone-800 bg-white border-transparent shadow-md' 
                    : 'bg-[#fcfcf9] hover:bg-white border-stone-200/80 hover:shadow-xs'
                }`}
              >
                {/* Visual Accent Badge */}
                {isSelected && (
                  <div className="absolute -top-2.5 -right-2.5 w-6 h-6 rounded-full bg-stone-850 text-white flex items-center justify-center shadow-md">
                    <Check className="w-3.5 h-3.5 stroke-[3]" />
                  </div>
                )}

                <div className="space-y-4">
                  {/* Theme Small Preview Circle */}
                  <div className="flex items-center gap-3">
                    <div className={`w-8 h-8 rounded-xl border border-stone-200/50 flex items-center justify-center shadow-xs overflow-hidden ${opt.bgPreview}`}>
                      <Icon className={`w-4 h-4 ${isSelected ? 'text-stone-850' : 'text-stone-400'}`} />
                    </div>
                    <div>
                      <h3 className="text-xs font-bold uppercase tracking-wider text-stone-900">{opt.name}</h3>
                      <p className="text-[10px] text-stone-400 font-medium">{opt.subtitle}</p>
                    </div>
                  </div>

                  <p className="text-[11px] text-stone-500 leading-relaxed">
                    {opt.description}
                  </p>
                </div>

                <div className="space-y-3 pt-4 border-t border-stone-100">
                  <div className="flex justify-between items-center text-[10px]">
                    <span className="text-stone-400 font-semibold uppercase">Typography</span>
                    <span className="font-bold text-stone-700">Minimalistic Sans (Inter)</span>
                  </div>
                  <div className="flex justify-between items-center text-[10px]">
                    <span className="text-stone-400 font-semibold uppercase">Colors</span>
                    <span className="font-bold text-stone-700">{opt.id === 'light' ? 'Earth tones' : 'Steel monochrome'}</span>
                  </div>

                  <button 
                    onClick={(e) => {
                      e.stopPropagation();
                      onSelectTheme(opt.id);
                      onEnter();
                    }}
                    className={`w-full text-[10px] uppercase font-bold py-2 rounded-xl border text-center transition-all cursor-pointer ${
                      isSelected 
                        ? 'bg-stone-850 text-white border-stone-900' 
                        : 'bg-white hover:bg-stone-50 text-stone-700 border-stone-200'
                    }`}
                  >
                    Select & Enter Sanctuary
                  </button>
                </div>
              </motion.div>
            );
          })}
        </div>

        {/* PROCEED TRIGGER */}
        <motion.div 
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.4 }}
          className="pt-6 flex flex-col sm:flex-row justify-center items-center gap-4"
        >
          <div className="flex items-center gap-1.5 text-[11px] text-stone-500">
            <Sparkles className="w-3.5 h-3.5 text-stone-600" />
            <span>Passcode encryption & companion memory ready</span>
          </div>

          <button
            onClick={onEnter}
            className="w-full sm:w-auto px-10 py-3.5 rounded-2xl bg-[#1C1917] hover:bg-[#292524] text-white font-bold uppercase tracking-wider text-xs shadow-md hover:shadow-lg transition-all cursor-pointer"
          >
            Enter Sanctuary
          </button>
        </motion.div>

      </div>
    </div>
  );
}
