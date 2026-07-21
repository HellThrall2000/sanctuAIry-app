export interface ChatMessage {
  id: string;
  text: string;
  role: 'user' | 'model';
  timestamp: string;
  simulated?: boolean;
}

export type MoodType = 'calm' | 'peaceful' | 'neutral' | 'anxious' | 'sad' | 'overwhelmed';

export interface JournalEntry {
  id: string;
  date: string;
  title: string;
  content: string; // Will store encrypted hex payload if password is set, or plain text if not
  isEncrypted: boolean;
  mood: MoodType;
  tags: string[];
  allowAiAccess: boolean; // True if the user grants the CBT AI permission to read this entry for context
}

export interface SearchMatch {
  entry: JournalEntry;
  score: number; // 0 to 1 calculation
  matchedTerms: string[];
}

export interface SubscriptionState {
  isPremium: boolean;
  licenseKey: string;
  activatedAt?: string;
  transactionId?: string;
}
