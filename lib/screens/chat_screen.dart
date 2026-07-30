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

  @override
  void initState() {
    super.initState();
    
    // Add welcome greeting
    _messages.add(ChatMessage(
      text: "Welcome to your personal Sanctuary companion. I am an on-device, fully-offline intelligence. I have zero access to the cloud, meaning our conversation never leaves this mobile device.\n\nHow can I support your reflections or mindfulness today?",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  /// Persona plus any journals the user unlocked for this session.
  ///
  /// This is sent once, as a real system turn, when the conversation is opened.
  /// Journals unlocked later in the session are not picked up until the
  /// conversation is recreated.
  String _buildSystemInstruction() {
    final buffer = StringBuffer(
      "You are Sanctuary, a compassionate private CBT writing companion. "
      "Keep responses brief, supportive, and helpful.",
    );

    if (widget.allowedJournals.isNotEmpty) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln(
        "The user unlocked these private journal entries and approved them "
        "for this conversation:",
      );
      for (final entry in widget.allowedJournals) {
        buffer.writeln();
        buffer.writeln("Title: ${entry.title}");
        buffer.writeln("Date: ${entry.date.split('T').first}");
        buffer.writeln("Content: ${entry.content}");
      }
    }

    return buffer.toString();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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
    await Future.delayed(const Duration(milliseconds: 150));

    // Lazy load the model on first prompt
    if (!_liteRtService.isInitialized) {
      final statusMessageIndex = _messages.length;
      setState(() {
        _messages.add(ChatMessage(
          text: "⚡ Initializing local LiteRT Engine (mapping 2.5GB model file into memory, please wait a few seconds)...",
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
      await Future.delayed(const Duration(milliseconds: 150));

      final path = await _liteRtService.findLocalModelFile();
      if (path != null) {
        final error = await _liteRtService.initializeModel(
          path: path,
          systemInstruction: _buildSystemInstruction(),
        );
        if (error != null) {
          setState(() {
            _messages[statusMessageIndex] = ChatMessage(
              text: "Failed to initialize companion: $error",
              isUser: false,
              timestamp: DateTime.now(),
            );
            _isGenerating = false;
          });
          _scrollToBottom();
          return;
        } else {
          // Remove initialization status message once ready
          setState(() {
            _messages.removeAt(statusMessageIndex);
          });
        }
      } else {
        setState(() {
          _messages[statusMessageIndex] = ChatMessage(
            text: "Companion Offline: Could not find the model file on device.",
            isUser: false,
            timestamp: DateTime.now(),
          );
          _isGenerating = false;
        });
        _scrollToBottom();
        return;
      }
    }

    // The persona and journal context are supplied once as the conversation's
    // system instruction (see _buildSystemInstruction), and the runtime applies
    // the chat template stored in the model's own metadata. So the model gets
    // the user's plain text here — hand-writing turn tags would be tokenized as
    // literal text and corrupt the prompt.
    final fullPrompt = prompt;

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
