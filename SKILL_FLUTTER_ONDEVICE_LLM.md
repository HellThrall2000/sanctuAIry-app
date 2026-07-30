# FLUTTER LOCAL LLM INTEGRATION SKILL (LiteRT-LM)

## 1. Core Objective
Master the implementation of **fully offline, on-device AI** in Flutter using Google's `LiteRT-LM` (formerly TensorFlow Lite LLM) runtime. This capability allows apps to run SLMs (Small Language Models) like Gemma 2, Qwen, and Phi without internet access.

## 2. Critical Resources & Documentation
The agent must prioritize these specific sources for ground-truth syntax and architectural patterns:

*   **Official Engine Source (C++/JNI)**: [Google AI Edge LiteRT-LM Repository](https://github.com)
    *   *Focus:* Understanding the native `LoRA` adapter support and GPU delegation flags.
*   **Primary Dart Package**: [flutter_litert_lm on Pub.dev](https://pub.dev)
    *   *Focus:* `LiteLmEngine.create` and `conversation.sendMessageStream` methods.
*   **Dart Package Source & Example**: [flutter_litert_lm Source Code Example](https://github.com/songhieu/flutter_litert_lm)
    *   *Focus:* Telemetry calculation (tokens-per-second) and production model-picker layouts.
*   **Engine Config Reference**: [litertlm Example Package](https://pub.dev/packages/litertlm/example)
    *   *Focus:* Structuring initialization maps, memory boundaries, and default token limitations.
*   **Official Google Edge Guide**: [Google AI Edge Flutter Integration Docs](https://developers.google.com/edge/litert-lm/flutter)
    *   *Focus:* Official hardware compatibility matrices and step-by-step native platform setup.
*   **Architectural Blueprint**: [AppsOnAir Flutter AI Agent Development Guide](https://www.appsonair.com/blogs/how-to-build-ai-agents-with-the-flutter-ai-toolkit)
    *   *Focus:* Creating clean UI abstractions and handling state logic for streaming responses.

## 3. Implementation Blueprint

### Phase A: Model Management (The "Heavy Lift")
Mobile LLMs are 1GB+. **Never** bundle them in `assets/`.
*   **Pattern**: Implement a "First Run" downloader.
*   **Action**: Use `dio` to download the `.litert` file to `getApplicationDocumentsDirectory()`.
*   **Validation**: Verify file hash (SHA-256) before initializing the engine to prevent crashes from corrupted downloads.

### Phase B: The Engine Isolate
Running LLM inference on the main thread will freeze the Flutter UI.
*   **Pattern**: Isolate/Worker encapsulation.
*   **Action**: Spawn a dedicated `Isolate` for the `LiteLmEngine`. Pass prompt strings *in* and stream token strings *out* via `ReceivePort` / `StreamController`.

### Phase C: Memory Hygiene
Native C++ memory leaks are fatal on mobile.
*   **Rule**: The `dispose()` method is mandatory.
*   **Snippet Logic**:
    ```dart
    // MUST call in this order in the generic dispose() override
    await _conversation?.dispose(); // Kill context window first
    await _engine?.dispose();       // Kill graph runner second
    ```

## 4. Code Generation Rules for Agents
When asking this agent to write code, enforce these constraints:
1.  **Hardware Acceleration**: Always set `LiteLmBackend.gpu` as the default, but wrap it in a `try-catch` to fallback to `LiteLmBackend.cpu` for older devices.
2.  **Prompt Templating**: Do not send raw user strings. Wrap them in the specific chat template required by the model (e.g., `<start_of_turn>user\n{prompt}<end_of_turn>model\n` for Gemma).
3.  **Streaming**: Always implement `StreamBuilder` for UI responses. Waiting for the full response feels "broken" to users due to on-device latency.

## 5. Troubleshooting "Hallucinations"
If the local model generates gibberish:
*   **Check**: Is the `.litert` file version compatible with the `flutter_litert_lm` package version? (e.g., v2 vs v3 headers).
*   **Fix**: Lower the `temperature` parameter to `0.2` for strictly factual tasks.
