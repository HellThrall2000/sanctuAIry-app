import 'package:flutter/material.dart';
import 'dart:async';
import '../models/journal_entry.dart';
import '../services/litert_service.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({required this.text, required this.isUser, required this.timestamp});
}

class ChatScreen extends StatefulWidget {
  final List<JournalEntry> allowedJournals;

  const ChatScreen({Key? key, required this.allowedJournals}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final LiteRtService _liteRtService = LiteRtService();
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isGenerating = false;
  bool _isModelLoaded = false;
  String _modelLoadError = "";
  String? _detectedModelPath;

  @override
  void initState() {
    super.initState();
    _checkAndInitLocalModel();
    
    // Add welcome greeting
    _messages.add(ChatMessage(
      text: "Welcome to your personal Sanctuary companion. I am an on-device, fully-offline intelligence. I have zero access to the cloud, meaning our conversation never leaves this mobile device.\n\nHow can I support your reflections or mindfulness today?",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> _checkAndInitLocalModel() async {
    final path = await _liteRtService.findLocalModelFile();
    if (path != null) {
      setState(() {
        _detectedModelPath = path;
      });
      // Try to auto-initialize
      final success = await _liteRtService.initializeModel(path: path);
      setState(() {
        _isModelLoaded = success;
        if (!success) {
          _modelLoadError = "Found .litertlm file but failed to load the model engine.";
        }
      });
    } else {
      setState(() {
        _modelLoadError = "No local .litertlm file found in app documents. Place your fine-tuned model inside the app folder to enable edge-hosted companion chats.";
      });
    }
  }

  Future<void> _manualInitModel(String path) async {
    setState(() {
      _isGenerating = true;
      _modelLoadError = "";
    });
    final success = await _liteRtService.initializeModel(path: path);
    setState(() {
      _isModelLoaded = success;
      _isGenerating = false;
      if (!success) {
        _modelLoadError = "Failed to initialize .litertlm engine. Please verify format compatibility.";
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() async {
    final prompt = _textController.text.trim();
    if (prompt.isEmpty || _isGenerating) return;

    _textController.clear();
    setState(() {
      _messages.add(ChatMessage(text: prompt, isUser: true, timestamp: DateTime.now()));
      _isGenerating = true;
    });
    _scrollToBottom();

    if (!_isModelLoaded) {
      setState(() {
        _messages.add(ChatMessage(
          text: "Companion Offline: To chat, please make sure your fine-tuned LiteRT model (.litertlm) is loaded using the settings panel above.",
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isGenerating = false;
      });
      _scrollToBottom();
      return;
    }

    // Compile dynamic context from unlocked allowed journal entries
    String journalContext = "";
    if (widget.allowedJournals.isNotEmpty) {
      journalContext = "\n[Permitted Local Context: Here are the user's secure journals that they unlocked and approved for this conversation]\n";
      for (var entry in widget.allowedJournals) {
        journalContext += "Title: ${entry.title}\nDate: ${entry.date.split('T').first}\nContent: ${entry.content}\n\n";
      }
    }

    // Build complete conversation prompt with system directives
    String fullPrompt = """
You are Sanctuary, a beautiful private CBT writing companion.
Your primary directive is to provide a non-judgmental, deeply compassionate therapeutic space.
Here is the secure journal context that the user has unlocked and specifically permitted you to reference to help connect insights (if empty, proceed with standard support):
$journalContext

Please respond warmly, ask gentle reflective questions, and help them notice cognitive distortions (such as catastrophizing, all-or-nothing thinking, emotional reasoning). Keep responses focused, deeply human, and supportive. Use markdown formatting.

Conversation History:
""";

    // Add recent history for context. Prune if context is too large (max token limit handling logic via limiting history).
    // Let's limit to the last 4 messages to save tokens.
    final historyMessages = _messages.skip(_messages.length > 4 ? _messages.length - 4 : 0);
    for (var msg in historyMessages) {
      fullPrompt += "${msg.isUser ? 'User' : 'Companion'}: ${msg.text}\n";
    }
    fullPrompt += "Companion: ";

    // Initialize blank message slot for streaming output
    final streamingMessage = ChatMessage(text: "", isUser: false, timestamp: DateTime.now());
    setState(() {
      _messages.add(streamingMessage);
    });

    String fullResponseText = "";
    StreamSubscription<String>? subscription;

    subscription = _liteRtService.generateResponseStream(fullPrompt).listen(
      (chunk) {
        setState(() {
          fullResponseText += chunk;
          // Update the last message in place
          _messages[_messages.length - 1] = ChatMessage(
            text: fullResponseText,
            isUser: false,
            timestamp: streamingMessage.timestamp,
          );
        });
        _scrollToBottom();
      },
      onError: (err) {
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            text: "Failed during edge inference: $err",
            isUser: false,
            timestamp: streamingMessage.timestamp,
          );
          _isGenerating = false;
        });
        subscription?.cancel();
        _scrollToBottom();
      },
      onDone: () {
        setState(() {
          _isGenerating = false;
        });
        subscription?.cancel();
        _scrollToBottom();
      },
      cancelOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Strictly dark themed per specs
    const accentColor = Color(0xFF00E5FF);
    const inputBg = Color(0xFF0A0A0A);

    return Scaffold(
      backgroundColor: Colors.transparent, // Inherits deep black from main.dart
      body: Column(
        children: [
          // LiteRT Model Loader Banner
          if (!_isModelLoaded)
            _buildModelSetupBanner(accentColor),

          // Conversation Area
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg, accentColor);
              },
            ),
          ),

          // First token loading indicator
          if (_isGenerating && _messages.isNotEmpty && _messages.last.text.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: accentColor, strokeWidth: 2),
              ),
            ),

          // Typing Input Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: inputBg,
              border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: null,
                    enabled: !_isGenerating,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: "Write your thoughts...",
                      hintStyle: TextStyle(fontSize: 14, color: Color(0xFF555555)),
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(fontSize: 14, color: Color(0xFFE2E6E9)),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _isGenerating ? null : _sendMessage,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                    child: _isGenerating
                        ? const Icon(Icons.stop_rounded, color: Colors.black, size: 20)
                        : const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelSetupBanner(Color accentColor) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border.all(color: accentColor.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: accentColor, size: 16),
              const SizedBox(width: 6),
              Text(
                "EDGE INFERENCE SETUP (.litertlm)",
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1, color: accentColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _modelLoadError,
            style: const TextStyle(fontSize: 11, height: 1.4, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          if (_detectedModelPath != null)
            ElevatedButton(
              onPressed: () => _manualInitModel(_detectedModelPath!),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.black,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text("Initialize Detected Model", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            )
          else
            const Text(
              "How to load: Connect your phone to your computer, open Android/iOS file explorer, and drop your model file inside the app's 'Documents' directory named exactly 'model.litertlm' or '.bin'. Then reboot the app.",
              style: TextStyle(fontSize: 9, color: Colors.grey, height: 1.3),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, Color accentColor) {
    final textColor = const Color(0xFFE2E6E9);
    final align = msg.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    // Don't show an empty bubble when first token is loading
    if (!msg.isUser && msg.text.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: BoxDecoration(
              border: Border(
                left: !msg.isUser ? BorderSide(color: accentColor, width: 2) : BorderSide.none,
                right: msg.isUser ? BorderSide(color: accentColor, width: 2) : BorderSide.none,
              ),
              color: const Color(0xFF0A0A0A),
            ),
            child: Text(
              msg.text,
              style: TextStyle(fontSize: 14, height: 1.45, color: textColor),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            msg.isUser ? "You" : "Sanctuary On-Device Model",
            style: const TextStyle(fontSize: 9, color: Color(0xFF555555), fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
