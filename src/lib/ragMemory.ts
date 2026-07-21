/**
 * Lightweight, privacy-preserving client-side RAG (Retrieval-Augmented Generation) memory engine
 * Stores memories in local storage and retrieves relevant historic context for conversation continuity.
 */

export interface MemoryExchange {
  id: string;
  timestamp: string;
  userQuery: string;
  modelResponse: string;
  keywords: string[];
}

// Simple set of English stop words to filter out for keyword search
const STOP_WORDS = new Set([
  'i', 'me', 'my', 'myself', 'we', 'our', 'ours', 'ourselves', 'you', "you're", "you've", "you'll", "you'd",
  'your', 'yours', 'yourself', 'yourselves', 'he', 'him', 'his', 'himself', 'she', "she's", 'her', 'hers',
  'herself', 'it', "it's", 'its', 'itself', 'they', 'them', 'their', 'theirs', 'themselves', 'what', 'which',
  'who', 'whom', 'this', 'that', "that'll", 'these', 'those', 'am', 'is', 'are', 'was', 'were', 'be', 'been',
  'being', 'have', 'has', 'had', 'having', 'do', 'does', 'did', 'doing', 'a', 'an', 'the', 'and', 'but',
  'if', 'or', 'because', 'as', 'until', 'while', 'of', 'at', 'by', 'for', 'with', 'about', 'against',
  'between', 'into', 'through', 'during', 'before', 'after', 'above', 'below', 'to', 'from', 'up', 'down',
  'in', 'out', 'on', 'off', 'over', 'under', 'again', 'further', 'then', 'once', 'here', 'there', 'when',
  'where', 'why', 'how', 'all', 'any', 'both', 'each', 'few', 'more', 'most', 'other', 'some', 'such',
  'no', 'nor', 'not', 'only', 'own', 'same', 'so', 'than', 'too', 'very', 's', 't', 'can', 'will', 'just',
  'don', "don't", 'should', "should've", 'now', 'd', 'll', 'm', 'o', 're', 've', 'y', 'ain', 'aren',
  "aren't", 'couldn', "couldn't", 'didn', "didn't", 'doesn', "doesn't", 'hadn', "hadn't", 'hasn', "hasn't",
  'haven', "haven't", 'isn', "isn't", 'ma', 'mightn', "mightn't", 'mustn', "mustn't", 'needn', "needn't",
  'shan', "shan't", 'shouldn', "shouldn't", 'wasn', "wasn't", 'weren', "weren't", 'won', "won't", 'wouldn',
  "wouldn't"
]);

/**
 * Tokenize text into lowercase keywords, removing stop words and punctuation
 */
export function extractKeywords(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length > 2 && !STOP_WORDS.has(word));
}

/**
 * Retrieve all memory exchanges from local storage
 */
export function getMemoryLedger(): MemoryExchange[] {
  const saved = localStorage.getItem('sanctuary_rag_memory');
  if (!saved) return [];
  try {
    return JSON.parse(saved);
  } catch (e) {
    console.error("Failed to parse sanctuary_rag_memory:", e);
    return [];
  }
}

/**
 * Save a new user-model exchange to the memory ledger
 */
export function addMemoryExchange(userQuery: string, modelResponse: string): MemoryExchange[] {
  if (!userQuery.trim() || !modelResponse.trim()) return getMemoryLedger();

  const ledger = getMemoryLedger();
  const keywords = Array.from(new Set([
    ...extractKeywords(userQuery),
    ...extractKeywords(modelResponse)
  ]));

  const newExchange: MemoryExchange = {
    id: `mem_${Date.now()}`,
    timestamp: new Date().toLocaleString(),
    userQuery,
    modelResponse,
    keywords
  };

  // Prepend so latest memory can be easily found, or just push
  const updated = [newExchange, ...ledger];
  localStorage.setItem('sanctuary_rag_memory', JSON.stringify(updated));
  return updated;
}

/**
 * RAG Core: Query-based retrieval with keyword scoring
 * Returns the top N most relevant past conversation memories
 */
export function retrieveMemories(query: string, maxResults: number = 3): MemoryExchange[] {
  const ledger = getMemoryLedger();
  if (ledger.length === 0) return [];

  const queryKeywords = extractKeywords(query);
  if (queryKeywords.length === 0) {
    // If no unique keywords, return the latest exchanges as a temporal fallback
    return ledger.slice(0, maxResults);
  }

  // Score each exchange based on overlapping keywords
  const scored = ledger.map(exchange => {
    let score = 0;
    const exchangeKeywords = new Set(exchange.keywords);

    queryKeywords.forEach(kw => {
      if (exchangeKeywords.has(kw)) {
        score += 1; // Direct keyword overlap
      }
    });

    // Slight recency bias (newer memories with equal scores rank higher)
    const recencyBonus = 0.001 * (1 / (1 + (Date.now() - parseInt(exchange.id.replace('mem_', ''))) / (1000 * 60 * 60)));
    
    return {
      exchange,
      score: score + recencyBonus
    };
  });

  // Filter out zero-score items unless we have very few total memories
  const relevantExchanges = scored
    .filter(item => item.score > 0.01)
    .sort((a, b) => b.score - a.score)
    .map(item => item.exchange);

  if (relevantExchanges.length > 0) {
    return relevantExchanges.slice(0, maxResults);
  }

  // Fallback: if no matches, return most recent memories
  return ledger.slice(0, maxResults);
}

/**
 * Clear the entire memory ledger
 */
export function clearMemoryLedger(): void {
  localStorage.removeItem('sanctuary_rag_memory');
}
