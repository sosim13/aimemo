import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var litertBridge: LiteRtBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register LiteRT-LM channel
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: LiteRtBridge.CHANNEL,
        binaryMessenger: controller.binaryMessenger)

      litertBridge = LiteRtBridge()

      channel.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }

        switch call.method {
        case "isAvailable":
          result(self.litertBridge?.isAvailable() ?? false)

        case "initEngine":
          if let modelPath = (call.arguments as? [String: Any])?["modelPath"] as? String {
            let success = self.litertBridge?.initEngine(modelPath: modelPath) ?? false
            result(success)
          } else {
            result(false)
          }

        case "generate":
          guard let args = call.arguments as? [String: Any],
                let prompt = args["prompt"] as? String else {
            result(nil)
            return
          }
          let maxTokens = args["maxTokens"] as? Int ?? 1500
          let temperature = args["temperature"] as? Double ?? 0.2
          let response = self.litertBridge?.generate(
            prompt: prompt, maxTokens: maxTokens, temperature: temperature)
          result(response)

        case "close":
          self.litertBridge?.close()
          self.litertBridge = nil
          result(nil)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
