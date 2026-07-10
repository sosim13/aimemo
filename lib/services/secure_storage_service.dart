import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static final SecureStorageService _instance = SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final _storage = const FlutterSecureStorage();

  static const _selectedModelKey = 'selected_model';
  static const _kakaoRestApiKey = 'kakao_rest_api_key';
  static const _naverClientIdKey = 'naver_client_id';
  static const _naverClientSecretKey = 'naver_client_secret';

  // --- Selected Model ---

  Future<void> saveSelectedModel(String modelName) async {
    await _storage.write(key: _selectedModelKey, value: modelName);
  }

  Future<String?> getSelectedModel() async {
    return await _storage.read(key: _selectedModelKey);
  }

  // --- Kakao REST API Key ---

  Future<void> saveKakaoRestApiKey(String key) async {
    await _storage.write(key: _kakaoRestApiKey, value: key);
  }

  Future<String?> getKakaoRestApiKey() async {
    return await _storage.read(key: _kakaoRestApiKey);
  }

  // --- Naver Client ID ---

  Future<void> saveNaverClientId(String id) async {
    await _storage.write(key: _naverClientIdKey, value: id);
  }

  Future<String?> getNaverClientId() async {
    return await _storage.read(key: _naverClientIdKey);
  }

  // --- Naver Client Secret ---

  Future<void> saveNaverClientSecret(String secret) async {
    await _storage.write(key: _naverClientSecretKey, value: secret);
  }

  Future<String?> getNaverClientSecret() async {
    return await _storage.read(key: _naverClientSecretKey);
  }
}
