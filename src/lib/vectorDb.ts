import { JournalEntry, SearchMatch } from "../types";

// Common English stopwords to filter out for meaningful semantic search vectors
const STOPWORDS = new Set([
  "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours", 
  "yourself", "yourselves", "he", "him", "his", "himself", "she", "her", "hers", 
  "herself", "it", "its", "itself", "they", "them", "their", "theirs", "themselves", 
  "what", "which", "who", "whom", "this", "that", "these", "those", "am", "is", "are", 
  "was", "were", "be", "been", "being", "have", "has", "had", "having", "do", "does", 
  "did", "doing", "a", "an", "the", "and", "but", "if", "or", "because", "as", "until", 
  "while", "of", "at", "by", "for", "with", "about", "against", "between", "into", 
  "through", "during", "before", "after", "above", "below", "to", "from", "up", "down", 
  "in", "out", "on", "off", "over", "under", "again", "further", "then", "once", "here", 
  "there", "when", "where", "why", "how", "all", "any", "both", "each", "few", "more", 
  "most", "other", "some", "such", "no", "nor", "not", "only", "own", "same", "so", 
  "than", "too", "very", "s", "t", "can", "will", "just", "don", "should", "now"
]);

// Helper to tokenize and stem/clean words
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, " ")
    .split(/\s+/)
    .filter((word) => word.length > 2 && !STOPWORDS.has(word));
}

/**
 * Perform a secure, entirely client-side TF-IDF vector similarity search
 * over a list of decrypted journal entries.
 */
export function secureLocalSemanticSearch(
  entries: JournalEntry[],
  query: string
): SearchMatch[] {
  if (!query.trim() || entries.length === 0) {
    return entries.map((entry) => ({ entry, score: 0, matchedTerms: [] }));
  }

  const queryTokens = tokenize(query);
  if (queryTokens.length === 0) {
    // If query has only stopwords, do a basic substring check
    const queryLower = query.toLowerCase();
    return entries.map((entry) => {
      const titleMatch = entry.title.toLowerCase().includes(queryLower);
      const contentMatch = entry.content.toLowerCase().includes(queryLower);
      const score = titleMatch ? 0.8 : contentMatch ? 0.5 : 0;
      return { entry, score, matchedTerms: titleMatch || contentMatch ? [query.trim()] : [] };
    });
  }

  // 1. Build Document Corpus Vocabulary
  const docTokensList = entries.map((e) => tokenize(e.title + " " + e.content));
  const vocabulary = new Set<string>();
  docTokensList.forEach((tokens) => tokens.forEach((token) => vocabulary.add(token)));
  queryTokens.forEach((token) => vocabulary.add(token));

  const vocabArray = Array.from(vocabulary);
  const vocabIndex: Record<string, number> = {};
  vocabArray.forEach((term, index) => {
    vocabIndex[term] = index;
  });

  const N = entries.length;

  // 2. Compute Inverse Document Frequency (IDF) for each vocabulary term
  const idf: Record<string, number> = {};
  vocabArray.forEach((term) => {
    let docCountWithTerm = 0;
    docTokensList.forEach((tokens) => {
      if (tokens.includes(term)) docCountWithTerm++;
    });
    // Add 1 to avoid division by zero
    idf[term] = Math.log(1 + (N / (1 + docCountWithTerm)));
  });

  // 3. Helper to build TF-IDF weight vector for a list of tokens
  const buildTfIdfVector = (tokens: string[]): number[] => {
    const tf: Record<string, number> = {};
    tokens.forEach((t) => {
      tf[t] = (tf[t] || 0) + 1;
    });

    const vector = new Array(vocabArray.length).fill(0);
    tokens.forEach((t) => {
      const idx = vocabIndex[t];
      if (idx !== undefined) {
        // TF-IDF weights
        vector[idx] = (tf[t] / tokens.length) * (idf[t] || 1);
      }
    });
    return vector;
  };

  // 4. Compute vector for the query
  const queryVector = buildTfIdfVector(queryTokens);

  // 5. Compute cosine similarity for each entry
  const results: SearchMatch[] = entries.map((entry, index) => {
    const docTokens = docTokensList[index];
    const docVector = buildTfIdfVector(docTokens);

    // Cosine Similarity Formula: dotProduct(A, B) / (norm(A) * norm(B))
    let dotProduct = 0;
    let normA = 0;
    let normB = 0;

    for (let i = 0; i < vocabArray.length; i++) {
      dotProduct += queryVector[i] * docVector[i];
      normA += queryVector[i] * queryVector[i];
      normB += docVector[i] * docVector[i];
    }

    const normProduct = Math.sqrt(normA) * Math.sqrt(normB);
    const cosineScore = normProduct === 0 ? 0 : dotProduct / normProduct;

    // Check which search terms specifically matched
    const matchedTerms = queryTokens.filter((token) => docTokens.includes(token));

    // Boost score slightly if the term is found in the title
    const titleTokens = tokenize(entry.title);
    const titleHasMatch = queryTokens.some((token) => titleTokens.includes(token));
    const finalScore = titleHasMatch ? Math.min(1.0, cosineScore * 1.3) : cosineScore;

    return {
      entry,
      score: finalScore,
      matchedTerms,
    };
  });

  // Sort by highest similarity score first, then by date descending
  return results.sort((a, b) => {
    if (b.score !== a.score) {
      return b.score - a.score;
    }
    return new Date(b.entry.date).getTime() - new Date(a.entry.date).getTime();
  });
}
