import React, { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { 
  Send, User, Brain, Lock, RefreshCw, Sparkles, PenTool,
  Database, Trash2, History, Eye, EyeOff, Cpu, Layers, X,
  Volume2, VolumeX, Mic, MicOff, Image, Play, Square
} from 'lucide-react';
import { 
  retrieveMemories, addMemoryExchange, getMemoryLedger, clearMemoryLedger, MemoryExchange 
} from '../lib/ragMemory';

interface ChatMessage {
  id: string;
  role: 'user' | 'model';
  text: string;
  isSuggested?: boolean;
  image?: string;
  audio?: string;
}

interface CbtCompanionProps {
  onSuggestJournalEntry: (title: string, text: string) => void;
  allowedJournals: { title: string; content: string; date: string }[] | null;
  theme?: 'light' | 'dark';
  user?: { name: string; email: string; picture: string } | null;
}

const REFLECTIVE_PROMPTS = [
  {
    id: 'deep-explore',
    title: 'Deep Reflection',
    icon: Sparkles,
    starter: 'I want to slow down and explore some thoughts that are on my mind...'
  },
  {
    id: 'stream',
    title: 'Stream of Consciousness',
    icon: PenTool,
    starter: 'Let\'s write down my raw, unfiltered thoughts and see where they lead...'
  },
  {
    id: 'gratitude',
    title: 'Focus on Wonder',
    icon: Sparkles,
    starter: 'I\'d like to reflect on some small positive moments or details from today...'
  }
];

export default function CbtCompanion({ onSuggestJournalEntry, allowedJournals, theme = 'light', user = null }: CbtCompanionProps) {
  const [messages, setMessages] = useState<ChatMessage[]>(() => {
    const saved = localStorage.getItem('sanctuary_companion_chat');
    if (saved) {
      try {
        return JSON.parse(saved);
      } catch (e) {
        // Fallback
      }
    }
    return [
      {
        id: 'welcome',
        role: 'model',
        text: 'Welcome to your private Sanctuary. I am your companion advisor. Here, your thoughts can unfold freely.\n\nEverything we discuss is entirely confidential, kept only on your device, and you choose which diaries I can reference to help guide our reflection.'
      }
    ];
  });

  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [activePrompt, setActivePrompt] = useState<string | null>(null);
  const chatEndRef = useRef<HTMLDivElement>(null);

  // RAG Memory State variables
  const [ledger, setLedger] = useState<MemoryExchange[]>(() => getMemoryLedger());
  const [showLedgerModal, setShowLedgerModal] = useState(false);
  const [lastRetrieved, setLastRetrieved] = useState<MemoryExchange[]>([]);

  // Voice Synthesis & Input States
  const [isTtsEnabled, setIsTtsEnabled] = useState(() => {
    return localStorage.getItem('sanctuary_tts_enabled') === 'true';
  });
  const [isListening, setIsListening] = useState(false);
  const recognitionRef = useRef<any>(null);

  // Local state for media attachments before sending
  const [attachedImage, setAttachedImage] = useState<string | null>(null);
  const [attachedAudio, setAttachedAudio] = useState<string | null>(null);
  
  // Media recorder state
  const [mediaRecorder, setMediaRecorder] = useState<MediaRecorder | null>(null);
  const [isRecordingAudio, setIsRecordingAudio] = useState(false);
  const [recordingSeconds, setRecordingSeconds] = useState(0);
  const audioChunksRef = useRef<Blob[]>([]);
  const recordingIntervalRef = useRef<any>(null);

  useEffect(() => {
    return () => {
      if (recordingIntervalRef.current) {
        clearInterval(recordingIntervalRef.current);
      }
    };
  }, []);

  const fileToDataUrl = (fileOrBlob: File | Blob): Promise<string> => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = reject;
      reader.readAsDataURL(fileOrBlob);
    });
  };

  const handleImageSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    
    const reader = new FileReader();
    reader.onload = () => {
      setAttachedImage(reader.result as string);
    };
    reader.onerror = (err) => {
      console.error("Error reading image file:", err);
    };
    reader.readAsDataURL(file);
  };

  const startAudioRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      audioChunksRef.current = [];
      
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) {
          audioChunksRef.current.push(e.data);
        }
      };
      
      recorder.onstop = async () => {
        const blob = new Blob(audioChunksRef.current, { type: 'audio/webm' });
        const dataUrl = await fileToDataUrl(blob);
        setAttachedAudio(dataUrl);
        // Stop all tracks to release mic
        stream.getTracks().forEach(track => track.stop());
      };
      
      recorder.start(200); // chunk every 200ms
      setMediaRecorder(recorder);
      setIsRecordingAudio(true);
      setRecordingSeconds(0);
      
      recordingIntervalRef.current = setInterval(() => {
        setRecordingSeconds(prev => prev + 1);
      }, 1000);
    } catch (err) {
      console.error("Failed to access microphone for recording:", err);
      alert("Microphone permission is required to record real voice entries.");
    }
  };

  const stopAudioRecording = () => {
    if (mediaRecorder && isRecordingAudio) {
      mediaRecorder.stop();
      setIsRecordingAudio(false);
      if (recordingIntervalRef.current) {
        clearInterval(recordingIntervalRef.current);
      }
    }
  };

  const cancelAudioRecording = () => {
    if (mediaRecorder) {
      mediaRecorder.onstop = () => {
        audioChunksRef.current = [];
      };
      mediaRecorder.stop();
      setIsRecordingAudio(false);
      if (recordingIntervalRef.current) {
        clearInterval(recordingIntervalRef.current);
      }
      setAttachedAudio(null);
    }
  };

  // Initialize Speech Recognition
  useEffect(() => {
    const SpeechRecognition = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (SpeechRecognition) {
      const rec = new SpeechRecognition();
      rec.continuous = false;
      rec.interimResults = false;
      rec.lang = 'en-US';

      rec.onstart = () => {
        setIsListening(true);
      };

      rec.onresult = (event: any) => {
        const transcript = event.results[0][0].transcript;
        if (transcript) {
          setInput(prev => prev ? prev + ' ' + transcript : transcript);
        }
      };

      rec.onerror = (err: any) => {
        console.error("Speech recognition error:", err);
        setIsListening(false);
      };

      rec.onend = () => {
        setIsListening(false);
      };

      recognitionRef.current = rec;
    }
  }, []);

  const toggleListening = () => {
    if (!recognitionRef.current) {
      alert("Speech recognition is not fully supported in this system/browser container. Standard mobile webviews natively translate this voice stream fully offline.");
      return;
    }

    if (isListening) {
      recognitionRef.current.stop();
    } else {
      try {
        recognitionRef.current.start();
      } catch (e) {
        console.error(e);
      }
    }
  };

  const speakText = (text: string) => {
    try {
      // Cancel any ongoing speech
      window.speechSynthesis.cancel();
      
      // Clean up markdown markers or code blocks for clean pronunciation
      const cleanText = text
        .replace(/`{1,3}[\s\S]*?`{1,3}/g, '') // remove code blocks
        .replace(/[*#_~]/g, '') // remove markdown indicators
        .trim();

      const utterance = new SpeechSynthesisUtterance(cleanText);
      utterance.rate = 1.05; // slightly faster and natural
      utterance.pitch = 1.05;
      window.speechSynthesis.speak(utterance);
    } catch (e) {
      console.error("Speech synthesis failed:", e);
    }
  };

  // Toggle TTS & Save Preference
  const handleToggleTts = () => {
    const newState = !isTtsEnabled;
    setIsTtsEnabled(newState);
    localStorage.setItem('sanctuary_tts_enabled', String(newState));
    if (!newState) {
      window.speechSynthesis.cancel();
    }
  };

  useEffect(() => {
    localStorage.setItem('sanctuary_companion_chat', JSON.stringify(messages));
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  const handleSendMessage = async (textToSend: string) => {
    if ((!textToSend.trim() && !attachedImage && !attachedAudio) || isLoading) return;

    // RAG Retrieval: Query local memory ledger for relevant context (use textToSend or fallback description)
    const queryForRag = textToSend.trim() || (attachedImage ? "Uploaded image reflection" : "Voice message reflection");
    const retrieved = retrieveMemories(queryForRag, 3);
    setLastRetrieved(retrieved);

    const userMsg: ChatMessage = {
      id: Date.now().toString(),
      role: 'user',
      text: textToSend,
      image: attachedImage || undefined,
      audio: attachedAudio || undefined
    };

    // Store references locally before resetting input states
    const sendImg = attachedImage;
    const sendAud = attachedAudio;

    setMessages(prev => [...prev, userMsg]);
    setInput('');
    setAttachedImage(null);
    setAttachedAudio(null);
    setIsLoading(true);

    try {
      // Send the request to our full-stack /api/chat endpoint with retrieved memories for RAG
      const response = await fetch('/api/chat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          message: textToSend,
          image: sendImg,
          audio: sendAud,
          history: messages.slice(-10), // Send last 10 messages for context
          allowedJournals: allowedJournals, // Pass only the journal entries unlocked & shared by user
          user: user, // Pass authenticated user info
          retrievedMemories: retrieved // Pass the RAG memories
        })
      });

      if (!response.ok) {
        const errData = await response.json().catch(() => ({}));
        throw new Error(errData.error || `Server returned error status ${response.status}`);
      }

      const data = await response.json();
      const responseText = data.response || "I hear you. Let's keep exploring that.";
      
      const companionMsg: ChatMessage = {
        id: (Date.now() + 1).toString(),
        role: 'model',
        text: responseText
      };

      setMessages(prev => [...prev, companionMsg]);

      // Speak response aloud if TTS is enabled
      if (isTtsEnabled) {
        speakText(responseText);
      }

      // RAG Storage: Automatically save the exchange as long-term memory
      const updatedLedger = addMemoryExchange(textToSend || "[Visual/Audio reflection]", responseText);
      setLedger(updatedLedger);
    } catch (err: any) {
      console.error(err);
      const errMsg: ChatMessage = {
        id: (Date.now() + 1).toString(),
        role: 'model',
        text: `Companion service currently unavailable: ${err.message || "Please verify your Gemini API Key in Settings > Secrets."}`
      };
      setMessages(prev => [...prev, errMsg]);
    } finally {
      setIsLoading(false);
    }
  };

  const handleClearHistory = () => {
    if (confirm("Are you sure you want to clear your chat history? This cannot be undone.")) {
      const initial: ChatMessage[] = [
        {
          id: 'welcome',
          role: 'model',
          text: 'Welcome to your private Sanctuary. I am your companion advisor. Here, your thoughts can unfold freely.\n\nEverything we discuss is entirely confidential, kept only on your device, and you choose which diaries I can reference to help guide our reflection.'
        }
      ];
      setMessages(initial);
      localStorage.setItem('sanctuary_companion_chat', JSON.stringify(initial));
    }
  };

  const handleExportToJournal = () => {
    // Find the latest user message or use the current input to create a journal prompt
    const lastUserMsg = [...messages].reverse().find(m => m.role === 'user');
    const title = lastUserMsg ? `Reflection: ${lastUserMsg.text.slice(0, 20)}...` : 'Sanctuary Reflection';
    const text = lastUserMsg 
      ? `My Reflection on: "${lastUserMsg.text}"\n\nNotes & companion insights:\n` 
      : 'My private thoughts today:\n';
    
    onSuggestJournalEntry(title, text);
  };

  // Theme bindings
  const containerClass = 
    theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' :
    'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]';

  const headerBgClass = 
    theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D]' :
    'bg-[#FAF8F5] border-[#EAE4D8]';

  const headerTitleClass = 
    theme === 'dark' ? 'text-[#A3B1BC] font-sans' :
    'text-[#536250] font-sans font-bold';

  const chatAreaBgClass = 
    theme === 'dark' ? 'bg-[#111315]/50' :
    'bg-[#FAF8F5]/30';

  const messageBoxModelClass = 
    theme === 'dark' ? 'bg-[#1C1E22] text-[#E2E6E9] border-[#24292D]' :
    'bg-white text-[#3D3830] border border-[#EAE4D8]';

  const messageBoxUserClass = 
    theme === 'dark' ? 'bg-[#A3B1BC] text-[#111315]' :
    'bg-[#536250] text-white';

  const inputAreaBgClass = 
    theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D]' :
    'bg-[#FAF8F5] border-[#EAE4D8]';

  const inputFieldClass = 
    theme === 'dark' ? 'bg-[#111315] text-[#E2E6E9] border-[#24292D] focus:ring-[#A3B1BC]' :
    'bg-white text-[#3D3830] border-[#EAE4D8] focus:ring-[#536250]';

  const quickStartBtnClass = (active: boolean) => 
    active 
      ? (theme === 'dark' ? 'bg-[#A3B1BC] text-[#111315] border-[#8E9AA6] shadow-xs' : 'bg-[#536250] text-white border-[#445242] shadow-xs')
      : (theme === 'dark' ? 'bg-[#111315] hover:bg-[#1A1D20] text-[#878F96] border-[#24292D]' : 'bg-white hover:bg-[#FAF8F5] border-[#EAE4D8] text-[#786E63]');

  const sendBtnClass = 
    theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' :
    'bg-[#536250] hover:bg-[#445242] text-white';

  return (
    <div className={`flex flex-col h-full rounded-2xl overflow-hidden shadow-sm border transition-all duration-300 ${containerClass}`}>
      
      {/* CHAT HEADER */}
      <div className={`px-5 py-3.5 border-b flex items-center justify-between transition-colors duration-300 ${headerBgClass}`}>
        <div className="flex items-center gap-2.5">
          <div className="w-2.5 h-2.5 rounded-full bg-emerald-600 animate-pulse" />
          <div>
            <h3 className={`text-xs font-bold uppercase tracking-wider transition-colors duration-300 ${headerTitleClass}`}>
              Sanctuary Advisor
            </h3>
            <p className="text-[10px] text-stone-500 font-medium">
              Private generative conversation partner
            </p>
          </div>
        </div>
        <button 
          onClick={handleClearHistory}
          className="text-stone-400 hover:text-red-500 p-1.5 rounded-xl transition-colors hover:bg-stone-100/20"
          title="Clear Conversation History"
        >
          <RefreshCw className="w-3.5 h-3.5" />
        </button>
      </div>

      {/* CHAT DISPLAY */}
      <div className={`flex-1 overflow-y-auto p-5 space-y-4 transition-colors duration-300 ${chatAreaBgClass}`}>
        
        {/* Linked Diary contextual banner */}
        {allowedJournals && allowedJournals.length > 0 && (
          <motion.div 
            initial={{ opacity: 0, y: -5 }}
            animate={{ opacity: 1, y: 0 }}
            className={`px-4 py-2 rounded-xl text-[10px] flex items-center gap-2 border ${
              theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#A3B1BC]' : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#536250]'
            }`}
          >
            <Brain className="w-3.5 h-3.5 text-emerald-600 shrink-0 animate-pulse" />
            <span className="font-semibold">
              Advising Context Active: referencing {allowedJournals.length} unlocked {allowedJournals.length === 1 ? 'diary' : 'diaries'}
            </span>
          </motion.div>
        )}

        {messages.map((m) => (
          <div 
            key={m.id} 
            className={`flex gap-3 max-w-[85%] ${m.role === 'user' ? 'ml-auto flex-row-reverse' : 'mr-auto'}`}
          >
            {/* Avatar */}
            <div className={`w-7 h-7 rounded-lg flex items-center justify-center shrink-0 border overflow-hidden ${
              m.role === 'user' 
                ? (theme === 'dark' ? 'bg-[#24292D] border-[#24292D] text-stone-300' : 'bg-white border-[#EAE4D8] text-[#3D3830]') 
                : (theme === 'dark' ? 'bg-[#24292D] border-[#24292D] text-[#A3B1BC]' : 'bg-white border-[#EAE4D8] text-[#536250]')
            }`}>
              {m.role === 'user' ? (
                user?.picture ? (
                  <img src={user.picture} alt={user.name} className="w-full h-full object-cover animate-fade-in" referrerPolicy="no-referrer" />
                ) : (
                  <User className="w-3.5 h-3.5" />
                )
              ) : (
                <Brain className="w-3.5 h-3.5" />
              )}
            </div>

            {/* Message Body */}
            <div className={`p-3.5 rounded-xl text-xs leading-relaxed shadow-2xs flex flex-col gap-2.5 ${
              m.role === 'user'
                ? `${messageBoxUserClass} rounded-tr-none`
                : `${messageBoxModelClass} rounded-tl-none`
            }`}>
              {m.image && (
                <div className="rounded-lg overflow-hidden max-w-[200px] border border-stone-500/10">
                  <img src={m.image} alt="Attached reflection media" className="w-full h-auto object-contain" />
                </div>
              )}
              {m.audio && (
                <div className="flex items-center gap-2 bg-black/5 dark:bg-white/5 rounded-lg p-1.5 max-w-[220px]">
                  <audio src={m.audio} controls className="w-full h-7 text-[9px] accent-[#536250] dark:accent-[#A3B1BC]" />
                </div>
              )}
              {m.text && <p className="whitespace-pre-line">{m.text}</p>}
            </div>
          </div>
        ))}

        {isLoading && (
          <div className="flex gap-3 mr-auto max-w-[85%]">
            <div className={`w-7 h-7 rounded-lg flex items-center justify-center animate-pulse border ${
              theme === 'dark' ? 'bg-[#24292D] border-[#24292D]' : 'bg-white border-[#EAE4D8]'
            }`}>
              <Brain className={`w-3.5 h-3.5 ${theme === 'dark' ? 'text-[#A3B1BC]' : 'text-[#536250]'}`} />
            </div>
            <div className={`p-3.5 rounded-xl rounded-tl-none shadow-2xs flex items-center gap-1.5 ${messageBoxModelClass}`}>
              <div className={`w-1 h-1 rounded-full animate-bounce [animation-delay:-0.3s] ${theme === 'dark' ? 'bg-[#A3B1BC]' : 'bg-[#536250]'}`} />
              <div className={`w-1 h-1 rounded-full animate-bounce [animation-delay:-0.15s] ${theme === 'dark' ? 'bg-[#A3B1BC]' : 'bg-[#536250]'}`} />
              <div className={`w-1 h-1 rounded-full animate-bounce ${theme === 'dark' ? 'bg-[#A3B1BC]' : 'bg-[#536250]'}`} />
              <span className="text-[9px] text-stone-400 ml-1">Reflecting...</span>
            </div>
          </div>
        )}
        <div ref={chatEndRef} />
      </div>

      {/* CONTROLS & COMPOSER FOOTER */}
      <div className={`p-3 border-t flex flex-col gap-3 transition-colors duration-300 ${inputAreaBgClass}`}>
        
        {/* Guided prompt starters */}
        <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-none">
          {REFLECTIVE_PROMPTS.map((ex) => {
            const IconComp = ex.icon;
            const active = activePrompt === ex.id;
            return (
              <button
                key={ex.id}
                onClick={() => {
                  setActivePrompt(ex.id);
                  setInput(ex.starter);
                }}
                className={`py-1.5 px-3 rounded-lg text-left border transition-all flex items-center gap-1.5 shrink-0 text-[10px] font-semibold cursor-pointer ${quickStartBtnClass(active)}`}
              >
                <IconComp className="w-3 h-3 text-emerald-700" />
                <span>{ex.title}</span>
              </button>
            );
          })}
        </div>

        {/* RAG Memory Ledger Status */}
        <motion.div 
          initial={{ opacity: 0, scale: 0.98 }}
          animate={{ opacity: 1, scale: 1 }}
          className={`flex justify-between items-center p-2 rounded-xl border text-[10px] shadow-2xs ${
            theme === 'dark' ? 'bg-[#111315] border-[#24292D] text-stone-300' : 'bg-white border-[#EAE4D8] text-stone-700'
          }`}
        >
          <div className="flex items-center gap-2">
            <Database className={`w-3.5 h-3.5 ${theme === 'dark' ? 'text-[#A3B1BC]' : 'text-[#536250]'} animate-pulse`} />
            <div className="flex flex-col">
              <span className="font-semibold uppercase tracking-wider text-[8px] text-stone-400">Autonomous RAG Memory Ledger</span>
              <span className="text-[10px] font-medium">
                {ledger.length === 0 
                  ? "Memory Vault Empty (saving conversations automatically)" 
                  : `${ledger.length} historic exchange${ledger.length === 1 ? '' : 's'} indexed as local knowledge base`}
              </span>
            </div>
          </div>
          <button
            onClick={() => setShowLedgerModal(true)}
            className={`text-[8px] px-2.5 py-1 rounded-lg font-bold uppercase tracking-wider transition-colors cursor-pointer ${
              theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' : 'bg-[#536250] hover:bg-[#445242] text-white'
            }`}
          >
            Manage Memory
          </button>
        </motion.div>

        {/* Display last retrieved details if applicable to show active RAG feedback */}
        {lastRetrieved.length > 0 && (
          <motion.div 
            initial={{ opacity: 0, y: 2 }}
            animate={{ opacity: 1, y: 0 }}
            className={`px-3 py-1.5 rounded-lg border flex items-center justify-between text-[9px] ${
              theme === 'dark' ? 'bg-[#1C1E22]/60 border-[#24292D] text-[#A3B1BC]' : 'bg-[#FAF8F5]/80 border-[#EAE4D8] text-[#536250]'
            }`}
          >
            <div className="flex items-center gap-1.5">
              <Cpu className="w-3 h-3 text-emerald-500 animate-pulse" />
              <span><b>RAG Active:</b> Injected {lastRetrieved.length} relevant historic memory blocks into LLM context</span>
            </div>
            <span className="text-[8px] font-mono uppercase tracking-widest text-stone-400">Retrieval Complete</span>
          </motion.div>
        )}

        {/* Multimodal Previews and Recording Status */}
        {(attachedImage || attachedAudio || isRecordingAudio) && (
          <div className={`p-2.5 rounded-xl border flex flex-col gap-2 ${
            theme === 'dark' ? 'bg-[#111315]/90 border-[#24292D]' : 'bg-[#FAF8F5] border-[#EAE4D8]'
          }`}>
            {isRecordingAudio ? (
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className="w-2 h-2 bg-red-500 rounded-full animate-ping" />
                  <span className="text-[10px] font-bold uppercase tracking-wider text-red-500 ml-1 animate-pulse">Voice Recording Active: {recordingSeconds}s</span>
                </div>
                <div className="flex items-center gap-1.5">
                  <button
                    onClick={stopAudioRecording}
                    className="p-1 px-2.5 text-[9px] font-bold uppercase rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white cursor-pointer"
                  >
                    Use
                  </button>
                  <button
                    onClick={cancelAudioRecording}
                    className="p-1 px-2.5 text-[9px] font-bold uppercase rounded-lg bg-stone-500/10 text-stone-400 hover:text-red-500 hover:bg-red-500/10 cursor-pointer"
                  >
                    Discard
                  </button>
                </div>
              </div>
            ) : (
              <div className="flex flex-wrap gap-3">
                {attachedImage && (
                  <div className="relative group rounded-lg overflow-hidden border border-stone-500/15 max-w-[80px]">
                    <img src={attachedImage} alt="Selection preview" className="w-16 h-16 object-cover" />
                    <button
                      onClick={() => setAttachedImage(null)}
                      className="absolute top-0 right-0 p-1 bg-black/70 text-white rounded-bl-lg hover:text-red-400 cursor-pointer"
                    >
                      <X className="w-3 h-3" />
                    </button>
                  </div>
                )}
                {attachedAudio && (
                  <div className="flex items-center gap-2 bg-stone-500/10 p-2 rounded-xl text-[10px] max-w-[240px]">
                    <Volume2 className="w-4 h-4 text-emerald-600 animate-pulse" />
                    <audio src={attachedAudio} controls className="w-40 h-6 text-[8px]" />
                    <button
                      onClick={() => setAttachedAudio(null)}
                      className="p-1 rounded-lg hover:bg-red-500/10 hover:text-red-500 cursor-pointer"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        {/* Message Input Box */}
        <div className="flex gap-2 items-center">
          {/* Text-To-Speech Speaker toggle */}
          <button
            onClick={handleToggleTts}
            className={`p-2 rounded-xl transition-all cursor-pointer border ${
              isTtsEnabled 
                ? (theme === 'dark' ? 'bg-[#A3B1BC] border-[#A3B1BC] text-[#111315]' : 'bg-[#536250] border-[#536250] text-white') 
                : (theme === 'dark' ? 'bg-[#1C1E22] border-[#24292D] text-stone-400 hover:text-stone-200' : 'bg-[#FAF8F5] border-[#EAE4D8] text-stone-500 hover:text-stone-800')
            }`}
            title={isTtsEnabled ? "Mute Read Aloud" : "Unmute Read Aloud"}
          >
            {isTtsEnabled ? <Volume2 className="w-4 h-4" /> : <VolumeX className="w-4 h-4" />}
          </button>

          {/* Speech-To-Text Mic Input button */}
          <button
            onClick={toggleListening}
            className={`p-2 rounded-xl transition-all cursor-pointer border ${
              isListening 
                ? 'bg-red-500 border-red-500 text-white animate-pulse' 
                : (theme === 'dark' ? 'bg-[#1C1E22] border-[#24292D] text-stone-400 hover:text-stone-200' : 'bg-[#FAF8F5] border-[#EAE4D8] text-stone-500 hover:text-stone-800')
            }`}
            title={isListening ? "Listening (tap to stop)..." : "Dictate message"}
          >
            {isListening ? <Mic className="w-4 h-4" /> : <MicOff className="w-4 h-4" />}
          </button>

          {/* Raw Audio Voice Recorder button */}
          <button
            onClick={isRecordingAudio ? stopAudioRecording : startAudioRecording}
            className={`p-2 rounded-xl transition-all cursor-pointer border ${
              isRecordingAudio 
                ? 'bg-red-600 border-red-600 text-white animate-pulse' 
                : (theme === 'dark' ? 'bg-[#1C1E22] border-[#24292D] text-stone-400 hover:text-stone-200' : 'bg-[#FAF8F5] border-[#EAE4D8] text-stone-500 hover:text-stone-800')
            }`}
            title={isRecordingAudio ? "Stop Voice Recording" : "Record Voice Message"}
          >
            {isRecordingAudio ? <Square className="w-4 h-4 text-white" /> : <Mic className="w-4 h-4 text-emerald-600 dark:text-emerald-400" />}
          </button>

          {/* Image Upload Label & Input */}
          <label
            className={`p-2 rounded-xl transition-all cursor-pointer border flex items-center justify-center ${
              attachedImage 
                ? (theme === 'dark' ? 'bg-emerald-800/40 border-emerald-700 text-emerald-400' : 'bg-emerald-50 border-emerald-200 text-emerald-700') 
                : (theme === 'dark' ? 'bg-[#1C1E22] border-[#24292D] text-stone-400 hover:text-stone-200' : 'bg-[#FAF8F5] border-[#EAE4D8] text-stone-500 hover:text-stone-800')
            }`}
            title="Attach visual reflection (photo or drawing)"
          >
            <input 
              type="file" 
              accept="image/*" 
              onChange={handleImageSelect} 
              className="hidden" 
            />
            <Image className="w-4 h-4" />
          </label>

          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleSendMessage(input)}
            placeholder={isListening ? "Listening... speak clearly" : "Explore what's on your mind (all confidential & secure)..."}
            className={`flex-1 text-xs rounded-xl px-3 py-2 focus:outline-none focus:ring-1 border ${inputFieldClass}`}
          />
          <button
            onClick={() => handleSendMessage(input)}
            disabled={(!input.trim() && !attachedImage && !attachedAudio) || isLoading}
            className={`p-2 rounded-xl transition-all disabled:opacity-45 cursor-pointer ${sendBtnClass}`}
          >
            <Send className="w-3.5 h-3.5" />
          </button>
        </div>

      </div>

      {/* RAG MEMORY LEDGER MODAL */}
      <AnimatePresence>
        {showLedgerModal && (
          <>
            {/* Backdrop */}
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={() => setShowLedgerModal(false)}
              className="fixed inset-0 bg-black/60 z-50 backdrop-blur-[2px] flex items-center justify-center p-4"
            >
              {/* Modal Card */}
              <motion.div
                initial={{ scale: 0.95, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                exit={{ scale: 0.95, opacity: 0 }}
                onClick={(e) => e.stopPropagation()}
                className={`w-full max-w-lg h-[80vh] flex flex-col rounded-3xl p-6 border shadow-2xl ${
                  theme === 'dark' ? 'bg-[#1A1D20] border-[#24292D] text-[#E2E6E9]' : 'bg-[#FAF8F5] border-[#EAE4D8] text-[#3D3830]'
                }`}
              >
                {/* Header */}
                <div className="flex justify-between items-start border-b border-stone-500/10 pb-4 shrink-0">
                  <div className="flex items-center gap-2">
                    <Database className={`w-5 h-5 ${theme === 'dark' ? 'text-[#A3B1BC]' : 'text-[#536250]'}`} />
                    <div>
                      <h3 className="text-xs font-bold uppercase tracking-wider">AI Local Memory Ledger</h3>
                      <p className="text-[10px] text-stone-400 mt-0.5">Privacy-first local Retrieval-Augmented Generation (RAG)</p>
                    </div>
                  </div>
                  <button 
                    onClick={() => setShowLedgerModal(false)}
                    className="p-1.5 rounded-lg hover:bg-stone-500/15 transition-colors cursor-pointer"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>

                {/* Educational Banner */}
                <div className={`my-4 p-3.5 rounded-xl border text-[10px] leading-relaxed shrink-0 ${
                  theme === 'dark' ? 'bg-[#111315]/80 border-[#24292D] text-stone-300' : 'bg-white border-[#EAE4D8] text-stone-600'
                }`}>
                  <span className="font-semibold text-emerald-600 uppercase tracking-widest text-[8px] block mb-1">How it works</span>
                  Every user exchange is automatically indexed, keyword-extracted, and saved inside the secure local app sandbox (utilizing high-performance device storage securely bridged via Capacitor).
                  When you send a message, the system searches this local database, finds matching records, and injects them as LLM memories.
                  This forms a deep, persistent knowledge base without storing any conversation data on external servers.
                </div>

                {/* Main Content Area */}
                <div className="flex-1 overflow-y-auto space-y-3 pr-1">
                  {ledger.length === 0 ? (
                    <div className="h-full flex flex-col items-center justify-center text-center p-8 space-y-2">
                      <History className="w-8 h-8 text-stone-400 stroke-[1.5] animate-pulse" />
                      <h4 className="text-[11px] font-bold uppercase tracking-wider text-stone-400">Empty Memory Ledger</h4>
                      <p className="text-[10px] text-stone-500 max-w-[240px]">Start conversing with the companion advisor. Memories will automatically populate and index here.</p>
                    </div>
                  ) : (
                    ledger.map((mem) => (
                      <div 
                        key={mem.id}
                        className={`p-3.5 rounded-xl border flex flex-col gap-2 relative group transition-all duration-200 ${
                          theme === 'dark' ? 'bg-[#111315] border-[#24292D]' : 'bg-white border-[#EAE4D8]'
                        }`}
                      >
                        {/* Timestamp & Individual Delete */}
                        <div className="flex justify-between items-center text-[8px] font-mono uppercase text-stone-400">
                          <span className="font-semibold tracking-wider">{mem.timestamp}</span>
                          <button
                            onClick={() => {
                              const updated = ledger.filter(item => item.id !== mem.id);
                              localStorage.setItem('sanctuary_rag_memory', JSON.stringify(updated));
                              setLedger(updated);
                            }}
                            className="p-1 rounded-md text-stone-400 hover:text-red-500 hover:bg-red-500/10 transition-all cursor-pointer opacity-80 group-hover:opacity-100"
                            title="Instruct AI to forget this exchange"
                          >
                            <Trash2 className="w-3 h-3" />
                          </button>
                        </div>

                        {/* Dialogue exchange */}
                        <div className="space-y-1.5 text-[10px] leading-relaxed">
                          <div>
                            <span className="font-bold text-emerald-600 block text-[8px] uppercase tracking-wider">User Input</span>
                            <p className="italic text-stone-400">"{mem.userQuery}"</p>
                          </div>
                          <div>
                            <span className="font-bold text-stone-400 block text-[8px] uppercase tracking-wider">Advisor Memory response</span>
                            <p className={theme === 'dark' ? 'text-stone-300' : 'text-stone-700'}>{mem.modelResponse}</p>
                          </div>
                        </div>

                        {/* Keyword pills */}
                        {mem.keywords.length > 0 && (
                          <div className="flex flex-wrap gap-1 mt-1 pt-2 border-t border-stone-500/5">
                            <span className="text-[7px] uppercase tracking-widest text-stone-500 mr-1 flex items-center font-bold">Index Terms:</span>
                            {mem.keywords.slice(0, 8).map((kw, idx) => (
                              <span 
                                key={idx} 
                                className={`text-[8px] px-1.5 py-0.5 rounded font-mono ${
                                  theme === 'dark' ? 'bg-[#1C1E22] text-[#A3B1BC]' : 'bg-stone-50 text-[#536250] border border-stone-100'
                                }`}
                              >
                                {kw}
                              </span>
                            ))}
                          </div>
                        )}
                      </div>
                    ))
                  )}
                </div>

                {/* Footer Controls */}
                {ledger.length > 0 && (
                  <div className="pt-4 mt-4 border-t border-stone-500/10 flex justify-between gap-3 shrink-0">
                    <button
                      onClick={() => {
                        if (confirm("Are you sure you want to delete all indexing memories? This will completely wipe the companion's RAG knowledge base.")) {
                          clearMemoryLedger();
                          setLedger([]);
                          setLastRetrieved([]);
                          setShowLedgerModal(false);
                        }
                      }}
                      className="px-3 py-2 rounded-xl text-[9px] font-bold uppercase tracking-wider border border-red-500/20 hover:bg-red-500/10 text-red-400 transition-all cursor-pointer flex items-center gap-1"
                    >
                      <Trash2 className="w-3 h-3" />
                      <span>Purge All Memory</span>
                    </button>
                    <button
                      onClick={() => setShowLedgerModal(false)}
                      className={`px-4 py-2 rounded-xl text-[9px] font-bold uppercase tracking-wider cursor-pointer shadow-xs transition-all ${
                        theme === 'dark' ? 'bg-[#A3B1BC] hover:bg-[#8E9AA6] text-[#111315]' : 'bg-[#536250] hover:bg-[#445242] text-white'
                      }`}
                    >
                      Done Viewing
                    </button>
                  </div>
                )}
              </motion.div>
            </motion.div>
          </>
        )}
      </AnimatePresence>

    </div>
  );
}
