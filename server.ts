import express from "express";
import path from "path";
import { createServer as createViteServer } from "vite";
import { GoogleGenAI } from "@google/genai";

async function startServer() {
  const app = express();
  const PORT = 3000;

  app.use(express.json({ limit: "20mb" }));
  app.use(express.urlencoded({ limit: "20mb", extended: true }));

  // API Route for chat companion
  app.post("/api/chat", async (req, res) => {
    try {
      const { message, image, audio, history, allowedJournals, user, retrievedMemories } = req.body;
      
      const apiKey = process.env.GEMINI_API_KEY;
      if (!apiKey) {
        return res.status(500).json({ 
          error: "GEMINI_API_KEY is not configured. Please check your Settings > Secrets panel." 
        });
      }

      const ai = new GoogleGenAI({
        apiKey,
        httpOptions: {
          headers: {
            'User-Agent': 'aistudio-build',
          }
        }
      });

      // Prepare context from shared journals
      let journalContext = "";
      if (allowedJournals && allowedJournals.length > 0) {
        journalContext = "Here are the private diary entries the user has explicitly shared with you as context for this conversation:\n";
        allowedJournals.forEach((j: any, idx: number) => {
          journalContext += `\n[Entry #${idx + 1} - Title: "${j.title}" - Date: ${j.date}]\nContent:\n${j.content}\n`;
        });
        journalContext += "\nUse these shared entries to personalize your advice and check-ins, but respect the user's boundaries.";
      }

      // Prepare context from retrieved memories (RAG)
      let memoryContext = "";
      if (retrievedMemories && retrievedMemories.length > 0) {
        memoryContext = "\n--- RETRIEVED LONG-TERM MEMORIES OF PAST CONVERSATIONS (RAG) ---\n";
        memoryContext += "These are relevant snippets from past discussions with this user. Use this background context to show deep continuity, active listening, and remember previous details they shared (such as aspirations, concerns, or things they like):\n";
        retrievedMemories.forEach((m: any, idx: number) => {
          memoryContext += `\n[Past Exchange #${idx + 1} - Date: ${m.timestamp}]\n`;
          memoryContext += `- User shared: "${m.userQuery}"\n`;
          memoryContext += `- You replied: "${m.modelResponse}"\n`;
        });
        memoryContext += "\nRefer back to these memories naturally where appropriate, demonstrating you remember them over time. Do not explicitly say 'According to my database memory'; make it sound human and empathetic.\n";
      }

      // Prepare the history for Google GenAI SDK.
      const contents: any[] = [];
      
      // Add history items (must be formatted as { role: 'user' | 'model', parts: [{ text: string }] })
      if (history && history.length > 0) {
        history.forEach((h: any) => {
          contents.push({
            role: h.role === 'user' ? 'user' : 'model',
            parts: [{ text: h.text || "" }]
          });
        });
      }

      // Add the final user message with multimodal parts support
      const finalParts: any[] = [{ text: message || "Reflecting on attached media:" }];

      if (image) {
        const match = image.match(/^data:([^;]+);base64,(.+)$/);
        if (match) {
          finalParts.push({
            inlineData: {
              mimeType: match[1],
              data: match[2]
            }
          });
        } else {
          finalParts.push({
            inlineData: {
              mimeType: "image/png",
              data: image
            }
          });
        }
      }

      if (audio) {
        const match = audio.match(/^data:([^;]+);base64,(.+)$/);
        if (match) {
          finalParts.push({
            inlineData: {
              mimeType: match[1],
              data: match[2]
            }
          });
        } else {
          finalParts.push({
            inlineData: {
              mimeType: "audio/webm",
              data: audio
            }
          });
        }
      }

      contents.push({
        role: 'user',
        parts: finalParts
      });

      let userContext = "";
      if (user && user.name) {
        userContext = `The user is logged in as "${user.name}" (${user.email}). Address them by their name naturally when appropriate (e.g. at the beginning or end of reflective responses) to make the sanctuary experience deeply personal and warm.\n`;
      }

      const systemInstruction = `You are "Sanctuary Advisor", a supportive, literary, private writing companion.
Your style: warm, authentic, calm, non-judgmental, creative, and comforting.
CRITICAL CONSTRAINT: Do NOT mention clinical, medical, or therapeutic jargon such as CBT, cognitive behavioral therapy, therapist, clinic, counselor, mental health, or diagnostics. This is a creative, reflective sanctuary. Keep the user comfortable and relaxed, never on guard.

You are equipped with advanced multimodal senses. If the user attaches an image (such as drawings, sketches, photos, or captures) or records a voice message, you can view and hear them perfectly. Comment thoughtfully on whatever visual themes or voice tone they share.
If the user shares personal writings, respond as an empathetic writing partner. Ask thoughtful, reflective questions about their thoughts and aspirations.

${userContext}
${journalContext}
${memoryContext}`;

      const response = await ai.models.generateContent({
        model: "gemini-3.5-flash",
        contents,
        config: {
          systemInstruction,
          temperature: 0.8,
        },
      });

      res.json({ response: response.text });
    } catch (error: any) {
      console.error("Gemini API Error:", error);
      res.status(500).json({ error: error.message || "An error occurred with the AI Companion." });
    }
  });

  // GOOGLE OAUTH AUTHORIZE URL ROUTE
  app.get('/api/auth/google/url', (req, res) => {
    const clientRedirectUri = req.query.redirect_uri as string;
    const clientId = process.env.GOOGLE_CLIENT_ID;

    if (!clientId) {
      return res.json({
        url: "",
        isDemo: true,
        message: "Google OAuth credentials are not configured yet."
      });
    }

    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: clientRedirectUri,
      response_type: 'code',
      scope: 'openid email profile',
      prompt: 'select_account',
      state: clientRedirectUri
    });

    const authUrl = `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
    res.json({ url: authUrl, isDemo: false });
  });

  // GOOGLE OAUTH CALLBACK ROUTE
  app.get(['/auth/callback', '/auth/callback/'], async (req, res) => {
    const { code, state } = req.query;
    const clientId = process.env.GOOGLE_CLIENT_ID;
    const clientSecret = process.env.GOOGLE_CLIENT_SECRET;

    if (!code) {
      return res.status(400).send("Authorization code is missing");
    }

    if (!clientId || !clientSecret) {
      return res.status(500).send("Google credentials are not configured");
    }

    try {
      // Exchange code for token
      const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          code: code as string,
          client_id: clientId,
          client_secret: clientSecret,
          redirect_uri: (state as string) || `https://${req.get('host')}/auth/callback`,
          grant_type: 'authorization_code'
        }).toString()
      });

      if (!tokenResponse.ok) {
        const errorText = await tokenResponse.text();
        throw new Error(`Token exchange failed: ${errorText}`);
      }

      const tokens = await tokenResponse.json();
      const accessToken = tokens.access_token;

      // Fetch user profile info
      const userResponse = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
        headers: {
          Authorization: `Bearer ${accessToken}`
        }
      });

      if (!userResponse.ok) {
        throw new Error("Failed to fetch user info");
      }

      const user = await userResponse.json();

      // Return a page that posts user info back to the client and closes popup
      res.send(`
        <html>
          <body style="background-color: #FAF8F5; margin: 0; padding: 0; display: flex; align-items: center; justify-content: center; height: 100vh;">
            <div style="text-align: center; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #3d3830; padding: 24px;">
              <h2 style="font-size: 18px; font-weight: 600; margin-bottom: 8px;">Sanctuary Verified</h2>
              <p style="font-size: 12px; color: #786e63; margin-bottom: 24px;">Establishing secure session connection...</p>
              <div style="width: 24px; height: 24px; border: 2px solid #EAE4D8; border-top-color: #536250; border-radius: 50%; animation: spin 1s linear infinite; margin: 0 auto;"></div>
            </div>
            <style>
              @keyframes spin { to { transform: rotate(360deg); } }
            </style>
            <script>
              const userData = {
                name: ${JSON.stringify(user.name)},
                email: ${JSON.stringify(user.email)},
                picture: ${JSON.stringify(user.picture || '')}
              };

              // Write to localStorage first (highly reliable on the exact same origin)
              try {
                localStorage.setItem('sanctuary_user', JSON.stringify(userData));
              } catch (e) {
                console.error("Failed to write to localStorage:", e);
              }

              // Try postMessage to window.opener
              if (window.opener) {
                try {
                  window.opener.postMessage({ 
                    type: 'OAUTH_AUTH_SUCCESS', 
                    user: userData
                  }, '*');
                } catch (e) {
                  console.error("postMessage failed:", e);
                }
              }

              // Close the popup window
              setTimeout(() => {
                window.close();
              }, 800);
            </script>
          </body>
        </html>
      `);
    } catch (err: any) {
      console.error("OAuth Exchange Error:", err);
      res.status(500).send(`Authentication error: ${err.message}`);
    }
  });

  // Serve static files / Vite dev middleware
  if (process.env.NODE_ENV !== "production") {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), 'dist');
    app.use(express.static(distPath));
    app.get('*', (req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  }

  app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server running on http://localhost:${PORT}`);
  });
}

startServer();
