import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'llm_provider.dart';
import 'ollama_provider.dart';
import 'nvidia_provider.dart';
import 'litert_provider.dart';
import 'gemma_provider.dart';
import 'secure_storage_service.dart';

/// Central LLM service that manages multiple providers
class LlmService {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal();

  final _secureStorage = SecureStorageService();

  late final OllamaProvider ollamaProvider;
  late final NvidiaProvider nvidiaProvider;
  late final LiteRtProvider litertProvider;
  late final GemmaProvider gemmaProvider;

  LlmProvider? _currentProvider;

  /// Initialize all providers
  Future<void> init() async {
    // Restore saved settings
    final savedUrl = await _secureStorage.getOllamaUrl();
    final savedModel = await _secureStorage.getSelectedModel();
    final savedProvider = await _secureStorage.getLlmProvider();

    ollamaProvider = OllamaProvider(
      baseUrl: savedUrl ?? 'http://192.168.0.1:11434',
      model: savedModel,
    );
    nvidiaProvider = NvidiaProvider();

    // LiteRT: use app documents dir for model storage
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${appDir.path}/litert_models');
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }
      litertProvider = LiteRtProvider(
        modelsDir: modelsDir.path,
        model: savedModel,
      );
    } catch (_) {
      litertProvider = LiteRtProvider();
    }

    // Gemma (flutter_gemma): on-device via LiteRT-LM managed bridge
    gemmaProvider = GemmaProvider();

    // Restore previously saved Gemma model so the engine is ready
    // without requiring manual model re-selection after app restart.
    if (savedModel != null && (savedProvider == null || savedProvider == 'gemma')) {
      try {
        await gemmaProvider.selectModel(savedModel);
      } catch (e) {
        // Model file may be missing or corrupted — user can re-download in settings
        // ignore: avoid_print
        print('LlmService.init: Failed to restore Gemma model "$savedModel": $e');
      }
    }

    // Restore previously selected provider
    if (savedProvider == 'ollama') {
      _currentProvider = ollamaProvider;
    } else if (savedProvider == 'nvidia') {
      _currentProvider = nvidiaProvider;
    } else if (savedProvider == 'litert') {
      _currentProvider = litertProvider;
    } else if (savedProvider == 'gemma') {
      _currentProvider = gemmaProvider;
    } else {
      // Auto-detect: prefer gemma (on-device, flutter_gemma), then litert, then ollama
      _currentProvider = gemmaProvider;
    }
  }

  /// Get the current active provider
  LlmProvider get currentProvider {
    if (_currentProvider == null) {
      _currentProvider = litertProvider;
    }
    return _currentProvider!;
  }

  /// List all available providers
  List<LlmProvider> get providers =>
      [gemmaProvider, litertProvider, ollamaProvider, nvidiaProvider];

  /// Switch active provider
  Future<void> setProvider(String providerId) async {
    if (providerId == 'gemma') {
      _currentProvider = gemmaProvider;
    } else if (providerId == 'litert') {
      _currentProvider = litertProvider;
    } else if (providerId == 'ollama') {
      _currentProvider = ollamaProvider;
    } else if (providerId == 'nvidia') {
      _currentProvider = nvidiaProvider;
    }
    await _secureStorage.saveLlmProvider(providerId);
  }

  /// Save ollama server URL
  Future<void> setOllamaUrl(String url) async {
    ollamaProvider.updateBaseUrl(url);
    await _secureStorage.saveOllamaUrl(url);
  }

  /// Get saved ollama URL
  Future<String?> getSavedOllamaUrl() async {
    return await _secureStorage.getOllamaUrl();
  }

  /// Select model for current provider
  Future<void> selectModel(String modelName) async {
    await currentProvider.selectModel(modelName);
    await _secureStorage.saveSelectedModel(modelName);
  }

  /// Get currently selected model name
  String? get selectedModel => currentProvider.selectedModel;

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

  /// Check if any provider is available
  Future<bool> isAvailable() async {
    if (await currentProvider.isAvailable()) return true;
    // Try other providers in order of preference
    for (final p in providers) {
      if (await p.isAvailable()) {
        _currentProvider = p;
        return true;
      }
    }
    return false;
  }

  /// Get the best available provider for the current settings
  Future<LlmProvider?> getAvailableProvider() async {
    for (final p in providers) {
      if (await p.isAvailable()) {
        return p;
      }
    }
    return null;
  }

  /// Get LiteRT models directory path
  String? get litertModelsDir {
    // ignore: invalid_use_of_private_member
    return litertProvider.modelsDir;
  }
}
