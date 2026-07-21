import React, { useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { 
  Heart, ShieldCheck, Compass, User, BookOpen, Moon, Sun, X, Menu, Lock
} from 'lucide-react';

import CbtCompanion from './components/CbtCompanion';
import SecureJournal from './components/SecureJournal';
import Soundscape from './components/Soundscape';
import DesignSetup from './components/DesignSetup';

export default function App() {
  const [suggestedTitle, setSuggestedTitle] = useState('');
  const [suggestedText, setSuggestedText] = useState('');
  const [allowedJournals, setAllowedJournals] = useState<{ title: string; content: string; date: string }[] | null>(null);
  
  const [user, setUser] = useState<{ name: string; email: string; picture: string } | null>(() => {
    const saved = localStorage.getItem('sanctuary_user');
    return saved ? JSON.parse(saved) : null;
  });
  const [showDemoModal, setShowDemoModal] = useState(false);
  const [demoName, setDemoName] = useState('Sovereign Soul');
  const [demoEmail, setDemoEmail] = useState('explorer@sanctuary.private');

  const [theme, setTheme] = useState<'light' | 'dark'>(() => {
    return (localStorage.getItem('sanctuary_theme') as 'light' | 'dark') || 'light';
  });

  const [showSetup, setShowSetup] = useState(() => {
    return !localStorage.getItem('sanctuary_design_selected');
  });

  const [isLeftDrawerOpen, setIsLeftDrawerOpen] = useState(false);
  const [isRightDrawerOpen, setIsRightDrawerOpen] = useState(false);

  React.useEffect(() => {
    // 1. PostMessage handler for immediate callback inside popups
    const handleMessage = (event: MessageEvent) => {
      // Validate that message is coming from our own origin or trusted sandbox
      const origin = event.origin;
      if (origin !== window.location.origin && !origin.endsWith('.run.app') && !origin.includes('localhost')) {
        return;
      }
      
      if (event.data?.type === 'OAUTH_AUTH_SUCCESS') {
        const loggedUser = event.data.user;
        if (loggedUser) {
          setUser(loggedUser);
          localStorage.setItem('sanctuary_user', JSON.stringify(loggedUser));
          setIsLeftDrawerOpen(false); // Close left drawer on success
        }
      }
    };

    // 2. Storage event listener (syncs across tabs and when popup changes localStorage on the same origin)
    const handleStorageChange = (event: StorageEvent) => {
      if (event.key === 'sanctuary_user') {
        try {
          const loggedUser = event.newValue ? JSON.parse(event.newValue) : null;
          setUser(loggedUser);
          if (loggedUser) {
            setIsLeftDrawerOpen(false);
          }
        } catch (err) {
          console.error("Storage parse error:", err);
        }
      }
    };

    // 3. Window focus event listener (instant fallback when focus returns to the main window)
    const handleFocus = () => {
      try {
        const saved = localStorage.getItem('sanctuary_user');
        const parsed = saved ? JSON.parse(saved) : null;
        if (parsed) {
          if (!user || user.email !== parsed.email || user.name !== parsed.name || user.picture !== parsed.picture) {
            setUser(parsed);
            setIsLeftDrawerOpen(false);
          }
        } else if (user) {
          // If deleted in storage elsewhere, logout here too
          setUser(null);
        }
      } catch (err) {
        console.error("Focus sync error:", err);
      }
    };

    window.addEventListener('message', handleMessage);
    window.addEventListener('storage', handleStorageChange);
    window.addEventListener('focus', handleFocus);

    return () => {
      window.removeEventListener('message', handleMessage);
      window.removeEventListener('storage', handleStorageChange);
      window.removeEventListener('focus', handleFocus);
    };
  }, [user]);

  const handleGoogleLoginClick = async () => {
    try {
      const redirectUri = `${window.location.origin}/auth/callback`;
      const response = await fetch(`/api/auth/google/url?redirect_uri=${encodeURIComponent(redirectUri)}`);
      if (!response.ok) {
        throw new Error("Failed to contact auth server");
      }
      const data = await response.json();
      if (data.isDemo) {
        setShowDemoModal(true);
      } else {
        const authWindow = window.open(
          data.url,
          'google_oauth_popup',
          'width=500,height=650'
        );
        if (!authWindow) {
          alert('Popup blocked. Please allow popups for Google Sign-In.');
        }
      }
    } catch (err) {
      console.error("Auth initialization error:", err);
      setShowDemoModal(true);
    }
  };

  const handleLogout = () => {
    setUser(null);
    localStorage.removeItem('sanctuary_user');
  };

  const handleDemoSignIn = () => {
    const mockUser = {
      name: demoName || 'Sovereign Soul',
      email: demoEmail || 'explorer@sanctuary.private',
      picture: ''
    };
    setUser(mockUser);
    localStorage.setItem('sanctuary_user', JSON.stringify(mockUser));
    setShowDemoModal(false);
    setIsLeftDrawerOpen(false);
  };

  const handleSetTheme = (newTheme: 'light' | 'dark') => {
    setTheme(newTheme);
    localStorage.setItem('sanctuary_theme', newTheme);
  };

  const handleEnterSanctuary = () => {
    localStorage.setItem('sanctuary_design_selected', 'true');
    setShowSetup(false);
  };

  const handleSuggestJournalEntry = (title: string, text: string) => {
    setSuggestedTitle(title);
    setSuggestedText(text);
    // Auto open the right drawer so the user can easily view and save the suggestion
    setIsRightDrawerOpen(true);
  };

  const handleAllowedEntriesChange = (entries: { title: string; content: string; date: string }[]) => {
    setAllowedJournals(entries);
  };

  const handleClearSuggestions = () => {
    setSuggestedTitle('');
    setSuggestedText('');
  };

  // Theme-specific style sheets mapping Zen Earth (light) and Steel Monochrome (dark)
  const themeClass = 
    theme === 'dark' 
      ? 'bg-[#111315] text-[#E2E6E9] font-sans selection:bg-[#2C3136] selection:text-[#E2E6E9]' 
      : 'bg-[#F5F2EB] text-[#3D3830] font-sans selection:bg-[#E2DDD3] selection:text-[#3D3830]';

  const headerClass = 
    theme === 'dark' ? 'border-[#24292D] bg-[#1A1D20]' : 'border-[#EAE4D8] bg-[#FAF8F5]';

  const titleTextClass = 
    theme === 'dark' ? 'text-[#A3B1BC] font-sans font-bold' : 'text-[#536250] font-sans font-bold';

  const subtitleTextClass = 
    theme === 'dark' ? 'text-[#878F96] font-sans' : 'text-[#786E63] font-sans';

  const footerClass = 
    theme === 'dark' 
      ? 'border-[#24292D] bg-[#1A1D20] text-[#878F96] font-sans' 
      : 'border-[#EAE4D8] bg-[#FAF8F5] text-[#786E63] font-sans';

  if (showSetup) {
    return (
      <DesignSetup 
        currentTheme={theme} 
        onSelectTheme={handleSetTheme} 
        onEnter={handleEnterSanctuary} 
      />
    );
  }

  return (
    <div className={`h-screen overflow-hidden flex flex-col antialiased transition-colors duration-300 ${themeClass}`}>
      
      {/* SANCTUARY HEADER */}
      <header className={`border-b shrink-0 px-6 py-3 flex justify-between items-center transition-all duration-300 ${headerClass}`}>
        <div className="flex items-center gap-3">
          {/* Menu Button / Settings Trigger */}
          <button 
            onClick={() => setIsLeftDrawerOpen(true)}
            className={`p-2 rounded-xl border transition-all cursor-pointer shadow-2xs hover:scale-[1.02] active:scale-[0.98] ${
              theme === 'dark' ? 'bg-[#111315] border-[#24292D] text-[#A3B1BC] hover:bg-[#1C1E22]' : 'bg-white border-[#EAE4D8] text-[#536250] hover:bg-[#FAF8F5]'
            }`}
            title="Open Space Settings"
          >
            <Menu className="w-4 h-4" />
          </button>

          <div className="flex items-center gap-2.5">
            <div className={`w-8 h-8 rounded-xl flex items-center justify-center shadow-2xs border ${
              theme === 'dark' ? 'bg-[#24292D] border-[#24292D] text-[#A3B1BC]' : 'bg-white border-[#EAE4D8] text-[#536250]'
            }`}>
              <Heart className="w-4 h-4 fill-current" />
            </div>
            <div>
              <h1 className={`text-sm font-bold tracking-tight leading-none ${titleTextClass}`}>
                Sanctuary
              </h1>
              <p className={`text-[8px] font-semibold uppercase tracking-widest ${subtitleTextClass}`}>
                Private Companion & Diary Lockbox
              </p>
            </div>
          </div>
        </div>

        {/* Change Design Choice / Layout Aesthetic toggles */}
        <div className="flex items-center gap-2">
          {/* Click to open secure journal drawer */}
          <button 
            onClick={() => setIsRightDrawerOpen(true)}
            className={`px-4 py-2 text-[10px] font-bold uppercase tracking-wider rounded-xl border cursor-pointer shadow-2xs transition-all flex items-center gap-1.5 ${
              theme === 'dark' ? 'bg-[#24292D] hover:bg-[#2C3136] text-[#A3B1BC] border-[#24292D]' : 'bg-white hover:bg-stone-50 text-[#536250] border-[#EAE4D8]'
            }`}
            title="Open Secure Diary Lockbox"
          >
            <BookOpen className="w-3.5 h-3.5" />
            <span>Open Diary</span>
          </button>

          <button 
            onClick={() => setShowSetup(true)}
            className={`px-3.5 py-2 text-[10px] font-bold uppercase tracking-wider rounded-xl border cursor-pointer shadow-2xs transition-all ${
              theme === 'dark' ? 'bg-[#111315] hover:bg-[#1C1E22] text-[#878F96] border-[#24292D]' : 'bg-[#FAF8F5] hover:bg-[#FAF8F5] text-[#786E63] border-[#EAE4D8]'
            }`}
            title="Adjust layout & typography aesthetic styles"
          >
            Aesthetics
          </button>
        </div>
      </header>

      {/* STATIC CORE LAYOUT: FULL HEIGHT FILL, NO OUTER SCROLL */}
      <main className="flex-1 w-full mx-auto p-4 flex flex-col overflow-hidden">
        {/* Main interactive area */}
        <div className="flex-1 w-full max-w-4xl mx-auto flex flex-col overflow-hidden">
          <CbtCompanion 
            onSuggestJournalEntry={handleSuggestJournalEntry}
            allowedJournals={allowedJournals}
            theme={theme}
            user={user}
          />
        </div>
      </main>

      {/* SANCTUARY ACCESSIBILITY FOOTER */}
      <footer className={`border-t px-6 py-2.5 shrink-0 flex flex-col md:flex-row justify-between items-center text-[10px] gap-3 transition-all duration-300 ${footerClass}`}>
        <div className="flex items-center gap-2">
          <ShieldCheck className="w-4 h-4 text-stone-500 shrink-0" />
          <span>Sovereign Local Sandbox — Completely offline database — Zero cloud synchronization</span>
        </div>
        <div className="flex gap-4 font-semibold uppercase tracking-wider text-[9px]">
          <span>Passcode Encryption</span>
          <span>Web Audio Loop Synth</span>
          <span>Privacy Sanctuary</span>
        </div>
      </footer>

      {/* SIDE DRAWERS */}
      <AnimatePresence>
        {/* LEFT DRAWER (Settings, User, Mode & Soundscape) */}
        {isLeftDrawerOpen && (
          <>
            {/* Backdrop */}
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setIsLeftDrawerOpen(false)}
              className="fixed inset-0 bg-black/30 z-40 backdrop-blur-[1px]"
            />
            
            {/* Drawer Panel */}
            <motion.div
              initial={{ x: '-100%' }}
              animate={{ x: 0 }}
              exit={{ x: '-100%' }}
              transition={{ type: 'tween', duration: 0.25 }}
              className={`fixed top-0 left-0 h-full w-[330px] max-w-[90vw] z-50 border-r shadow-2xl p-6 flex flex-col gap-6 overflow-y-auto ${
                theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]'
              }`}
            >
              {/* Drawer Header */}
              <div className="flex justify-between items-center shrink-0">
                <div className="flex items-center gap-2">
                  <Compass className="w-4 h-4 text-stone-400" />
                  <h3 className="text-xs font-bold uppercase tracking-wider text-stone-400">Sanctuary Controls</h3>
                </div>
                <button 
                  onClick={() => setIsLeftDrawerOpen(false)} 
                  className="p-1.5 rounded-lg hover:bg-stone-500/10 transition-colors cursor-pointer"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>

              {/* User profile block */}
              <div className={`p-4 rounded-xl border flex flex-col gap-2 shrink-0 ${
                theme === 'dark' ? 'bg-[#111315] border-[#24292D]' : 'bg-white border-[#EAE4D8]'
              }`}>
                {user ? (
                  <>
                    <div className="flex items-center gap-2.5">
                      {user.picture ? (
                        <img 
                          src={user.picture} 
                          alt={user.name} 
                          className="w-7 h-7 rounded-lg border border-stone-200/50 object-cover" 
                          referrerPolicy="no-referrer" 
                        />
                      ) : (
                        <div className={`w-7 h-7 rounded-lg flex items-center justify-center border ${
                          theme === 'dark' ? 'bg-[#24292D] text-[#A3B1BC] border-[#24292D]' : 'bg-[#FAF8F5] text-[#536250] border-[#EAE4D8]'
                        }`}>
                          <User className="w-4 h-4" />
                        </div>
                      )}
                      <div className="flex-1 min-w-0">
                        <h4 className="text-[11px] font-bold uppercase tracking-wider truncate">{user.name}</h4>
                        <p className="text-[8px] text-stone-400 font-mono tracking-widest truncate">{user.email}</p>
                      </div>
                    </div>
                    <button 
                      onClick={handleLogout}
                      className={`w-full mt-1.5 py-1.5 rounded-xl text-[9px] font-bold uppercase tracking-wider border transition-all cursor-pointer ${
                        theme === 'dark' ? 'bg-[#111315] hover:bg-red-950/20 text-red-400 border-red-950/40' : 'bg-white hover:bg-red-50 text-red-700 border-red-100'
                      }`}
                    >
                      Logout Session
                    </button>
                  </>
                ) : (
                  <>
                    <div className="flex items-center gap-2.5">
                      <div className={`w-7 h-7 rounded-lg flex items-center justify-center border ${
                        theme === 'dark' ? 'bg-[#24292D] text-[#A3B1BC] border-[#24292D]' : 'bg-[#FAF8F5] text-[#536250] border-[#EAE4D8]'
                      }`}>
                        <User className="w-4 h-4" />
                      </div>
                      <div>
                        <h4 className="text-[11px] font-bold uppercase tracking-wider">Guest Companion</h4>
                        <p className="text-[8px] text-stone-400 font-mono uppercase tracking-widest">Client ID: Anonymous</p>
                      </div>
                    </div>
                    <button 
                      onClick={handleGoogleLoginClick}
                      className={`w-full mt-1.5 py-2 rounded-xl text-[10px] font-bold uppercase tracking-wider border flex items-center justify-center gap-2 transition-all cursor-pointer ${
                        theme === 'dark' ? 'bg-[#24292D] hover:bg-[#2C3136] text-[#A3B1BC] border-[#24292D]' : 'bg-white hover:bg-stone-50 text-[#536250] border-[#EAE4D8]'
                      }`}
                    >
                      <svg className="w-3.5 h-3.5 fill-current shrink-0" viewBox="0 0 24 24">
                        <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="#4285F4" stroke="none" />
                        <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853" stroke="none" />
                        <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l2.85-2.22.81-.63z" fill="#FBBC05" stroke="none" />
                        <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335" stroke="none" />
                      </svg>
                      <span>Sign In with Google</span>
                    </button>
                  </>
                )}
                <div className="text-[9px] text-stone-500 leading-normal border-t border-stone-200/40 pt-2 space-y-1">
                  <div className="flex justify-between"><span>Sandbox Encryption:</span> <span className="font-semibold text-emerald-600">ACTIVE</span></div>
                  <div className="flex justify-between"><span>Local Storage Ledger:</span> <span className="font-semibold">LOCAL-ONLY</span></div>
                </div>
              </div>

              {/* Light/Dark palette toggler */}
              <div className="space-y-2 shrink-0">
                <h4 className="text-[9px] font-bold uppercase tracking-wider text-stone-400">Aesthetic Palette</h4>
                <div className={`flex p-1 border rounded-xl gap-1 ${
                  theme === 'dark' ? 'bg-[#111315] border-[#24292D]' : 'bg-white border-[#EAE4D8]'
                }`}>
                  <button
                    onClick={() => handleSetTheme('light')}
                    className={`flex-1 flex items-center justify-center gap-1.5 py-1.5 text-[10px] font-semibold rounded-lg transition-all cursor-pointer ${
                      theme === 'light'
                        ? 'bg-[#536250] text-white shadow-xs'
                        : 'text-[#786E63] hover:text-stone-900'
                    }`}
                  >
                    <Sun className="w-3.5 h-3.5" />
                    <span>Zen Earth</span>
                  </button>
                  <button
                    onClick={() => handleSetTheme('dark')}
                    className={`flex-1 flex items-center justify-center gap-1.5 py-1.5 text-[10px] font-semibold rounded-lg transition-all cursor-pointer ${
                      theme === 'dark'
                        ? 'bg-[#A3B1BC] text-[#111315] shadow-xs'
                        : 'text-[#878F96] hover:text-stone-100'
                    }`}
                  >
                    <Moon className="w-3.5 h-3.5" />
                    <span>Steel Night</span>
                  </button>
                </div>
              </div>

              {/* Soundscape controls */}
              <div className="space-y-2 flex-1 flex flex-col justify-end">
                <h4 className="text-[9px] font-bold uppercase tracking-wider text-stone-400">Environment Resonance</h4>
                <Soundscape theme={theme} />
              </div>
            </motion.div>
          </>
        )}

        {/* RIGHT DRAWER (Secure Journal Lockbox) */}
        {isRightDrawerOpen && (
          <>
            {/* Backdrop */}
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setIsRightDrawerOpen(false)}
              className="fixed inset-0 bg-black/30 z-40 backdrop-blur-[1px]"
            />
            
            {/* Drawer Panel */}
            <motion.div
              initial={{ x: '100%' }}
              animate={{ x: 0 }}
              exit={{ x: '100%' }}
              transition={{ type: 'tween', duration: 0.25 }}
              className={`fixed top-0 right-0 h-full w-[480px] max-w-[95vw] z-50 border-l shadow-2xl flex flex-col overflow-hidden ${
                theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]'
              }`}
            >
              {/* Drawer Header */}
              <div className="flex justify-between items-center p-4 border-b border-stone-200/20 shrink-0">
                <div className="flex items-center gap-2">
                  <Lock className="w-4 h-4 text-stone-400" />
                  <h3 className="text-xs font-bold uppercase tracking-wider text-stone-400">Secure Journal Vault</h3>
                </div>
                <button 
                  onClick={() => setIsRightDrawerOpen(false)} 
                  className="p-1.5 rounded-lg hover:bg-stone-500/10 transition-colors cursor-pointer"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>

              {/* Secure Journal Body */}
              <div className="flex-1 min-h-0">
                <SecureJournal 
                  suggestedTitle={suggestedTitle}
                  suggestedText={suggestedText}
                  onClearSuggestions={handleClearSuggestions}
                  onAllowedEntriesChange={handleAllowedEntriesChange}
                  theme={theme}
                />
              </div>
            </motion.div>
          </>
        )}

        {/* GOOGLE SIGN IN CONFIG / DEMO MODAL */}
        {showDemoModal && (
          <>
            {/* Backdrop */}
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setShowDemoModal(false)}
              className="fixed inset-0 bg-black/60 z-50 backdrop-blur-[2px] flex items-center justify-center p-4"
            >
              {/* Modal Container */}
              <motion.div
                initial={{ scale: 0.95, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                exit={{ scale: 0.95, opacity: 0 }}
                onClick={(e) => e.stopPropagation()}
                className={`w-full max-w-md rounded-3xl p-6 border shadow-2xl flex flex-col gap-5 ${
                  theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]'
                }`}
              >
                {/* Modal Header */}
                <div className="flex justify-between items-start">
                  <div>
                    <h3 className={`text-xs font-bold uppercase tracking-wider ${theme === 'dark' ? 'text-[#A3B1BC]' : 'text-[#536250]'}`}>
                      Google Sign-In Sandbox
                    </h3>
                    <p className="text-[10px] text-stone-400 mt-1">Configure your real keys or use our offline Demo</p>
                  </div>
                  <button 
                    onClick={() => setShowDemoModal(false)}
                    className="p-1 rounded-lg hover:bg-stone-500/10 transition-colors cursor-pointer"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>

                {/* Instant Sandbox Profile Config */}
                <div className={`p-4 rounded-2xl border flex flex-col gap-3 ${
                  theme === 'dark' ? 'bg-[#111315]/80 border-[#24292D]' : 'bg-white border-[#EAE4D8]'
                }`}>
                  <span className="text-[9px] font-bold uppercase tracking-wider text-emerald-600">Option 1: Instant Offline Demo Login</span>
                  <div className="space-y-2">
                    <div>
                      <label className="block text-[8px] uppercase tracking-wider font-semibold text-stone-400 mb-1">Display Name</label>
                      <input 
                        type="text" 
                        value={demoName}
                        onChange={(e) => setDemoName(e.target.value)}
                        className={`w-full px-3 py-1.5 text-xs rounded-xl border focus:outline-hidden ${
                          theme === 'dark' ? 'bg-[#1A1D20] text-stone-100 border-[#24292D]' : 'bg-stone-50 text-stone-800 border-stone-200'
                        }`}
                        placeholder="Enter demo name"
                      />
                    </div>
                    <div>
                      <label className="block text-[8px] uppercase tracking-wider font-semibold text-stone-400 mb-1">Email Address</label>
                      <input 
                        type="email" 
                        value={demoEmail}
                        onChange={(e) => setDemoEmail(e.target.value)}
                        className={`w-full px-3 py-1.5 text-xs rounded-xl border focus:outline-hidden ${
                          theme === 'dark' ? 'bg-[#1A1D20] text-stone-100 border-[#24292D]' : 'bg-stone-50 text-stone-800 border-stone-200'
                        }`}
                        placeholder="Enter demo email"
                      />
                    </div>
                  </div>
                  <button 
                    onClick={handleDemoSignIn}
                    className={`w-full py-2.5 rounded-xl text-[10px] font-bold uppercase tracking-wider cursor-pointer shadow-xs transition-all ${
                      theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' : 'bg-[#536250] hover:bg-[#445242] text-white'
                    }`}
                  >
                    Enter Sandbox Session
                  </button>
                </div>

                {/* Instructions on how to add actual secrets */}
                <div className="space-y-2.5 text-[10px] leading-relaxed text-stone-400">
                  <span className="block text-[9px] font-bold uppercase tracking-wider text-stone-400">Option 2: Live Google Credentials Setup</span>
                  <p>To connect live, follow these quick steps:</p>
                  <ol className="list-decimal pl-4 space-y-1 font-sans text-[9.5px]">
                    <li>Go to the Google Cloud Console and obtain a Client ID & Secret.</li>
                    <li>Add your Redirect URI in Google settings:
                      <code className={`block mt-1 p-1 rounded font-mono text-[8px] select-all ${theme === 'dark' ? 'bg-black/30 text-emerald-400' : 'bg-stone-100 text-emerald-800'}`}>
                        {window.location.origin}/auth/callback
                      </code>
                    </li>
                    <li>In the upper-right corner of AI Studio, open <b>Settings &gt; Secrets</b>, and add these environment variables:
                      <ul className="list-disc pl-4 mt-1 font-mono text-[8px] text-stone-300">
                        <li><span className="font-bold">GOOGLE_CLIENT_ID</span></li>
                        <li><span className="font-bold">GOOGLE_CLIENT_SECRET</span></li>
                      </ul>
                    </li>
                  </ol>
                </div>
              </motion.div>
            </motion.div>
          </>
        )}
      </AnimatePresence>

    </div>
  );
}
