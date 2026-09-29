import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BrowserApp {
  final String packageName;
  final String name;
  final Uint8List? icon;

  const BrowserApp({required this.packageName, required this.name, this.icon});
}

/// 설치된 브라우저 조회 및 지정 브라우저로 링크 열기 (Android 전용).
class BrowserService {
  static const _channel = MethodChannel('com.aimemo.aimemo/browser');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<List<BrowserApp>> getInstalledBrowsers() async {
    if (!isSupported) return [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getInstalledBrowsers');
      return (raw ?? []).map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        return BrowserApp(
          packageName: map['packageName'] as String,
          name: map['name'] as String,
          icon: map['icon'] as Uint8List?,
        );
      }).toList();
    } catch (e) {
      debugPrint('[BrowserService] getInstalledBrowsers 오류: $e');
      return [];
    }
  }

  static Future<String?> getPreferredBrowser() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('getPreferredBrowser');
    } catch (_) {
      return null;
    }
  }

  /// [packageName]이 null이면 기본 브라우저 지정을 해제한다.
  static Future<void> setPreferredBrowser(String? packageName) async {
    if (!isSupported) return;
    await _channel.invokeMethod('setPreferredBrowser', {'packageName': packageName});
  }

  /// 지정 브라우저로 열기. 해당 브라우저가 없으면 false.
  static Future<bool> openWith(String url, String packageName) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'openUrl',
        {'url': url, 'packageName': packageName},
      );
      return ok ?? false;
    } catch (e) {
      debugPrint('[BrowserService] openWith 오류: $e');
      return false;
    }
  }
}
