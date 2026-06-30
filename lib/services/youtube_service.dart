import 'dart:convert';
import 'package:http/http.dart' as http;

class YouTubeVideoInfo {
  final String videoId;
  final String title;
  final String description;
  final String? thumbnailUrl;
  final String? channelName;
  final String? transcript; // Full transcript text from the video

  YouTubeVideoInfo({
    required this.videoId,
    required this.title,
    required this.description,
    this.thumbnailUrl,
    this.channelName,
    this.transcript,
  });

  String get videoUrl => 'https://www.youtube.com/watch?v=$videoId';

  /// Build the full content to send to AI analysis
  String buildContentForAi() {
    final buffer = StringBuffer();
    buffer.writeln('YouTube 영상 제목: $title');
    buffer.writeln('채널: ${channelName ?? '알 수 없음'}');
    if (description.isNotEmpty) {
      buffer.writeln('영상 설명: $description');
    }
    if (transcript != null && transcript!.isNotEmpty) {
      buffer.writeln('\n영상 자막 (transcript):');
      buffer.writeln(transcript);
    }
    return buffer.toString();
  }
}

class YouTubeService {
  static final YouTubeService _instance = YouTubeService._internal();
  factory YouTubeService() => _instance;
  YouTubeService._internal();

  /// Extract YouTube video ID from various URL formats
  String? extractVideoId(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;

    // youtube.com/watch?v=VIDEO_ID
    if (uri.host.contains('youtube.com') || uri.host.contains('youtu.be')) {
      if (uri.host == 'youtu.be') {
        // youtu.be/VIDEO_ID
        return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      }

      // youtube.com/watch?v=VIDEO_ID
      if (uri.path == '/watch') {
        return uri.queryParameters['v'];
      }

      // youtube.com/embed/VIDEO_ID
      if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'embed') {
        return uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      }

      // youtube.com/shorts/VIDEO_ID
      if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'shorts') {
        return uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      }
    }

    // m.youtube.com
    if (uri.host.contains('m.youtube.com') && uri.path == '/watch') {
      return uri.queryParameters['v'];
    }

    return null;
  }

  /// Check if a URL is a YouTube URL
  bool isYouTubeUrl(String url) {
    final videoId = extractVideoId(url);
    return videoId != null;
  }

  /// Get YouTube video info using oEmbed API + HTML fallback for description
  Future<YouTubeVideoInfo?> getVideoInfo(String videoId) async {
    String title = 'YouTube 영상';
    String description = '';
    String? thumbnailUrl;
    String? channelName;

    // 1) oEmbed API (title, channel, thumbnail — no description)
    try {
      final url =
          'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        title = data['title'] as String? ?? title;
        thumbnailUrl = data['thumbnail_url'] as String?;
        channelName = data['author_name'] as String?;
      }
    } catch (_) {}

    // 2) Fetch HTML page for og:description (real description, not just title)
    try {
      final htmlResponse = await http.get(
        Uri.parse('https://www.youtube.com/watch?v=$videoId'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'ko-KR,ko;q=0.9',
        },
      );

      if (htmlResponse.statusCode == 200) {
        final html = utf8.decode(htmlResponse.bodyBytes);

        // og:description
        final ogDesc = RegExp(
          r"""<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']""",
          caseSensitive: false,
        ).firstMatch(html);
        if (ogDesc != null) {
          description = ogDesc.group(1)!.trim();
        }

        // og:title (more accurate than oEmbed for non-English)
        final ogTitle = RegExp(
          r"""<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']""",
          caseSensitive: false,
        ).firstMatch(html);
        if (ogTitle != null && ogTitle.group(1)!.trim().isNotEmpty) {
          title = ogTitle.group(1)!.trim();
        }
      }
    } catch (_) {}

    return YouTubeVideoInfo(
      videoId: videoId,
      title: title,
      description: description,
      thumbnailUrl: thumbnailUrl,
      channelName: channelName,
    );
  }

  /// Remove consecutive duplicate phrases from transcript text
  /// Uses sentence-level dedup with n-gram overlap detection
  String _deduplicateTranscript(String text) {
    // Split into sentence-like segments by punctuation or newlines
    final segments = text.split(RegExp(r'(?<=[.!?]\s)|(?<=[.!?]$)|(?<=\n)'));
    if (segments.isEmpty) return text;

    final List<String> deduped = [];
    // Keep a small window of recent sentences for comparison
    final recentWindow = <String>[];

    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i].trim();
      if (seg.isEmpty) continue;
      // Normalize whitespace within segment
      seg = seg.replaceAll(RegExp(r'\s+'), ' ').trim();

      // Skip if too short (likely noise)
      if (seg.length < 4) continue;

      // Check if this segment is too similar to any recent segment
      bool isDuplicate = false;
      for (final recent in recentWindow) {
        if (_isSimilar(seg, recent)) {
          isDuplicate = true;
          break;
        }
      }

      if (!isDuplicate) {
        deduped.add(seg);
        recentWindow.add(seg);
        // Keep window at 3 most recent segments
        if (recentWindow.length > 3) {
          recentWindow.removeAt(0);
        }
      }
    }

    return deduped.join(' ');
  }

  /// Check if two text segments are similar (>60% word overlap or one contains the other)
  bool _isSimilar(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;

    // Exact match or one contains the other
    if (a == b || a.contains(b) || b.contains(a)) return true;

    final wordsA = a.split(RegExp(r'\s+')).where((w) => w.length >= 2).toSet();
    final wordsB = b.split(RegExp(r'\s+')).where((w) => w.length >= 2).toSet();

    if (wordsA.isEmpty || wordsB.isEmpty) return false;

    final intersection = wordsA.intersection(wordsB).length;
    final minLen = wordsA.length < wordsB.length ? wordsA.length : wordsB.length;

    // >60% overlap or >70% of shorter text's words are in the other
    return (intersection / minLen) > 0.6;
  }

  /// Fetch video transcript from youtube-transcript.ai (free, no API key required)
  Future<String?> fetchTranscript(String videoId) async {
    try {
      final response = await http.get(
        Uri.parse('https://youtube-transcript.ai/transcript/$videoId.txt'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
        },
      );

      if (response.statusCode == 200) {
        var text = utf8.decode(response.bodyBytes);
        // Remove the metadata header (everything up to and including "## Transcript")
        final headerEnd = text.indexOf('## Transcript');
        if (headerEnd != -1) {
          text = text.substring(headerEnd + '## Transcript'.length).trim();
        }
        // Remove timestamps like [0:01]
        text = text.replaceAll(RegExp(r'\[\d+:\d+\]'), '');
        // Remove music note markers
        text = text.replaceAll('♪', '');
        // Collapse whitespace
        text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

        // Deduplicate repeated phrases
        text = _deduplicateTranscript(text);

        if (text.length > 4000) {
          text = text.substring(0, 4000);
        }
        return text.isNotEmpty ? text : null;
      }
    } catch (_) {}

    // Fallback: try alternative transcript service
    try {
      final response = await http.get(
        Uri.parse(
            'https://youtubetranscript.com/?v=$videoId&format=txt'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
        },
      );
      if (response.statusCode == 200) {
        var text = utf8.decode(response.bodyBytes).trim();
        // Also deduplicate fallback transcript
        text = _deduplicateTranscript(text);
        if (text.length > 4000) text = text.substring(0, 4000);
        return text.isNotEmpty ? text : null;
      }
    } catch (_) {}

    return null;
  }

  /// Get thumbnail URL for a video
  String getThumbnailUrl(String videoId, {String quality = 'medium'}) {
    switch (quality) {
      case 'default':
        return 'https://img.youtube.com/vi/$videoId/default.jpg';
      case 'medium':
        return 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
      case 'high':
        return 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
      case 'maxres':
        return 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
      default:
        return 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
    }
  }
}
