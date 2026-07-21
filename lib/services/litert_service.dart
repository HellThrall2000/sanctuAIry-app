import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class LiteRtService {
  static const MethodChannel _methodChannel = MethodChannel('sanctuary/litert_method');
  static const EventChannel _eventChannel = EventChannel('sanctuary/litert_stream');

  static final LiteRtService _instance = LiteRtService._internal();
  factory LiteRtService() => _instance;
  LiteRtService._internal();

  bool _isInitialized = false;
  String? _modelPath;

  bool get isInitialized => _isInitialized;
  String? get modelPath => _modelPath;

  /// Locates the default model path or searches the app documents directory for a .litertlm file
  Future<String?> findLocalModelFile() async {
    try {
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

      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final extFile = File('${extDir.path}/model.litertlm');
        if (await extFile.exists()) {
          return extFile.path;
        }
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

  /// Initialize the native LiteRT / MediaPipe tasks-genai engine
  Future<bool> initializeModel({
    required String path,
    double temperature = 0.7,
    int maxTokens = 512,
  }) async {
    try {
      final bool success = await _methodChannel.invokeMethod('initializeModel', {
        'modelPath': path,
        'temperature': temperature,
        'maxTokens': maxTokens,
      });
      _isInitialized = success;
      if (success) {
        _modelPath = path;
      }
      return success;
    } on PlatformException catch (e) {
      print("Failed to initialize LiteRT model on native platform: ${e.message}");
      _isInitialized = false;
      return false;
    }
  }

  /// Generates a single-shot response from the local LiteRT model
  Future<String> generateResponse(String prompt) async {
    if (!_isInitialized) {
      throw StateError("LiteRT model is not initialized. Please call initializeModel() first.");
    }
    try {
      final String response = await _methodChannel.invokeMethod('generateResponse', {
        'prompt': prompt,
      });
      return response;
    } on PlatformException catch (e) {
      return "Error running model inference: ${e.message}";
    }
  }

  /// Streams chunks of text back in real-time.
  /// This is the most optimal way for on-device inference as it eliminates latency-blocking.
  Stream<String> generateResponseStream(String prompt) {
    if (!_isInitialized) {
      return Stream.error(
        StateError("LiteRT model is not initialized. Please call initializeModel() first.")
      );
    }

    final StreamController<String> controller = StreamController<String>();

    // Start native asynchronous model inference
    _methodChannel.invokeMethod('startStreamingInference', {
      'prompt': prompt,
    }).then((_) {
      // Stream registration is handled by the EventChannel listener
      StreamSubscription? subscription;
      subscription = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (data is Map) {
            final String? chunk = data['chunk'] as String?;
            final bool? isComplete = data['isComplete'] as bool?;
            final String? error = data['error'] as String?;

            if (error != null) {
              controller.addError(error);
              subscription?.cancel();
              controller.close();
            } else {
              if (chunk != null) {
                controller.add(chunk);
              }
              if (isComplete == true) {
                subscription?.cancel();
                controller.close();
              }
            }
          }
        },
        onError: (err) {
          controller.addError(err);
          subscription?.cancel();
          controller.close();
        },
        onDone: () {
          if (!controller.isClosed) {
            controller.close();
          }
        },
        cancelOnError: true,
      );
    }).catchError((err) {
      controller.addError("Failed to trigger streaming inference: $err");
      controller.close();
    });

    return controller.stream;
  }
}
