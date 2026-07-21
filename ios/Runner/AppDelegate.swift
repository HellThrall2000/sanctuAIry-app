import UIKit
import Flutter
import MediaPipeTasksGenAI

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var llmInference: LlmInference?
  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    
    let methodChannel = FlutterMethodChannel(name: "sanctuary/litert_method",
                                              binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: "sanctuary/litert_stream",
                                            binaryMessenger: controller.binaryMessenger)
    
    eventChannel.setStreamHandler(self)
    
    methodChannel.setMethodCallHandler({
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      guard let self = self else { return }
      
      switch call.method {
      case "initializeModel":
        guard let args = call.arguments as? [String: Any],
              let modelPath = args["modelPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing modelPath", details: nil))
          return
        }
        
        let temperature = args["temperature"] as? Double ?? 0.7
        let maxTokens = args["maxTokens"] as? Int ?? 512
        
        // Load model on background thread to prevent UI locking
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let options = LlmInference.Options()
            options.modelPath = modelPath
            options.temperature = Float(temperature)
            options.maxTokens = maxTokens
            // Note: iOS MediaPipe LlmInference uses Metal by default when supported.
            
            self.llmInference = try LlmInference(options: options)
            
            DispatchQueue.main.async {
              result(true)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "INIT_FAILED", message: "Failed to initialize MediaPipe iOS model: \(error.localizedDescription)", details: nil))
            }
          }
        }
        
      case "isModelInitialized":
        result(self.llmInference != nil)
        
      case "generateResponse":
        guard let args = call.arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing prompt", details: nil))
          return
        }
        
        guard let inference = self.llmInference else {
          result(FlutterError(code: "NOT_INITIALIZED", message: "LiteRT iOS engine is not loaded", details: nil))
          return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let response = try inference.generateResponse(prompt: prompt)
            DispatchQueue.main.async {
              result(response)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "INFERENCE_ERROR", message: error.localizedDescription, details: nil))
            }
          }
        }
        
      case "startStreamingInference":
        guard let args = call.arguments as? [String: Any],
              let prompt = args["prompt"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing prompt", details: nil))
          return
        }
        
        guard let inference = self.llmInference else {
          result(FlutterError(code: "NOT_INITIALIZED", message: "LiteRT iOS engine is not loaded", details: nil))
          return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            // Native MediaPipe iOS asynchronous callback streaming
            try inference.generateResponseAsync(prompt: prompt) { [weak self] partialResult, error in
              guard let self = self, let sink = self.eventSink else { return }
              
              DispatchQueue.main.async {
                var eventData = [String: Any]()
                if let error = error {
                  eventData["error"] = error.localizedDescription
                } else if let chunk = partialResult {
                  eventData["chunk"] = chunk
                  eventData["isComplete"] = false
                }
                sink(eventData)
              }
            }
            
            // Finish generation streaming
            DispatchQueue.main.async {
              var completeData = [String: Any]()
              completeData["isComplete"] = true
              self.eventSink?(completeData)
              result(true)
            }
          } catch {
            DispatchQueue.main.async {
              var errData = [String: Any]()
              errData["error"] = error.localizedDescription
              self.eventSink?(errData)
              result(FlutterError(code: "STREAM_INIT_FAILED", message: error.localizedDescription, details: nil))
            }
          }
        }
        
      default:
        result(FlutterMethodNotImplemented)
      }
    })
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // FlutterStreamHandler implementation
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}
