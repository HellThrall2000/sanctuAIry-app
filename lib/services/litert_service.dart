import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'model_download_service.dart';
import 'model_profile.dart';
import 'model_settings.dart';

/// Wraps the native LiteRT-LM engine (`liblitertlm_jni.so`) for Sanctuary.
///
/// CPU is the correct and intended backend for a `.litertlm` model. The earlier
/// `reason=3 (LOW_MEMORY)` kills were a conversion defect — the model had been
/// quantized with `weight_only_wi4_afp32`, which stores INT4 but computes in
/// FP32 and so expands ~8x under XNNPACK. Re-exported with `dynamic_wi4_afp32`
/// it peaks at ~1,543 MB. See README for the measurements.
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

  // Retained so [reconfigure] and [reseed] can rebuild an equivalent
  // conversation without reloading the 2.5 GB model.
  String? _systemInstruction;
  List<LiteLmMessage>? _initialMessages;
  ModelSettings? _settings;

  final Random _random = Random();

  /// A fresh sampler seed.
  ///
  /// The native `SamplerConfig.seed` is a Kotlin `Int`, so this stays inside
  /// signed 32-bit range. Without it the seed is 0 on every conversation and
  /// generation is fully reproducible — the cause of the companion repeating
  /// itself verbatim. See packages/flutter_litert_lm/VENDOR.md.
  int _nextSeed() => _random.nextInt(0x7FFFFFFF);

  bool get isInitialized => _isInitialized;
  String? get modelPath => _modelPath;

  /// Which backend the engine actually came up on — GPU or the CPU fallback.
  LiteLmBackend? get activeBackend => _activeBackend;

  /// Every `.litertlm` on the device, each paired with the profile it should run
  /// under.
  ///
  /// Both the stock model and the fine-tune can be present at once — that is the
  /// point, so development can continue on stock while the fine-tune is being
  /// retrained. Directories are searched in order of specificity, and results are
  /// deduplicated by path.
  Future<List<LocatedModel>> findLocalModels() async {
    final searchDirs = <String>[];
    try {
      // Where ModelDownloadService puts a fetched model. First, because on a
      // Play install it is the only place a model ever comes from.
      searchDirs.add((await ModelDownloadService.instance.modelDirectory()).path);

      final extDir = await getExternalStorageDirectory();
      if (extDir != null) searchDirs.add(extDir.path);
      searchDirs.add((await getApplicationDocumentsDirectory()).path);
      searchDirs.add((await getApplicationSupportDirectory()).path);
    } catch (e) {
      debugPrint('Error resolving app directories: $e');
    }

    // The adb-push workflow, kept for development only.
    //
    // Reading these in a shipped build is not merely unnecessary, it is
    // impossible: from Android 10 scoped storage denies an app access to shared
    // storage it did not create, and the broad-access permission that would
    // restore it is one Play grants almost no one. A release build finds its
    // model in the managed directory above or not at all.
    if (kDebugMode) {
      searchDirs.addAll(const ['/sdcard/Download', '/sdcard']);
    }

    final found = <String, LocatedModel>{};
    for (final dir in searchDirs) {
      try {
        final directory = Directory(dir);
        if (!await directory.exists()) continue;
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.litertlm') &&
              !entity.path.endsWith('.bin')) {
            continue;
          }
          found.putIfAbsent(
            entity.path,
            () => LocatedModel(entity.path, ModelProfile.forFileName(entity.path)),
          );
        }
      } catch (e) {
        // An unreadable directory is expected on scoped storage; keep looking.
        print("Skipping $dir: $e");
      }
    }

    // Sorted by profile priority, not by the order the filesystem happened to
    // enumerate them. With both the stock model and the fine-tune present — the
    // normal state during development — filesystem order would decide which one
    // loads, and it is not stable across devices or installs.
    final models = found.values.toList()
      ..sort((a, b) => ModelProfile.all
          .indexOf(a.profile)
          .compareTo(ModelProfile.all.indexOf(b.profile)));
    return List.unmodifiable(models);
  }

  /// Picks the model to load.
  ///
  /// [preferredProfileId] wins when a matching file is present, so the dev panel
  /// can pin a choice. Otherwise the first model found is used.
  Future<LocatedModel?> findLocalModelFile({String? preferredProfileId}) async {
    final models = await findLocalModels();
    if (models.isEmpty) return null;

    if (preferredProfileId != null) {
      for (final m in models) {
        if (m.profile.id == preferredProfileId) return m;
      }
    }
    return models.first;
  }

  File? _logFile;

  /// Largest the diagnostics log may grow before it is started over.
  ///
  /// It is append-only across every model load and generation, so without a cap
  /// it grows without limit inside the user's app storage.
  static const int _maxLogBytes = 256 * 1024;

  /// Appends a line to the engine diagnostics log.
  ///
  /// **App-private, not `/sdcard/Download`.** This used to write to the public
  /// Downloads folder, which is three separate problems in a shipped app: it
  /// needs storage permission the app does not hold, scoped storage blocks it
  /// outright from Android 10, and it leaves a file behind after uninstall.
  /// The support directory needs no permission and is removed with the app.
  ///
  /// Failures here are swallowed. Diagnostics must never be able to break the
  /// thing they are diagnosing.
  Future<void> logToFile(String logMessage) async {
    try {
      final file = _logFile ??=
          File('${(await getApplicationSupportDirectory()).path}/engine.log');

      if (await file.exists() && await file.length() > _maxLogBytes) {
        await file.writeAsString('');
      }

      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$timestamp] $logMessage\n',
        mode: FileMode.append,
      );
    } catch (e) {
      debugPrint('Failed to write engine log: $e');
    }
  }

  /// The diagnostics log, for the developer panel to show or share.
  Future<String> readLog() async {
    try {
      final file = _logFile ??=
          File('${(await getApplicationSupportDirectory()).path}/engine.log');
      return await file.exists() ? await file.readAsString() : '';
    } catch (e) {
      return 'Could not read log: $e';
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
  ///
  /// [initialMessages] seeds the conversation with exemplar turns. This is the
  /// most effective lever on the companion's voice: the model is fine-tuned on
  /// therapist dialogue, so showing it the register works better than
  /// describing it in the system prompt. See [Persona.exemplars].
  ///
  /// [settings] carries both the sampler values and the [ModelProfile] they came
  /// from; see [ModelSettings.load].
  Future<String?> initializeModel({
    required String path,
    required ModelSettings settings,
    String? systemInstruction,
    List<LiteLmMessage>? initialMessages,
    LiteLmBackend backend = LiteLmBackend.cpu,
  }) {
    // Loading twice concurrently would double a footprint that is already at
    // the edge of what the device can hold, so callers share one attempt.
    return _pendingInit ??= _initializeModel(
      path: path,
      settings: settings,
      systemInstruction: systemInstruction,
      initialMessages: initialMessages,
      backend: backend,
    ).whenComplete(() => _pendingInit = null);
  }

  Future<String?> _initializeModel({
    required String path,
    required ModelSettings settings,
    String? systemInstruction,
    List<LiteLmMessage>? initialMessages,
    required LiteLmBackend backend,
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

      _systemInstruction = systemInstruction;
      _initialMessages = initialMessages;
      _settings = settings.copy();

      final seed = await _openConversation();

      await logToFile("Conversation ready on ${backend.name} "
          "with ${settings.profile.label} "
          "($settings seed=$seed, "
          "${initialMessages?.length ?? 0} exemplar turns, "
          "systemInstruction=${systemInstruction?.length ?? 0} chars).");
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
    }).handleError((Object err, StackTrace stack) {
      // Logged *and* rethrown. Swallowing it here was how a hard runtime
      // failure became invisible: the stream simply ended with no chunks, the
      // caller received an empty string instead of an exception, and the
      // message stayed on two grey ticks forever because the error path that
      // resolves the tick was never entered. Observed on device as
      // `Input token ids are too long: 4241 >= 4096` — a fatal overflow that
      // reached the user as silence.
      logToFile("Stream Error: $err\nStack: $stack");
      Error.throwWithStackTrace(err, stack);
    });
  }

  /// Whether [error] is the runtime refusing a prompt that will not fit.
  ///
  /// The message is matched rather than a type, because it arrives as a generic
  /// `PlatformException` carrying the JNI text — there is no distinct exception
  /// class to catch. Worth singling out: it is the one inference failure that is
  /// fully recoverable, by rebuilding the conversation smaller and retrying.
  static bool isContextOverflow(Object error) {
    final text = error.toString();
    return text.contains('Input token ids are too long') ||
        text.contains('Exceeding the maximum number of tokens');
  }

  /// Disposes any current conversation and opens a new one with a fresh seed.
  ///
  /// **[history] replaces the opening messages; it is not added to them.** It
  /// used to be concatenated — `[...?_initialMessages, ...history]` — and that
  /// was a context leak with no way to close it. `_initialMessages` is set once
  /// in [initializeModel] and never cleared, and on a warm start it holds the
  /// restored conversation, so every later reseed silently re-prefilled those
  /// turns underneath whatever it was handed. Compaction reseeds in order to
  /// *shrink* the window; concatenating made it grow instead, and the rebuilt
  /// conversation overflowed 4096 and failed outright. Whatever a caller passes
  /// here is the conversation, entire.
  ///
  /// Passing `null` — not an empty list — keeps [_initialMessages], which is
  /// what [reconfigure] wants: no history to preserve, and the persona
  /// exemplars should come back. An *empty* list is a caller deliberately
  /// asking for a conversation with nothing in it, which is the last resort
  /// when a prompt will not fit alongside any history at all.
  ///
  /// Returns the seed used, for logging. Callers must have checked [_engine] is
  /// non-null.
  Future<int> _openConversation({
    List<LiteLmMessage>? history,
    double temperatureMultiplier = 1.0,
  }) async {
    final base = _settings ?? ModelSettings();
    final settings = temperatureMultiplier == 1.0
        ? base
        : (base.copy()
          ..temperature = (base.temperature * temperatureMultiplier)
              .clamp(0.1, ModelSettings.maxTemperature));
    final seed = _nextSeed();

    await _conversation?.dispose();
    _conversation = await _engine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: _systemInstruction,
        initialMessages: history ?? [...?_initialMessages],
        samplerConfig: LiteLmSamplerConfig(
          topK: settings.topK,
          topP: settings.topP,
          temperature: settings.temperature,
          seed: seed,
        ),
      ),
    );
    return seed;
  }

  /// Rebuilds the conversation with new sampler settings.
  ///
  /// Sampler config is fixed at conversation creation, so changing it means a
  /// new conversation — but the engine (and its mapped 2.5 GB of weights) is
  /// kept, so this costs well under a second rather than a full reload.
  ///
  /// The conversation history is discarded, which is why the caller should warn
  /// the user that the companion will lose the current thread.
  Future<String?> reconfigure(ModelSettings settings) async {
    if (!_isInitialized || _engine == null) {
      return "Model is not initialized.";
    }
    try {
      await logToFile("Reconfiguring sampler: $settings");
      _settings = settings.copy();
      await _openConversation();
      return null;
    } catch (e, stack) {
      await logToFile("Reconfigure failed: $e\nStack: $stack");
      _isInitialized = false;
      _conversation = null;
      return e.toString();
    }
  }

  /// Rebuilds the conversation on a new seed, replaying [history].
  ///
  /// This is the escape hatch for the companion repeating itself. The native
  /// [LiteLmConversation] exposes no way to change the sampler mid-conversation
  /// — `javap` on litertlm-android confirms there is no setter and no per-call
  /// override — so a different seed requires a different conversation, and the
  /// transcript has to be replayed as initial messages.
  ///
  /// That replay means re-prefilling the whole history, which is why this is
  /// called only when a repeat is actually detected rather than every turn.
  /// Cost grows with transcript length; on a long conversation it is seconds,
  /// not milliseconds.
  ///
  /// [temperatureMultiplier] widens sampling for the retry. A new seed alone is
  /// not enough: a repeat is evidence the distribution is peaked, and on a peaked
  /// distribution every seed picks the same token. Measured on-device — two
  /// reseeds, two fresh seeds, byte-identical replies both times. The widening
  /// stays in force until the next reseed or [reconfigure].
  Future<String?> reseed({
    List<LiteLmMessage> history = const [],
    double temperatureMultiplier = ModelSettings.escapeTemperatureMultiplier,
  }) async {
    if (!_isInitialized || _engine == null) {
      return "Model is not initialized.";
    }
    try {
      final seed = await _openConversation(
        history: history,
        temperatureMultiplier: temperatureMultiplier,
      );
      // The engine's idea of what it opened with now matches reality. Without
      // this, a later `reconfigure` would resurrect the turns this reseed was
      // called to get rid of.
      _initialMessages = history;
      await logToFile("Reseeded conversation (seed=$seed, "
          "${history.length} replayed turns, "
          "temp x$temperatureMultiplier).");
      return null;
    } catch (e, stack) {
      await logToFile("Reseed failed: $e\nStack: $stack");
      _isInitialized = false;
      _conversation = null;
      return e.toString();
    }
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
