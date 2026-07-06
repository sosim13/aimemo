import 'dart:collection';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../models/memo.dart';
import '../models/queue_state.dart';
import 'background_queue_service.dart';
import 'database_service.dart';
import 'llm_service.dart';
import 'ai_service.dart';
import 'url_handler_service.dart';
import 'youtube_service.dart';
import 'tiktok_service.dart';
import 'web_page_service.dart';
import 'category_detector.dart';
import 'debug_logger.dart';

// Native queue type to ContentType mapping
ContentType _nativeTypeToContentType(String nativeType) {
  return switch (nativeType) {
    'url' => ContentType.url,
    'image' => ContentType.image,
    _ => ContentType.text,
  };
}

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

  /// Stream that emits queue state changes for UI (active + history items)
  final _stateController = StreamController<QueueState>.broadcast();
  Stream<QueueState> get queueState => _stateController.stream;

  /// The item currently being processed (null if idle).
  ProcessingItem? _currentItem;
  String? _currentItemId;

  /// Cached history items loaded from DB.
  List<QueueItemProgress> _historyFromDb = [];
  bool _historyLoaded = false;

  /// Last known count of pending items in the native queue, used to detect
  /// changes and avoid redundant state emissions.
  int _lastNativePendingCount = 0;

  /// Periodic timer that polls DB for new history entries.
  /// Background isolate writes to DB but cannot notify the main isolate directly,
  /// so we poll every 2 seconds to pick up new items.
  Timer? _refreshTimer;

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

  final _uuid = const Uuid();

  Future<ProcessingResult> processItem(ProcessingItem item,
      {String? itemId}) async {
    itemId ??= _uuid.v4();
    try {
      final title = switch (item.type) {
        ContentType.url => await _processUrl(item.content),
        ContentType.image => await _processImage(item.content),
        ContentType.text => await _processText(item),
      };
      final result = ProcessingResult(success: true, title: title);
      _resultController.add(result);

      // Persist to history DB
      await _saveHistory(
        itemId: itemId,
        content: item.content,
        type: item.type,
        status: 'completed',
        memoTitle: title,
      );

      // Refresh queue state
      _emitQueueState();

      return result;
    } catch (e, stack) {
      await _debug.log('CPS: Processing failed: $e\n$stack');
      final result = ProcessingResult(success: false, error: e.toString());
      _resultController.add(result);

      // Persist failure to history DB
      await _saveHistory(
        itemId: itemId,
        content: item.content,
        type: item.type,
        status: 'failed',
        error: e.toString(),
      );

      // Refresh queue state
      _emitQueueState();

      return result;
    }
  }

  /// Persist a processing result to the history database.
  Future<void> _saveHistory({
    required String itemId,
    required String content,
    required ContentType type,
    required String status,
    String? memoTitle,
    String? error,
  }) async {
    try {
      await _databaseService.insertProcessingHistory(ProcessingHistoryItem(
        itemId: itemId,
        content: content,
        type: type,
        status: status,
        progress: status == 'completed' ? 1.0 : 0.0,
        error: error,
        memoTitle: memoTitle,
        completedAt: DateTime.now(),
      ));
    } catch (e) {
      await _debug.log('CPS: Failed to save history: $e');
    }
  }

  /// Load processing history from DB plus native queue pending items,
  /// then emit updated state so the UI reflects current queue status.
  Future<void> loadHistoryIntoState() async {
    try {
      // 1. Load completed/failed history from DB
      final history = await _databaseService.getAllProcessingHistory();
      final historyItems = history.map((h) => QueueItemProgress(
            id: h.itemId,
            content: h.content,
            type: h.type,
            progress: 1.0,
            stage: h.status == 'completed'
                ? ProcessingStage.completed
                : ProcessingStage.failed,
            statusText: h.status == 'completed' ? '완료' : '실패',
            isCurrent: false,
            error: h.error,
            memoTitle: h.memoTitle,
            completedAt: h.completedAt,
          ));
      final historyList = historyItems.toList();

      // 2. Check native queue for items being processed or waiting
      //    (backgroundMain in a separate isolate processes them)
      List<QueueItemProgress> nativeActiveItems = [];
      var nativeCount = 0;
      try {
        final nativePending = await BackgroundQueueService().getPendingItems();
        nativeCount = nativePending.length;
        if (nativeCount > 0) {
          // First item is currently being processed, rest are waiting
          for (var i = 0; i < nativeCount; i++) {
            final n = nativePending[i];
            final isCurrent = i == 0;
            nativeActiveItems.add(QueueItemProgress(
              id: n.id,
              content: n.content,
              type: _nativeTypeToContentType(
                  n.type.name), // BackgroundQueueType → ContentType
              progress: isCurrent ? 0.3 : 0.0,
              stage: ProcessingStage.queued,
              statusText: isCurrent ? '처리 중' : '대기 중',
              isCurrent: isCurrent,
            ));
          }
        }
      } catch (_) {
        // Native channel may not be available; fall through
      }

      // 3. Merge: native active items + in-memory queue + history
      final combined = [
        ...nativeActiveItems,
        ..._buildActiveItemsFromMemory(),
        ...historyList,
      ];

      final completedCount =
          historyList.where((h) => h.stage == ProcessingStage.completed).length;
      final failedCount =
          historyList.where((h) => h.stage == ProcessingStage.failed).length;

      final isProcessing = nativeActiveItems.isNotEmpty ||
          _currentItem != null ||
          _queue.isNotEmpty;

      // 4. Emit only if something changed
      final newHistoryOnly = historyList;
      if (!_listEquals(newHistoryOnly, _historyFromDb) ||
          nativeActiveItems.length != _lastNativePendingCount) {
        _historyFromDb = newHistoryOnly;
        _lastNativePendingCount = nativeActiveItems.length;
        if (!_stateController.isClosed) {
          _stateController.add(QueueState(
            items: combined,
            isProcessing: isProcessing,
            pendingCount: _queue.length + nativeCount,
            completedCount: completedCount,
            failedCount: failedCount,
          ));
        }
      } else {
        _historyFromDb = newHistoryOnly;
      }
    } catch (e) {
      await _debug.log('CPS: Failed to load history: $e');
    }
  }

  /// Build active items from the in-memory queue (used when processing
  /// happens via [enqueue] instead of the native background service).
  List<QueueItemProgress> _buildActiveItemsFromMemory() {
    final items = <QueueItemProgress>[];
    if (_currentItem != null) {
      items.add(QueueItemProgress(
        id: _currentItemId ?? _uuid.v4(),
        content: _currentItem!.content,
        type: _currentItem!.type,
        progress: 0.0,
        stage: ProcessingStage.queued,
        statusText: '처리 중',
        isCurrent: true,
      ));
    }
    for (final item in _queue) {
      items.add(QueueItemProgress(
        id: _uuid.v4(),
        content: item.content,
        type: item.type,
        progress: 0.0,
        stage: ProcessingStage.queued,
        statusText: '대기 중',
        isCurrent: false,
      ));
    }
    return items;
  }

  /// Start a periodic timer that polls the DB for new history entries.
  /// Background processing happens in a separate Dart isolate, so we need
  /// to poll since the main isolate doesn't get automatic notifications.
  void startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      loadHistoryIntoState();
    });
  }

  /// Stop the periodic refresh timer.
  void stopPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Compare two lists of QueueItemProgress by their IDs and status.
  bool _listEquals(List<QueueItemProgress> a, List<QueueItemProgress> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
      if (a[i].stage != b[i].stage) return false;
    }
    return true;
  }

  /// Build and emit the current queue state.
  /// Delegates to [loadHistoryIntoState] which reads both DB history and
  /// native queue status for a complete picture.
  void _emitQueueState() {
    // Fire-and-forget: loadHistoryIntoState handles the full state emission
    loadHistoryIntoState();
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
      // Set current item and emit state so UI shows "processing"
      _currentItem = item;
      _currentItemId = _uuid.v4();
      _emitQueueState();
      await processItem(item, itemId: _currentItemId);
      // Clear current item
      _currentItem = null;
      _currentItemId = null;
    }

    _isProcessing = false;
    _emitQueueState();
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
        thumbnailUrl: videoInfo.thumbnailUrl,
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
        thumbnailUrl: videoInfo.thumbnailUrl,
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
        thumbnailUrl: tiktokInfo.thumbnailUrl,
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
        thumbnailUrl: tiktokInfo.thumbnailUrl,
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

  // ---------------------------------------------------------------------------
  // Image processing (OCR via native ML Kit)
  // ---------------------------------------------------------------------------

  Future<String> _processImage(String imageUri) async {
    await _debug.log('CPS: Processing image: $imageUri');

    final queue = BackgroundQueueService();
    final ocrResult = await queue.performOcr(imageUri);
    final localImagePath = ocrResult.localImagePath;

    if (ocrResult.text != null && ocrResult.text!.isNotEmpty) {
      await _debug.log('CPS: OCR found text (${ocrResult.text!.length} chars)');

      if (await _llmService.isAvailable()) {
        try {
          final result = await _aiService.analyzeContent(content: ocrResult.text!);
          final title = result.title.isNotEmpty
              ? result.title
              : '이미지 메모';
          await _databaseService.insertMemo(Memo(
            title: title,
            content: result.content.isNotEmpty ? result.content : ocrResult.text!,
            category: result.category.isNotEmpty ? result.category : '기타',
            imagePath: localImagePath,
          ));
          await _debug.log('CPS: Image OCR memo saved via AI');
          return title;
        } catch (e) {
          await _debug.log('CPS: Image AI failed ($e), saving OCR text');
        }
      }

      await _databaseService.insertMemo(Memo(
        title: '이미지 메모',
        content: ocrResult.text!,
        category: '기타',
        imagePath: localImagePath,
      ));
      return '이미지 메모';
    }

    await _debug.log('CPS: No text found in image');
    await _databaseService.insertMemo(Memo(
      title: '이미지 메모',
      content: '📷 이미지가 공유되었습니다.\n\n이 이미지에서 인식된 텍스트가 없습니다.',
      category: '기타',
      imagePath: localImagePath,
    ));
    return '이미지 메모';
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
    _refreshTimer?.cancel();
    _resultController.close();
    _stateController.close();
  }
}
