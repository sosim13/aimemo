import 'dart:convert';
import 'package:http/http.dart' as http;
import 'secure_storage_service.dart';
import 'debug_logger.dart';

class NaverCoordResult {
  /// UTM-K X coordinate (northing)
  final double x;
  /// UTM-K Y coordinate (easting)
  final double y;

  const NaverCoordResult({required this.x, required this.y});
}

class NaverCoordService {
  static final NaverCoordService _instance = NaverCoordService._internal();
  factory NaverCoordService() => _instance;
  NaverCoordService._internal();

  final _storage = SecureStorageService();
  final _debug = DebugLogger();

  /// Convert WGS84 (lat/lng) to Naver UTM-K coordinates.
  /// Returns null if conversion fails or API keys missing.
  Future<NaverCoordResult?> wgs84ToUtmk(double lat, double lng) async {
    final clientId = await _storage.getNaverClientId();
    final clientSecret = await _storage.getNaverClientSecret();

    if (clientId == null || clientId.isEmpty) {
      await _debug.log('NaverCoord: Naver Client ID not set');
      return null;
    }
    if (clientSecret == null || clientSecret.isEmpty) {
      await _debug.log('NaverCoord: Naver Client Secret not set');
      return null;
    }

    final uri = Uri.parse(
      'https://naveropenapi.apigw.ntruss.com/map-coordinates/v2/coordinates',
    ).replace(queryParameters: {
      'source': 'WGS84',
      'target': 'UTMK',
      'x': lng.toString(),
      'y': lat.toString(),
    });

    try {
      final response = await http.get(
        uri,
        headers: {
          'X-NCP-APIGW-API-KEY-ID': clientId,
          'X-NCP-APIGW-API-KEY': clientSecret,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        await _debug.log(
          'NaverCoord: API error ${response.statusCode}: ${response.body}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final x = (data['x'] as num?)?.toDouble();
      final y = (data['y'] as num?)?.toDouble();

      if (x == null || y == null) {
        await _debug.log('NaverCoord: Invalid response: ${response.body}');
        return null;
      }

      await _debug.log('NaverCoord: WGS84($lat, $lng) -> UTMK($x, $y)');
      return NaverCoordResult(x: x, y: y);
    } catch (e) {
      await _debug.log('NaverCoord: Request failed: $e');
      return null;
    }
  }
}
