import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'llm_provider.dart';
import 'gemma_provider.dart';
import 'secure_storage_service.dart';

/// Central LLM service that manages the Gemma provider
class LlmService {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal();

  final _secureStorage = SecureStorageService();

  late final GemmaProvider gemmaProvider;

  LlmProvider? _currentProvider;

  /// Initialize all providers
  Future<void> init() async {
    // Restore saved settings
    final savedModel = await _secureStorage.getSelectedModel();

    // Gemma (flutter_gemma): on-device via LiteRT-LM managed bridge
    gemmaProvider = GemmaProvider();

    // Restore previously saved Gemma model so the engine is ready
    if (savedModel != null) {
      try {
        await gemmaProvider.selectModel(savedModel);
      } catch (e) {
        // ignore: avoid_print
        print('LlmService.init: Failed to restore Gemma model "$savedModel": $e');
      }
    }

    _currentProvider = gemmaProvider;
  }

  /// Get the current active provider
  LlmProvider get currentProvider {
    if (_currentProvider == null) {
      _currentProvider = gemmaProvider;
    }
    return _currentProvider!;
  }

  /// List all available providers (only gemma)
  List<LlmProvider> get providers => [gemmaProvider];

  /// Get currently selected model name
  String? get selectedModel => currentProvider.selectedModel;

  /// Select model for current provider
  Future<void> selectModel(String modelName) async {
    await currentProvider.selectModel(modelName);
    await _secureStorage.saveSelectedModel(modelName);
  }

  /// Analyze content with current provider
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    return currentProvider.analyze(
      content: content,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
    );
  }

  /// Check if provider is available
  Future<bool> isAvailable() async {
    return await currentProvider.isAvailable();
  }

  /// Get the best available provider for the current settings
  Future<LlmProvider?> getAvailableProvider() async {
    if (await currentProvider.isAvailable()) {
      return currentProvider;
    }
    return null;
  }
}
