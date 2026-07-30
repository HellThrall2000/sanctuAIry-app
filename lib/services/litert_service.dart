import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

/// Wraps the native LiteRT-LM engine (`liblitertlm_jni.so`) for Sanctuary.
///
/// CPU is the correct and intended backend for a `.litertlm` model — Google's
/// own Gemma 4 E2B build is a 2,583 MB file that peaks at ~1,733 MB RSS on an
/// Android CPU. The model currently shipped with Sanctuary is the same size
/// (2,549 MB) but peaks at 6,000-7,400 MB, so the app is killed with
/// `reason=3 (LOW_MEMORY)` before it emits a token. That ~4x gap is a defect in
/// how the model was converted, not something this class can work around; see
/// README "Known blocking issue" for the measurements and the conversion plan.
///
/// Load is exclusive and reentrancy-guarded — two concurrent engines would
/// double an already-marginal footprint.
class LiteRtService {
  static final LiteRtService _instance = LiteRtService._internal();
  factory LiteRtService() => _instance;
  LiteRtService._internal();

  LiteLmEngine? _engine;
  LiteLmConversation? _conversation;
  bool _isInitialized = false;
  String? _modelPath;
  LiteLmBackend? _activeBackend;
  Future<String?>? _pendingInit;

  bool get isInitialized => _isInitialized;
  String? get modelPath => _modelPath;

  /// Which backend the engine actually came up on — GPU or the CPU fallback.
  LiteLmBackend? get activeBackend => _activeBackend;

  /// Locates the default model path or searches the app documents directory for a .litertlm file
  Future<String?> findLocalModelFile() async {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final extFile = File('${extDir.path}/model.litertlm');
        if (await extFile.exists()) {
          print("Found local model file at: ${extFile.path} (Size: ${await extFile.length()} bytes)");
          return extFile.path;
        }
      }

      final directory = await getApplicationDocumentsDirectory();

      // Look for a .litertlm or .bin file inside the documents directory
      final entities = await directory.list().toList();
      for (var entity in entities) {
        if (entity is File &&
            (entity.path.endsWith('.litertlm') || entity.path.endsWith('.bin'))) {
          return entity.path;
        }
      }

      // Fallback: Check standard model path
      final defaultFile = File('${directory.path}/model.litertlm');
      if (await defaultFile.exists()) {
        return defaultFile.path;
      }

      // Fallback: Check SD Card locations
      final sdcardFile = File('/sdcard/Download/model.litertlm');
      if (await sdcardFile.exists()) {
        return sdcardFile.path;
      }

      final sdcardFile2 = File('/sdcard/model.litertlm');
      if (await sdcardFile2.exists()) {
        return sdcardFile2.path;
      }
    } catch (e) {
      print("Error locating local model file: $e");
    }
    return null;
  }

  Future<void> logToFile(String logMessage) async {
    try {
      final file = File('/sdcard/Download/sanctuary_crash_log.txt');
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString('[$timestamp] $logMessage\n', mode: FileMode.append);
    } catch (e) {
      print("Failed to write to crash log file: $e");
    }
  }

  /// Initialize the native LiteRT engine and open a conversation.
  ///
  /// [backend] defaults to CPU, which is what `.litertlm` models target. GPU is
  /// only worth trying once the model is re-converted with a GPU variant — the
  /// current container has none, and `LiteLmEngine.create` fails on it with
  /// `INTERNAL: ERROR: [llm_litert_compiled_model_executor.cc]`.
  ///
  /// [systemInstruction] is passed to the runtime as a real system turn. Do not
  /// hand-write turn tags into prompts — the runtime applies the chat template
  /// stored in the model's own metadata.
  Future<String?> initializeModel({
    required String path,
    String? systemInstruction,
    LiteLmBackend backend = LiteLmBackend.cpu,
    double temperature = 0.7,
    int topK = 40,
    double topP = 0.95,
  }) {
    // Loading twice concurrently would double a footprint that is already at
    // the edge of what the device can hold, so callers share one attempt.
    return _pendingInit ??= _initializeModel(
      path: path,
      systemInstruction: systemInstruction,
      backend: backend,
      temperature: temperature,
      topK: topK,
      topP: topP,
    ).whenComplete(() => _pendingInit = null);
  }

  Future<String?> _initializeModel({
    required String path,
    String? systemInstruction,
    required LiteLmBackend backend,
    required double temperature,
    required int topK,
    required double topP,
  }) async {
    await logToFile("Starting initializeModel with path: $path");
    try {
      // Acquire CPU WakeLock to forbid OS from suspending the process
      try {
        await const MethodChannel('sanctuary/wakelock').invokeMethod('acquireWakeLock');
      } catch (_) {}

      await _disposeEngine();

      final tempDir = await getTemporaryDirectory();
      await logToFile("Using tempDir: ${tempDir.path}");

      await logToFile("Calling LiteLmEngine.create on ${backend.name}...");
      _engine = await LiteLmEngine.create(LiteLmEngineConfig(
        modelPath: path,
        backend: backend,
        cacheDir: tempDir.path,
      ));
      await logToFile("Engine created on ${backend.name}. Creating conversation...");

      _conversation = await _engine!.createConversation(
        LiteLmConversationConfig(
          systemInstruction: systemInstruction,
          samplerConfig: LiteLmSamplerConfig(
            topK: topK,
            topP: topP,
            temperature: temperature,
          ),
        ),
      );

      await logToFile("Conversation ready on ${backend.name}.");
      _isInitialized = true;
      _modelPath = path;
      _activeBackend = backend;
      return null;
    } catch (e, stack) {
      final errLog = "Failed to initialize LiteRT model: $e\nStack: $stack";
      print(errLog);
      await logToFile(errLog);
      _isInitialized = false;
      return e.toString();
    } finally {
      try {
        await const MethodChannel('sanctuary/wakelock').invokeMethod('releaseWakeLock');
      } catch (_) {}
    }
  }

  /// Generates a single-shot response from the local LiteRT model.
  ///
  /// Pass the user's plain text — the runtime adds the turn tags.
  Future<String> generateResponse(String prompt) async {
    if (!_isInitialized || _conversation == null) {
      const errStr = "LiteRT model is not initialized. Please call initializeModel() first.";
      await logToFile(errStr);
      throw StateError(errStr);
    }
    try {
      final response = await _conversation!.sendMessage(prompt);
      return response.text;
    } catch (e, stack) {
      final errLog = "Error running model inference: $e\nStack: $stack";
      await logToFile(errLog);
      return errLog;
    }
  }

  /// Streams chunks of text back in real-time.
  ///
  /// Pass the user's plain text — the runtime adds the turn tags.
  Stream<String> generateResponseStream(String prompt) {
    if (!_isInitialized || _conversation == null) {
      logToFile("Error: generateResponseStream called when model is not initialized");
      return Stream.error(
        StateError("LiteRT model is not initialized. Please call initializeModel() first.")
      );
    }

    logToFile("Starting sendMessageStream for prompt length: ${prompt.length}");
    return _conversation!.sendMessageStream(prompt).map((msg) {
      return msg.text;
    }).handleError((err, stack) {
      logToFile("Stream Error: $err\nStack: $stack");
    });
  }

  /// Releases the conversation and engine. Context window first, graph second.
  Future<void> dispose() => _disposeEngine();

  Future<void> _disposeEngine() async {
    try {
      await _conversation?.dispose();
    } catch (_) {}
    _conversation = null;
    try {
      await _engine?.dispose();
    } catch (_) {}
    _engine = null;
    _isInitialized = false;
    _activeBackend = null;
  }
}
