package com.example.sanctuary

import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions

class MainActivity: FlutterActivity() {
    private val METHOD_CHANNEL = "sanctuary/litert_method"
    private val EVENT_CHANNEL = "sanctuary/litert_stream"

    private var llmInference: LlmInference? = null
    private var eventSink: EventChannel.EventSink? = null
    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel handles model loading and synchronous queries
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "initializeModel" -> {
                    val modelPath = call.argument<String>("modelPath")
                    val temperature = call.argument<Double>("temperature") ?: 0.7
                    val maxTokens = call.argument<Int>("maxTokens") ?: 512

                    if (modelPath == null || !File(modelPath).exists()) {
                        result.error("INVALID_MODEL", "Model file does not exist at: $modelPath", null)
                        return@setMethodCallHandler
                    }

                    // Initialize in a background thread to prevent UI freeze
                    executor.execute {
                        try {
                            val options = LlmInferenceOptions.builder()
                                .setModelPath(modelPath)
                                .setMaxTokens(maxTokens)
                                .build()

                            // Close previous instance if exists
                            llmInference?.close()
                            llmInference = LlmInference.createFromOptions(context, options)

                            runOnUiThread {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("INIT_FAILED", "Failed to load .litertlm model: ${e.message}", e.toString())
                            }
                        }
                    }
                }
                "isModelInitialized" -> {
                    result.success(llmInference != null)
                }
                "generateResponse" -> {
                    val prompt = call.argument<String>("prompt")
                    if (llmInference == null) {
                        result.error("NOT_INITIALIZED", "LiteRT engine is not loaded", null)
                        return@setMethodCallHandler
                    }
                    if (prompt == null) {
                        result.error("EMPTY_PROMPT", "Prompt cannot be null", null)
                        return@setMethodCallHandler
                    }

                    executor.execute {
                        try {
                            // Synchronous generate on background thread
                            val response = llmInference!!.generateResponse(prompt)
                            runOnUiThread {
                                result.success(response)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("INFERENCE_ERROR", e.message, null)
                            }
                        }
                    }
                }
                "startStreamingInference" -> {
                    val prompt = call.argument<String>("prompt")
                    if (llmInference == null) {
                        result.error("NOT_INITIALIZED", "LiteRT engine is not loaded", null)
                        return@setMethodCallHandler
                    }
                    if (prompt == null) {
                        result.error("EMPTY_PROMPT", "Prompt cannot be null", null)
                        return@setMethodCallHandler
                    }

                    executor.execute {
                        try {
                            // Start MediaPipe/LiteRT streaming model generation
                            llmInference!!.generateResponseAsync(prompt) { partialResult, done ->
                                runOnUiThread {
                                    val eventData = HashMap<String, Any>()
                                    if (partialResult != null) {
                                        eventData["chunk"] = partialResult
                                        eventData["isComplete"] = done
                                        eventSink?.success(eventData)
                                    }
                                }
                            }

                            runOnUiThread {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                val errData = HashMap<String, Any>()
                                errData["error"] = e.message ?: "Inference error"
                                eventSink?.success(errData)
                                result.error("STREAM_INIT_FAILED", e.message, null)
                            }
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // EventChannel streams real-time generated chunks back to Flutter
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    override fun onDestroy() {
        llmInference?.close()
        executor.shutdown()
        super.onDestroy()
    }
}
