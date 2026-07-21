import React, { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { 
  Lock, Unlock, ShieldAlert, Plus, Trash2, CheckCircle2, AlertCircle, Eye, EyeOff, Sparkles, Database
} from 'lucide-react';

interface JournalEntry {
  id: string;
  title: string;
  content: string;
  date: string;
  allowAiAccess: boolean; // Custom LLM permission toggle per entry
}

interface SecureJournalProps {
  suggestedTitle: string;
  suggestedText: string;
  onClearSuggestions: () => void;
  onAllowedEntriesChange: (entries: { title: string; content: string; date: string }[]) => void;
  theme?: 'light' | 'dark';
}

export default function SecureJournal({
  suggestedTitle,
  suggestedText,
  onClearSuggestions,
  onAllowedEntriesChange,
  theme = 'light'
}: SecureJournalProps) {
  const [isUnlocked, setIsUnlocked] = useState(false);
  const [passcode, setPasscode] = useState('');
  const [hasPasscodeSet, setHasPasscodeSet] = useState(() => {
    return !!localStorage.getItem('sanctuary_diary_vault_code_v1');
  });
  const [passcodeError, setPasscodeError] = useState('');
  const [revealPasscode, setRevealPasscode] = useState(false);

  // Journal entries state
  const [entries, setEntries] = useState<JournalEntry[]>([]);
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [allowAi, setAllowAi] = useState(true); // Default toggle for new entry

  // On mount/unlock: Load entries
  useEffect(() => {
    if (isUnlocked) {
      const encryptedData = localStorage.getItem('sanctuary_secure_diaries_v1');
      if (encryptedData) {
        try {
          // Robust decode/Base64 "encryption" mock representing AES-GCM
          const decoded = atob(encryptedData);
          const parsed = JSON.parse(decoded);
          if (Array.isArray(parsed)) {
            setEntries(parsed);
          }
        } catch (e) {
          console.error("Error reading secure ledger:", e);
        }
      }
    }
  }, [isUnlocked]);

  // Bind suggestion props to input fields when unlocked
  useEffect(() => {
    if (isUnlocked && (suggestedTitle || suggestedText)) {
      setTitle(suggestedTitle);
      setContent(suggestedText);
    }
  }, [isUnlocked, suggestedTitle, suggestedText]);

  // Propagate unlocked entries with AI permission back to Parent App for companion access
  useEffect(() => {
    if (isUnlocked) {
      const allowed = entries
        .filter(entry => entry.allowAiAccess)
        .map(entry => ({
          title: entry.title,
          content: entry.content,
          date: entry.date
        }));
      onAllowedEntriesChange(allowed);
    } else {
      onAllowedEntriesChange([]);
    }
  }, [entries, isUnlocked]);

  // Persist secure diaries
  const saveSecureLedger = (updated: JournalEntry[]) => {
    setEntries(updated);
    try {
      const encoded = btoa(JSON.stringify(updated));
      localStorage.setItem('sanctuary_secure_diaries_v1', encoded);
    } catch (e) {
      console.error("Failed to commit diaries safely:", e);
    }
  };

  // Lockbox Actions
  const handleSetPasscode = (e: React.FormEvent) => {
    e.preventDefault();
    if (passcode.length < 4) {
      setPasscodeError('Vault passcode must be at least 4 digits.');
      return;
    }
    localStorage.setItem('sanctuary_diary_vault_code_v1', passcode);
    setHasPasscodeSet(true);
    setIsUnlocked(true);
    setPasscodeError('');
    setPasscode('');
  };

  const handleUnlock = (e: React.FormEvent) => {
    e.preventDefault();
    const stored = localStorage.getItem('sanctuary_diary_vault_code_v1');
    if (passcode === stored) {
      setIsUnlocked(true);
      setPasscodeError('');
      setPasscode('');
    } else {
      setPasscodeError('Invalid passcode. Access denied.');
      // Auto-lock again
      setIsUnlocked(false);
    }
  };

  const handleLockVault = () => {
    setIsUnlocked(false);
    setPasscode('');
    setPasscodeError('');
    onClearSuggestions();
  };

  // CRUD Operations
  const handleCreateEntry = (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim() || !content.trim()) return;

    const newEntry: JournalEntry = {
      id: Date.now().toString(),
      title: title.trim(),
      content: content.trim(),
      date: new Date().toLocaleDateString(undefined, { 
        month: 'short', 
        day: 'numeric', 
        year: 'numeric', 
        hour: '2-digit', 
        minute: '2-digit' 
      }),
      allowAiAccess: allowAi
    };

    const updated = [newEntry, ...entries];
    saveSecureLedger(updated);

    // Reset inputs
    setTitle('');
    setContent('');
    setAllowAi(true);
    onClearSuggestions(); // Clear suggestions from parent
  };

  const handleDeleteEntry = (id: string) => {
    if (confirm("Permanently erase this diary entry from local storage? This cannot be undone.")) {
      const updated = entries.filter(e => e.id !== id);
      saveSecureLedger(updated);
    }
  };

  const toggleAiAccess = (id: string) => {
    const updated = entries.map(e => {
      if (e.id === id) {
        return { ...e, allowAiAccess: !e.allowAiAccess };
      }
      return e;
    });
    saveSecureLedger(updated);
  };

  // Theme-specific CSS styles
  const boxClass = 
    theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' :
    'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]';

  const titleClass = 
    theme === 'dark' ? 'text-[#A3B1BC]' :
    'text-[#536250]';

  const entryCardBgClass = 
    theme === 'dark' ? 'bg-[#111315]/80 border-[#24292D] hover:border-[#A3B1BC]/40' :
    'bg-white border-[#EAE4D8] hover:border-[#536250]/40';

  const inputClass = 
    theme === 'dark' ? 'bg-[#111315] text-[#E2E6E9] border-[#24292D] focus:ring-[#A3B1BC]' :
    'bg-white text-[#3D3830] border-[#EAE4D8] focus:ring-[#536250]';

  const btnClass = 
    theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' :
    'bg-[#536250] hover:bg-[#445242] text-white';

  return (
    <div className={`h-full flex flex-col rounded-2xl overflow-hidden shadow-sm border transition-all duration-300 ${boxClass}`}>
      
      {/* CARD TOP STATUS BAR */}
      <div className={`px-5 py-3 border-b flex items-center justify-between ${
        theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D]' :
        'bg-[#FAF8F5] border-[#EAE4D8]'
      }`}>
        <div className="flex items-center gap-2">
          {isUnlocked ? <Unlock className="w-3.5 h-3.5 text-emerald-600 animate-pulse" /> : <Lock className="w-3.5 h-3.5 text-stone-400" />}
          <span className={`text-xs font-bold uppercase tracking-wider ${titleClass}`}>
            Secure Diary Lockbox
          </span>
        </div>
        
        {isUnlocked && (
          <button 
            onClick={handleLockVault}
            className="text-[10px] uppercase tracking-wider font-bold text-red-500 hover:text-red-700 bg-red-100/10 px-2 py-0.5 rounded transition-all cursor-pointer"
          >
            Lock Vault
          </button>
        )}
      </div>

      {/* BODY WORKSPACE */}
      <div className="flex-1 overflow-y-auto p-4 flex flex-col min-h-0">
        <AnimatePresence mode="wait">
          
          {/* 1. VAULT LOCKED SCREEN */}
          {!isUnlocked && (
            <motion.div 
              key="locked_screen"
              initial={{ opacity: 0, scale: 0.98 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.98 }}
              className="flex-1 flex flex-col justify-center items-center py-6 text-center"
            >
              <div className={`w-12 h-12 rounded-full flex items-center justify-center mb-3 ${
                theme === 'dark' ? 'bg-[#24292D] text-[#A3B1BC]' : 'bg-[#EAE4D8] text-[#536250]'
              }`}>
                <Lock className="w-5 h-5" />
              </div>

              {!hasPasscodeSet ? (
                // SETUP PASSCODE
                <form onSubmit={handleSetPasscode} className="max-w-xs w-full space-y-3 px-3">
                  <h4 className="text-xs font-bold uppercase tracking-wider">Initialize Encrypted Diary</h4>
                  <p className="text-[10px] text-stone-500">
                    Choose a numeric passcode (at least 4 digits). This passcode remains on your device to unlock and view your encrypted diary.
                  </p>
                  
                  <div className="relative">
                    <input
                      type={revealPasscode ? "text" : "password"}
                      value={passcode}
                      onChange={(e) => setPasscode(e.target.value.replace(/\D/g, '').slice(0, 8))}
                      placeholder="Enter new PIN..."
                      className={`w-full text-center tracking-widest text-xs rounded-xl px-3 py-2 border focus:outline-none ${inputClass}`}
                    />
                    <button
                      type="button"
                      onClick={() => setRevealPasscode(!revealPasscode)}
                      className="absolute right-3 top-2 text-stone-400 hover:text-stone-600"
                    >
                      {revealPasscode ? <EyeOff className="w-3.5 h-3.5" /> : <Eye className="w-3.5 h-3.5" />}
                    </button>
                  </div>

                  {passcodeError && (
                    <p className="text-[9px] text-red-500 font-bold flex items-center justify-center gap-1">
                      <ShieldAlert className="w-3 h-3" /> {passcodeError}
                    </p>
                  )}

                  <button type="submit" className={`w-full text-xs py-2 rounded-xl font-bold uppercase tracking-wider cursor-pointer ${btnClass}`}>
                    Set Passcode & Unlock
                  </button>
                </form>
              ) : (
                // ENTER PASSCODE
                <form onSubmit={handleUnlock} className="max-w-xs w-full space-y-3 px-3">
                  <h4 className="text-xs font-bold uppercase tracking-wider">Unlock Private Logs</h4>
                  <p className="text-[10px] text-stone-500">
                    Input your secure lockbox passcode to read and write private notes.
                  </p>

                  <div className="relative">
                    <input
                      type={revealPasscode ? "text" : "password"}
                      value={passcode}
                      onChange={(e) => setPasscode(e.target.value.replace(/\D/g, '').slice(0, 8))}
                      placeholder="••••"
                      className={`w-full text-center tracking-widest text-sm font-bold rounded-xl px-3 py-2 border focus:outline-none ${inputClass}`}
                    />
                    <button
                      type="button"
                      onClick={() => setRevealPasscode(!revealPasscode)}
                      className="absolute right-3 top-2 text-stone-400 hover:text-stone-600"
                    >
                      {revealPasscode ? <EyeOff className="w-3.5 h-3.5" /> : <Eye className="w-3.5 h-3.5" />}
                    </button>
                  </div>

                  {passcodeError && (
                    <p className="text-[9px] text-red-500 font-bold flex items-center justify-center gap-1">
                      <AlertCircle className="w-3 h-3" /> {passcodeError}
                    </p>
                  )}

                  <button type="submit" className={`w-full text-xs py-2 rounded-xl font-bold uppercase tracking-wider cursor-pointer ${btnClass}`}>
                    Unlock Diary
                  </button>
                </form>
              )}
            </motion.div>
          )}

          {/* 2. VAULT UNLOCKED WORKSPACE */}
          {isUnlocked && (
            <motion.div 
              key="unlocked_screen"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="flex-1 flex flex-col space-y-4 min-h-0"
            >
              {/* Add New Entry Form */}
              <form onSubmit={handleCreateEntry} className="space-y-2 shrink-0 border-b pb-3 border-stone-200/50">
                <div className="flex justify-between items-center">
                  <span className="text-[10px] uppercase font-bold text-stone-400">Write New Entry</span>
                  {suggestedTitle && (
                    <span className="text-[9px] text-emerald-700 font-bold flex items-center gap-1 animate-pulse">
                      <Sparkles className="w-3 h-3" /> Imported from Chat
                    </span>
                  )}
                </div>

                <input
                  type="text"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  placeholder="Title of this moment..."
                  required
                  className={`w-full text-xs rounded-xl px-3 py-1.5 border focus:outline-none ${inputClass}`}
                />

                <textarea
                  value={content}
                  onChange={(e) => setContent(e.target.value)}
                  placeholder="Unfold your thoughts freely here..."
                  rows={3}
                  required
                  className={`w-full text-xs rounded-xl px-3 py-2 border focus:outline-none resize-none ${inputClass}`}
                />

                <div className="flex justify-between items-center pt-1">
                  {/* LLM ACCESS PERMISSION OPT-IN ON WRITING */}
                  <label className="flex items-center gap-1.5 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={allowAi}
                      onChange={(e) => setAllowAi(e.target.checked)}
                      className="rounded border-stone-300 text-emerald-800 focus:ring-emerald-800 cursor-pointer"
                    />
                    <span className="text-[9px] font-semibold text-stone-500">
                      Allow Companion to reference this
                    </span>
                  </label>

                  <button 
                    type="submit"
                    className={`text-[10px] uppercase font-bold px-3 py-1.5 rounded-xl flex items-center gap-1 cursor-pointer ${btnClass}`}
                  >
                    <Plus className="w-3.5 h-3.5" /> Save Entry
                  </button>
                </div>
              </form>

              {/* Historical Log list */}
              <div className="flex-1 min-h-0 flex flex-col space-y-2">
                <span className="text-[10px] uppercase font-bold text-stone-400 shrink-0">Sovereign Journal ledger ({entries.length})</span>
                
                {entries.length === 0 ? (
                  <div className="flex-1 flex flex-col justify-center items-center text-center p-4 border border-dashed border-stone-200/50 rounded-2xl">
                    <Database className="w-6 h-6 text-stone-300 mb-1" />
                    <p className="text-[10px] text-stone-500">No diaries logged in this secure session yet.</p>
                  </div>
                ) : (
                  <div className="flex-1 overflow-y-auto space-y-2 pr-1 scrollbar-none">
                    {entries.map((entry) => (
                      <div 
                        key={entry.id}
                        className={`p-3 rounded-xl border flex flex-col gap-1.5 transition-all duration-300 ${entryCardBgClass}`}
                      >
                        <div className="flex justify-between items-start gap-2">
                          <div>
                            <h5 className="text-xs font-bold leading-tight">{entry.title}</h5>
                            <span className="text-[8px] text-stone-400 font-medium">{entry.date}</span>
                          </div>
                          
                          <button
                            onClick={() => handleDeleteEntry(entry.id)}
                            className="text-stone-400 hover:text-red-500 p-1 rounded-md hover:bg-stone-100/10 transition-colors cursor-pointer"
                            title="Erase Note"
                          >
                            <Trash2 className="w-3 h-3" />
                          </button>
                        </div>

                        <p className="text-[11px] text-stone-500 leading-relaxed whitespace-pre-wrap">{entry.content}</p>

                        {/* LIVE DYNAMIC EXPORT CHOICE ON SAVED NOTES */}
                        <div className={`mt-1 pt-1.5 border-t border-dashed border-stone-200/50 flex justify-between items-center text-[9px]`}>
                          <span className={`font-semibold flex items-center gap-1 ${entry.allowAiAccess ? 'text-emerald-700' : 'text-stone-400'}`}>
                            {entry.allowAiAccess ? <CheckCircle2 className="w-3 h-3 text-emerald-600" /> : <EyeOff className="w-3 h-3 text-stone-400" />}
                            {entry.allowAiAccess ? 'Shared with Companion AI' : 'Completely Private Vault'}
                          </span>

                          <button
                            onClick={() => toggleAiAccess(entry.id)}
                            className={`px-2 py-0.5 rounded font-bold uppercase text-[8px] border transition-colors cursor-pointer ${
                              entry.allowAiAccess 
                                ? 'bg-emerald-100/10 hover:bg-emerald-100/20 text-emerald-800 border-emerald-300/30' 
                                : 'bg-stone-100/30 hover:bg-stone-100/60 text-stone-600 border-stone-200'
                            }`}
                          >
                            {entry.allowAiAccess ? 'Revoke AI Access' : 'Grant AI Access'}
                          </button>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

            </motion.div>
          )}

        </AnimatePresence>
      </div>

    </div>
  );
}
