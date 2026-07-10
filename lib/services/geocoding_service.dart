import 'dart:convert';
import 'package:http/http.dart' as http;
import 'secure_storage_service.dart';
import 'debug_logger.dart';

class GeocodingResult {
  final double lat;
  final double lng;
  final String address;

  const GeocodingResult({
    required this.lat,
    required this.lng,
    required this.address,
  });
}

class GeocodingService {
  static final GeocodingService _instance = GeocodingService._internal();
  factory GeocodingService() => _instance;
  GeocodingService._internal();

  final _storage = SecureStorageService();
  final _debug = DebugLogger();

  /// Search for coordinates of a Korean address using Kakao Local API.
  /// Returns null if address not found or API key missing.
  Future<GeocodingResult?> searchAddress(String address) async {
    final apiKey = await _storage.getKakaoRestApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      await _debug.log('Geocoding: Kakao API key not set');
      return null;
    }

    final uri = Uri.parse(
      'https://dapi.kakao.com/v2/local/search/address.json',
    ).replace(queryParameters: {'query': address});

    try {
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'KakaoAK $apiKey',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        await _debug.log('Geocoding: Kakao API error ${response.statusCode}: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final documents = data['documents'] as List<dynamic>?;

      if (documents == null || documents.isEmpty) {
        await _debug.log('Geocoding: No results for "$address"');
        return null;
      }

      final first = documents.first as Map<String, dynamic>;
      final x = double.tryParse(first['x'] as String? ?? '');
      final y = double.tryParse(first['y'] as String? ?? '');
      final roadAddr = first['road_address'] as Map<String, dynamic>?;
      final regionAddr = first['address'] as Map<String, dynamic>?;
      final foundAddress = roadAddr?['address_name'] as String? ??
          regionAddr?['address_name'] as String? ??
          address;

      if (x == null || y == null) {
        await _debug.log('Geocoding: Invalid coordinates for "$address"');
        return null;
      }

      await _debug.log('Geocoding: "$address" -> ($y, $x) = "$foundAddress"');
      return GeocodingResult(lat: y, lng: x, address: foundAddress);
    } catch (e) {
      await _debug.log('Geocoding: Request failed for "$address": $e');
      return null;
    }
  }
}
