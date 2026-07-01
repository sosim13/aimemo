import 'dart:collection';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/memo.dart';
import 'database_service.dart';
import 'llm_service.dart';
import 'ai_service.dart';
import 'url_handler_service.dart';
import 'youtube_service.dart';
import 'tiktok_service.dart';
import 'web_page_service.dart';
import 'category_detector.dart';
import 'debug_logger.dart';

/// Type of content to process
enum ContentType { url, text }

/// An item waiting to be processed
class ProcessingItem {
  final String content;
  final ContentType type;

  /// Optional fallback values if AI analysis is used
  final String? fallbackTitle;
  final String? fallbackContent;
  final String? fallbackCategory;

  const ProcessingItem({
    required this.content,
    required this.type,
    this.fallbackTitle,
    this.fallbackContent,
    this.fallbackCategory,
  });
}

/// Result of processing a single item
class ProcessingResult {
  final bool success;
  final String? title;
  final String? error;

  const ProcessingResult({
    required this.success,
    this.title,
    this.error,
  });
}

/// Status of the queue
enum QueueStatus { idle, processing }

/// Service that processes shared content (URLs or text) sequentially in the
/// background. Completely independent of widget lifecycle — survives
/// app backgrounding, home button, etc.
class ContentProcessingService {
  static final ContentProcessingService _instance =
      ContentProcessingService._internal();
  factory ContentProcessingService() => _instance;
  ContentProcessingService._internal();

  final Queue<ProcessingItem> _queue = Queue();
  bool _isProcessing = false;

  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();
  final _webPageService = WebPageService();
  final _urlHandler = UrlHandlerService();
  final _aiService = AiService();
  final _llmService = LlmService();
  final _databaseService = DatabaseService();
  final _debug = DebugLogger();

  /// Stream that fires each time an item finishes processing.
  /// Listeners can use this to refresh UI or show notifications.
  final _resultController = StreamController<ProcessingResult>.broadcast();
  Stream<ProcessingResult> get onItemProcessed => _resultController.stream;

  /// Current queue depth (for UI badge etc.)
  int get pendingCount => _queue.length;
  QueueStatus get status =>
      _isProcessing ? QueueStatus.processing : QueueStatus.idle;

  /// Add an item to the processing queue. Processing starts automatically
  /// if the queue was idle.
  void enqueue(ProcessingItem item) {
    _queue.add(item);
    _processNext();
  }

  Future<ProcessingResult> processItem(ProcessingItem item) async {
    try {
      final title = item.type == ContentType.url
          ? await _processUrl(item.content)
          : await _processText(item);
      final result = ProcessingResult(success: true, title: title);
      _resultController.add(result);
      return result;
    } catch (e, stack) {
      await _debug.log('CPS: Processing failed: $e\n$stack');
      final result = ProcessingResult(success: false, error: e.toString());
      _resultController.add(result);
      return result;
    }
  }

  /// Convenience: enqueue a URL for background processing.
  void enqueueUrl(String url) {
    enqueue(ProcessingItem(content: url, type: ContentType.url));
  }

  /// Convenience: enqueue plain text for AI analysis.
  void enqueueText(String text, {String? fallbackTitle}) {
    enqueue(ProcessingItem(
      content: text,
      type: ContentType.text,
      fallbackTitle: fallbackTitle,
    ));
  }

  Future<void> _processNext() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      await processItem(item);
    }

    _isProcessing = false;
  }

  // ---------------------------------------------------------------------------
  // URL processing (YouTube / TikTok / Web)
  // ---------------------------------------------------------------------------

  Future<String> _processUrl(String url) async {
    await _debug.log('CPS: Processing URL: $url');
    final parsed = _urlHandler.parseUrl(url);

    if (parsed.isYouTube && parsed.youtubeVideoId != null) {
      return _processYouTube(parsed.youtubeVideoId!, url);
    } else if (parsed.isTikTok) {
      return _processTikTok(parsed.originalUrl);
    } else {
      return _processWebPage(url);
    }
  }

  Future<String> _processYouTube(String videoId, String url) async {
    await _debug.log('CPS: YouTube video: $videoId');
    final videoInfo = await _youtubeService.getVideoInfo(videoId);
    if (videoInfo == null) {
      // Fallback: save raw URL
      return _saveFallback(url, '기타');
    }

    final transcript =
        await _youtubeService.fetchTranscript(videoId);
    final videoInfoWithTranscript = YouTubeVideoInfo(
      videoId: videoInfo.videoId,
      title: videoInfo.title,
      description: videoInfo.description,
      thumbnailUrl: videoInfo.thumbnailUrl,
      channelName: videoInfo.channelName,
      transcript: transcript,
    );

    final extractedContent = videoInfoWithTranscript.buildContentForAi();

    try {
      final result = await _aiService.analyzeContent(
        content: extractedContent,
        sourceUrl: url,
        youtubeVideoId: videoId,
      );

      final title = result.title.isNotEmpty ? result.title : videoInfo.title;
      await _databaseService.insertMemo(Memo(
        title: title,
        content: result.content.isNotEmpty ? result.content : extractedContent,
        category: result.category.isNotEmpty ? result.category : '기타',
        sourceUrl: url,
        youtubeVideoId: videoId,
      ));
      await _debug.log('CPS: YouTube memo saved');
      return title;
    } catch (e) {
      // AI failed — save with raw transcript data
      await _debug.log('CPS: YouTube AI failed ($e), saving fallback');
      await _databaseService.insertMemo(Memo(
        title: videoInfo.title,
        content: extractedContent,
        category: '기타',
        sourceUrl: url,
        youtubeVideoId: videoId,
      ));
      return videoInfo.title;
    }
  }

  Future<String> _processTikTok(String url) async {
    await _debug.log('CPS: TikTok URL: $url');
    final tiktokInfo = await _tiktokService.getVideoInfo(url);
    if (tiktokInfo == null) {
      return _saveFallback(url, '기타');
    }

    final extractedContent = tiktokInfo.buildContentForAi();

    try {
      final result = await _aiService.analyzeContent(
        content: extractedContent,
        sourceUrl: url,
      );

      final title = result.title.isNotEmpty ? result.title : tiktokInfo.title;
      await _databaseService.insertMemo(Memo(
        title: title,
        content: result.content.isNotEmpty ? result.content : extractedContent,
        category: result.category.isNotEmpty ? result.category : '기타',
        sourceUrl: url,
      ));
      await _debug.log('CPS: TikTok memo saved');
      return title;
    } catch (e) {
      await _debug.log('CPS: TikTok AI failed ($e), saving fallback');
      await _databaseService.insertMemo(Memo(
        title: tiktokInfo.title,
        content: extractedContent,
        category: '기타',
        sourceUrl: url,
      ));
      return tiktokInfo.title;
    }
  }

  Future<String> _processWebPage(String url) async {
    await _debug.log('CPS: Web page: $url');

    String? extractedContent;
    String? pageTitle;

    // Try WebPageService first
    final pageInfo = await _webPageService.fetchPageContent(url);
    if (pageInfo != null && pageInfo.textContent.isNotEmpty) {
      pageTitle = pageInfo.title;
      extractedContent = '웹페이지 제목: ${pageInfo.title}\n'
          '설명: ${pageInfo.description}\n'
          '본문 내용:\n${pageInfo.textContent}';
    } else {
      // Fallback HTTP fetch
      try {
        final response = await http
            .get(Uri.parse(url), headers: {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              'Accept-Language': 'ko-KR,ko;q=0.9',
            })
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final html = utf8.decode(response.bodyBytes);
          final ogTitle = RegExp(
            r'''<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']''',
            caseSensitive: false,
          ).firstMatch(html);
          final ogDesc = RegExp(
            r'''<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']''',
            caseSensitive: false,
          ).firstMatch(html);

          final title = ogTitle?.group(1)?.trim() ?? '';
          final desc = ogDesc?.group(1)?.trim() ?? '';

          if (title.isNotEmpty || desc.isNotEmpty) {
            pageTitle = title;
            extractedContent = [if (title.isNotEmpty) '[$title]', desc]
                .where((s) => s.isNotEmpty)
                .join(' ');
          }
        }
      } catch (_) {}
    }

    if (extractedContent == null || extractedContent.isEmpty) {
      return _saveFallback(url, '기타');
    }

    final finalTitle = pageTitle ?? url;
    final aiContent = extractedContent.length > 3000
        ? '${extractedContent.substring(0, 3000)}\n\n[...이하 생략...]'
        : extractedContent;

    try {
      final result = await _aiService.analyzeContent(
        content: aiContent,
        sourceUrl: url,
      );

      var finalContent = result.content.isNotEmpty ? result.content : extractedContent;
      var finalCategory = result.category.isNotEmpty ? result.category : '기타';

      // Check for AI echo
      if (result.content.isEmpty || result.content.length > aiContent.length * 0.8) {
        await _debug.log('CPS: AI likely echoed input');
        finalContent = extractedContent.length > 500
            ? '${extractedContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.'
            : extractedContent;
        if (finalCategory == '기타' || finalCategory.isEmpty) {
          final detected = CategoryDetector.detect(extractedContent);
          if (detected != null) finalCategory = detected;
        }
      }

      final title = result.title.isNotEmpty ? result.title : finalTitle;
      await _databaseService.insertMemo(Memo(
        title: title,
        content: finalContent,
        category: finalCategory,
        sourceUrl: url,
      ));
      await _debug.log('CPS: Web memo saved');
      return title;
    } catch (e) {
      await _debug.log('CPS: Web AI failed ($e), saving fallback');
      final detected = CategoryDetector.detect(extractedContent);
      final truncated = extractedContent.length > 500
          ? '${extractedContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다.'
          : extractedContent;
      await _databaseService.insertMemo(Memo(
        title: finalTitle,
        content: truncated,
        category: detected ?? '기타',
        sourceUrl: url,
      ));
      return finalTitle;
    }
  }

  // ---------------------------------------------------------------------------
  // Plain text AI analysis
  // ---------------------------------------------------------------------------

  Future<String> _processText(ProcessingItem item) async {
    final content = item.content;
    await _debug.log('CPS: Processing text (${content.length} chars)');

    if (!await _llmService.isAvailable()) {
      // No AI — save raw
      await _databaseService.insertMemo(Memo(
        title: item.fallbackTitle ?? '메모',
        content: content,
        category: item.fallbackCategory ?? '기타',
      ));
      return item.fallbackTitle ?? '메모';
    }

    try {
      final result = await _aiService.analyzeContent(content: content);

      final title = result.title.isNotEmpty
          ? result.title
          : item.fallbackTitle ?? '제목 없음';
      await _databaseService.insertMemo(Memo(
        title: title,
        content: result.content.isNotEmpty ? result.content : content,
        category: result.category.isNotEmpty ? result.category : '기타',
      ));
      await _debug.log('CPS: Text memo saved via AI');
      return title;
    } catch (e) {
      await _debug.log('CPS: Text AI failed ($e), saving raw');
      await _databaseService.insertMemo(Memo(
        title: item.fallbackTitle ?? '메모',
        content: content,
        category: item.fallbackCategory ?? '기타',
      ));
      return item.fallbackTitle ?? '메모';
    }
  }

  Future<String> _saveFallback(String url, String category) async {
    await _databaseService.insertMemo(Memo(
      title: url,
      content: 'URL: $url',
      category: category,
      sourceUrl: url,
    ));
    return url;
  }

  /// Clean up resources.
  void dispose() {
    _resultController.close();
  }
}
