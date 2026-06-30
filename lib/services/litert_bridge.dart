import 'package:flutter/services.dart';

/// Platform channel bridge to native LiteRT-LM inference engine
class LiteRtBridge {
  static const _channel = MethodChannel('com.aimemo.aimemo/litert');

  /// Check if LiteRT-LM is available on this device
  static Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Initialize the LLM engine with a model file at [modelPath]
  static Future<bool> initEngine(String modelPath) async {
    try {
      final result = await _channel.invokeMethod<bool>('initEngine', {
        'modelPath': modelPath,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Run inference: generate text from [prompt]
  /// Returns null if inference fails
  static Future<String?> generate(String prompt,
      {int maxTokens = 1500, double temperature = 0.2}) async {
    try {
      final result = await _channel.invokeMethod<String>('generate', {
        'prompt': prompt,
        'maxTokens': maxTokens,
        'temperature': temperature,
      });
      return result;
    } on MissingPluginException {
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Release the engine resources
  static Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }

  /// Read LiteRT diagnostic crash markers (survives process death)
  static Future<String?> getDiagLog() async {
    try {
      return await _channel.invokeMethod<String>('getDiagLog');
    } catch (_) {
      return null;
    }
  }

  /// Clear LiteRT diagnostic crash marker file
  static Future<void> clearDiagLog() async {
    try {
      await _channel.invokeMethod<void>('clearDiagLog');
    } catch (_) {}
  }
}
