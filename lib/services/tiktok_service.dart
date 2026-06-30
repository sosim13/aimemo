import 'dart:convert';
import 'package:http/http.dart' as http;

class TikTokVideoInfo {
  final String videoId;
  final String title;
  final String authorName;
  final String? thumbnailUrl;
  final String? description;

  TikTokVideoInfo({
    required this.videoId,
    required this.title,
    required this.authorName,
    this.thumbnailUrl,
    this.description,
  });

  String get videoUrl => 'https://www.tiktok.com/@$authorName/video/$videoId';

  /// Build the full content to send to AI analysis
  String buildContentForAi() {
    final buffer = StringBuffer();
    buffer.writeln('TikTok 영상 제목: $title');
    buffer.writeln('크리에이터: $authorName');
    if (description != null && description!.isNotEmpty) {
      buffer.writeln('영상 설명: $description');
    }
    return buffer.toString();
  }
}

class TikTokService {
  static final TikTokService _instance = TikTokService._internal();
  factory TikTokService() => _instance;
  TikTokService._internal();

  /// Resolve short TikTok URLs (lite.tiktok.com, vm.tiktok.com) to full URLs
  Future<String> _resolveUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    // Only resolve short link domains
    if (!uri.host.contains('lite.tiktok.com') &&
        !uri.host.contains('vm.tiktok.com')) {
      return url;
    }

    try {
      // Use a Client to control redirect behavior
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        request.headers['User-Agent'] =
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36';
        request.followRedirects = false;

        final streamedResponse = await client.send(request);
        final statusCode = streamedResponse.statusCode;

        // If redirect (301, 302, 307, 308), follow the Location header
        if (statusCode == 301 ||
            statusCode == 302 ||
            statusCode == 307 ||
            statusCode == 308) {
          final location = streamedResponse.headers['location'];
          if (location != null && location.isNotEmpty) {
            // Handle relative redirect URLs
            if (location.startsWith('/')) {
              return 'https://www.tiktok.com$location';
            }
            return location;
          }
        }
      } finally {
        client.close();
      }

      // Fallback: let http.get follow redirects and use the final URL
      final getResponse = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
        },
      );
      if (getResponse.statusCode == 200) {
        // Check if the request URL changed (redirect was followed)
        if (getResponse.request != null &&
            getResponse.request!.url.toString() != url) {
          return getResponse.request!.url.toString();
        }

        // Check for meta refresh redirect in HTML
        final html = utf8.decode(getResponse.bodyBytes);
        final metaRefresh = RegExp(
          r"""<meta\s+[^>]*http-equiv=["']refresh["'][^>]*content=["']\d+;url=([^"']+)["']""",
          caseSensitive: false,
        ).firstMatch(html);
        if (metaRefresh != null) {
          var redirectUrl = metaRefresh.group(1)!;
          if (redirectUrl.startsWith('/')) {
            redirectUrl = 'https://www.tiktok.com$redirectUrl';
          }
          return redirectUrl;
        }
      }
    } catch (_) {}

    return url;
  }

  /// Extract TikTok video info from various URL formats using oEmbed API
  Future<TikTokVideoInfo?> getVideoInfo(String url) async {
    // Step 1: Resolve short links to full URLs first
    final resolvedUrl = await _resolveUrl(url);
    final effectiveUrl = resolvedUrl;

    try {
      // Step 2: Use oEmbed API with the full URL
      final oembedUrl =
          'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(effectiveUrl)}';
      final response = await http.get(
        Uri.parse(oembedUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));

        final title = data['title'] as String? ?? 'TikTok 영상';
        final authorName = data['author_name'] as String? ?? '알 수 없음';
        final thumbnailUrl = data['thumbnail_url'] as String?;
        final authorUrl = data['author_url'] as String?;

        // Extract author name from author_url if available
        String finalAuthor = authorName;
        if (finalAuthor == '알 수 없음' && authorUrl != null) {
          final authorUri = Uri.tryParse(authorUrl);
          if (authorUri != null) {
            final segments =
                authorUri.pathSegments.where((s) => s.isNotEmpty).toList();
            if (segments.isNotEmpty) {
              finalAuthor = segments.first.replaceAll('@', '');
            }
          }
        }

        return TikTokVideoInfo(
          videoId: _extractVideoId(effectiveUrl) ?? _extractVideoId(url) ?? url,
          title: title,
          authorName: finalAuthor,
          thumbnailUrl: thumbnailUrl,
          description: title != 'TikTok 영상' ? title : null,
        );
      }
    } catch (_) {}

    // Step 3: Fallback — scrape HTML if oEmbed fails
    try {
      final uri = Uri.tryParse(effectiveUrl);
      if (uri != null) {
        final htmlResponse = await http.get(
          Uri.parse(effectiveUrl),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
            'Accept-Language': 'ko-KR,ko;q=0.9',
          },
        );

        if (htmlResponse.statusCode == 200) {
          final html = utf8.decode(htmlResponse.bodyBytes);

          String title = 'TikTok 영상';
          String description = '';

          final ogTitle = RegExp(
            r"""<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']""",
            caseSensitive: false,
          ).firstMatch(html);
          if (ogTitle != null) {
            final t = ogTitle.group(1)!.trim();
            if (t.isNotEmpty) title = t;
          }

          final ogDesc = RegExp(
            r"""<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']""",
            caseSensitive: false,
          ).firstMatch(html);
          if (ogDesc != null) {
            description = ogDesc.group(1)!.trim();
          }

          // Extract author from resolved URL or HTML
          String author = _extractAuthorFromUrl(effectiveUrl) ??
              _extractAuthorFromUrl(url) ??
              '알 수 없음';

          // Try to get author from og:url or canonical URL in HTML
          if (author == '알 수 없음') {
            final ogUrl = RegExp(
              r"""<meta\s+[^>]*property=["']og:url["'][^>]*content=["']([^"']*)["']""",
              caseSensitive: false,
            ).firstMatch(html);
            if (ogUrl != null) {
              author = _extractAuthorFromUrl(ogUrl.group(1)!) ?? '알 수 없음';
            }
          }

          return TikTokVideoInfo(
            videoId: _extractVideoId(effectiveUrl) ??
                _extractVideoId(url) ??
                url,
            title: title,
            authorName: author,
            thumbnailUrl: null,
            description: description.isNotEmpty ? description : null,
          );
        }
      }
    } catch (_) {}

    return null;
  }

  /// Extract TikTok video ID from URL
  String? _extractVideoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    // vm.tiktok.com/XXXXX (short links)
    if (uri.host.contains('vm.tiktok.com') ||
        uri.host.contains('lite.tiktok.com')) {
      final segments =
          uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) {
        return segments.last;
      }
      // Handle trailing slash case - use the path itself
      final path = uri.path.replaceAll('/', '').trim();
      if (path.isNotEmpty) return path;
    }

    // www.tiktok.com/@username/video/VIDEO_ID
    if (uri.host.contains('tiktok.com')) {
      final segments =
          uri.pathSegments.where((s) => s.isNotEmpty).toList();
      // segments = ['@username', 'video', 'VIDEO_ID']
      if (segments.length >= 3 && segments[1] == 'video') {
        return segments[2];
      }
    }

    // Fallback: return last path segment
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      return segments.last;
    }

    return null;
  }

  /// Extract author username from TikTok URL
  String? _extractAuthorFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.host.contains('tiktok.com')) return null;

    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments[0].startsWith('@')) {
      return segments[0].substring(1);
    }
    return null;
  }

  /// Check if a URL is a TikTok URL
  bool isTikTokUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.host.contains('tiktok.com');
  }
}
