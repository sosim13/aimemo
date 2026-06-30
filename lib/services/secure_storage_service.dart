import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static final SecureStorageService _instance = SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final _storage = const FlutterSecureStorage();

  static const _apiKeyKey = 'neotron_api_key';
  static const _llmProviderKey = 'llm_provider';
  static const _ollamaUrlKey = 'ollama_url';
  static const _selectedModelKey = 'selected_model';

  // --- API Key (for NVIDIA) ---

  Future<void> saveApiKey(String apiKey) async {
    await _storage.write(key: _apiKeyKey, value: apiKey);
  }

  Future<String?> getApiKey() async {
    return await _storage.read(key: _apiKeyKey);
  }

  Future<void> deleteApiKey() async {
    await _storage.delete(key: _apiKeyKey);
  }

  Future<bool> hasApiKey() async {
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }

  // --- LLM Provider Selection ---

  Future<void> saveLlmProvider(String providerId) async {
    await _storage.write(key: _llmProviderKey, value: providerId);
  }

  Future<String?> getLlmProvider() async {
    return await _storage.read(key: _llmProviderKey);
  }

  // --- Ollama Server URL ---

  Future<void> saveOllamaUrl(String url) async {
    await _storage.write(key: _ollamaUrlKey, value: url);
  }

  Future<String?> getOllamaUrl() async {
    return await _storage.read(key: _ollamaUrlKey);
  }

  // --- Selected Model ---

  Future<void> saveSelectedModel(String modelName) async {
    await _storage.write(key: _selectedModelKey, value: modelName);
  }

  Future<String?> getSelectedModel() async {
    return await _storage.read(key: _selectedModelKey);
  }
}
