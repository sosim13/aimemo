import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static final SecureStorageService _instance = SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final _storage = const FlutterSecureStorage();

  static const _selectedModelKey = 'selected_model';

  // --- Selected Model ---

  Future<void> saveSelectedModel(String modelName) async {
    await _storage.write(key: _selectedModelKey, value: modelName);
  }

  Future<String?> getSelectedModel() async {
    return await _storage.read(key: _selectedModelKey);
  }
}
