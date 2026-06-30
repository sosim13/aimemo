import 'youtube_service.dart';
import 'tiktok_service.dart';

class ParsedUrl {
  final String originalUrl;
  final String? youtubeVideoId;
  final bool isYouTube;
  final bool isTikTok;

  ParsedUrl({
    required this.originalUrl,
    this.youtubeVideoId,
    required this.isYouTube,
    this.isTikTok = false,
  });
}

class UrlHandlerService {
  static final UrlHandlerService _instance = UrlHandlerService._internal();
  factory UrlHandlerService() => _instance;
  UrlHandlerService._internal();

  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();

  /// Parse a shared URL and determine its type
  ParsedUrl parseUrl(String url) {
    final videoId = _youtubeService.extractVideoId(url);
    final isYouTube = videoId != null;
    final isTikTok = !isYouTube && _tiktokService.isTikTokUrl(url);

    return ParsedUrl(
      originalUrl: url,
      youtubeVideoId: videoId,
      isYouTube: isYouTube,
      isTikTok: isTikTok,
    );
  }
}
