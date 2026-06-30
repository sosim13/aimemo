import 'package:flutter/services.dart';

class NativeShareService {
  static const _channel = MethodChannel('com.aimemo.aimemo/share');

  /// Check for shared text from other apps (e.g., YouTube share)
  static Future<String?> getSharedText() async {
    try {
      final sharedText = await _channel.invokeMethod<String>('getSharedText');
      return sharedText;
    } on MissingPluginException {
      return null;
    } catch (e) {
      return null;
    }
  }
}
