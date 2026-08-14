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
import 'geocoding_service.dart';
import 'naver_coord_service.dart';
import 'sync_service.dart';
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

  const ProcessingResult({required this.success, this.title, this.error});
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
  final _syncService = SyncService();

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

  /// Last emitted active-item stage — used to detect progress updates that
  /// would otherwise be filtered out by the history-change guard below.
  ProcessingStage? _lastEmittedActiveStage;

  /// Current stage of the item being processed (for progress tracking).
  ProcessingStage _currentStage = ProcessingStage.queued;

  /// Current progress (0.0–1.0) of the item being processed.
  double _currentProgress = 0.0;

  /// Status label for the current processing stage.
  String _currentStatusText = '처리 중';

  /// ── Retry tracking (independent of the main queue) ──

  /// The memo currently being retried (null if idle).
  Memo? _retryingMemo;

  /// Current stage of the retry operation.
  ProcessingStage _retryStage = ProcessingStage.queued;

  /// Current progress (0.0–1.0) of the retry.
  double _retryProgress = 0.0;

  /// Status label for the retry stage.
  String _retryStatusText = '';

  /// Last emitted retry stage — used by [loadHistoryIntoState] to detect change.
  ProcessingStage? _lastEmittedRetryStage;

  /// Last emitted retry queue length — detects new queued retries.
  int _lastRetryQueueLength = 0;

  /// Last emitted retrying memo id — 재요약 시작(null→id)/완료(id→null) 전이 감지.
  ///
  /// 재요약이 완료되어도 처리 기록 저장(_saveRetryHistory)이 실패하는 등의 이유로
  /// history가 변하지 않으면 dedup 로직이 상태를 재방출하지 않아 UI가
  /// 80%(저장 중)에 멈춰있게 된다. 이 필드로 retry active 전이를 감지하여
  /// 재요약 종료 시 반드시 상태를 갱신한다.
  int? _lastEmittedRetryingMemoId;

  /// Queue of memos awaiting retry (processed sequentially to avoid concurrent
  /// AI inference which would crash the local model / corrupt shared fields).
  final List<Memo> _retryQueue = [];
  bool _isRetryLock = false;

  /// Set when the user explicitly cancels the current operation.
  /// Checked by [processItem] and [cancelCurrentItem] to avoid double-saving.
  bool _userCancelled = false;

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

  /// Cancel only the currently processing item or retry.
  /// 대기중인 나머지 큐는 유지하고, 현재 처리중인 건 1개만 취소한다.
  /// 취소된 건은 실패 처리하여 처리 기록에 남기고, 필요시 재시도 가능.
  Future<void> cancelCurrentItem() async {
    _userCancelled = true;

    // 1. Abort the LLM provider (현재 처리중인 inference 즉시 중단)
    //    이 호출로 인해 진행중이던 processItem / _processSingleRetry는
    //    예외를 던지거나 빈 결과를 반환하며 종료된다.
    //    큐에 남은 다음 항목은 _processNext / retryMemo가 자연스럽게 이어받는다.
    _llmService.cancel();

    // 2. 메모리 큐에서 처리중인 건 1건만 실패 처리
    //    _queue 자체는 clear하지 않는다 — 대기중인 항목은 계속 처리.
    if (_currentItem != null && _currentItemId != null) {
      await _saveHistory(
        itemId: _currentItemId!,
        content: _currentItem!.content,
        type: _currentItem!.type,
        status: 'failed',
        error: '사용자가 처리를 취소했습니다.',
      );
      _currentItem = null;
      _currentItemId = null;
      _currentStage = ProcessingStage.queued;
      _currentProgress = 0.0;
      _currentStatusText = '';
    }

    // 3. 현재 재시도중인 건 1건만 실패 처리
    //    _retryQueue는 유지 — retryMemo의 try/finally가 이어서 다음 retry를
    //    자연스럽게 진행한다. _isRetryLock은 건드리지 않는다.
    if (_retryingMemo != null) {
      await _saveRetryHistory(
        memo: _retryingMemo!,
        status: 'failed',
        error: '사용자가 처리를 취소했습니다.',
      );
      // _retryingMemo는 retryMemo의 finally에서 null로 리셋하므로 여기서 건드리지 않음
    }

    // 4. native 큐에서 현재 처리중인 첫 번째 건만 제거
    //    (나머지 대기중인 항목은 유지하여 backgroundMain이 계속 처리)
    try {
      final pending = await BackgroundQueueService().getPendingItems();
      if (pending.isNotEmpty) {
        await BackgroundQueueService().removeById(pending.first.id);
      }
    } catch (_) {}

    // 5. 메모리 큐에 남은 대기항목이 있고, 처리 루프가 멈춰있다면 재개
    if (_queue.isNotEmpty && !_isProcessing) {
      _processNext();
    }

    _emitQueueState();
  }

  Future<ProcessingResult> processItem(
    ProcessingItem item, {
    String? itemId,
  }) async {
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
      // If the user explicitly cancelled, skip saving (cancelCurrentItem
      // already saved the failed entry) and avoid noisy logs.
      if (_userCancelled) {
        _userCancelled = false;
        await _debug.log('CPS: Processing cancelled by user');
        final result = ProcessingResult(
          success: false,
          error: '사용자가 처리를 취소했습니다.',
        );
        _resultController.add(result);
        _emitQueueState();
        return result;
      }

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
    int? memoId,
  }) async {
    try {
      await _databaseService.insertProcessingHistory(
        ProcessingHistoryItem(
          itemId: itemId,
          content: content,
          type: type,
          status: status,
          progress: status == 'completed' ? 1.0 : 0.0,
          error: error,
          memoTitle: memoTitle,
          memoId: memoId,
          completedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      await _debug.log('CPS: Failed to save history: $e');
    }
  }

  /// Persist a retry result to the processing history DB.
  /// Each retry gets a unique itemId so multiple retries of the same memo
  /// each appear as separate history entries.
  Future<void> _saveRetryHistory({
    required Memo memo,
    required String status,
    String? error,
  }) async {
    try {
      await _databaseService.insertProcessingHistory(
        ProcessingHistoryItem(
          itemId: _uuid.v4(),
          content: memo.title,
          type: _memoContentType(memo),
          status: status,
          progress: status == 'completed' ? 1.0 : 0.0,
          error: error,
          memoTitle: memo.title,
          memoId: memo.id,
          completedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      await _debug.log('CPS: Failed to save retry history: $e');
    }
  }

  /// Load processing history from DB plus native queue pending items,
  /// then emit updated state so the UI reflects current queue status.
  Future<void> loadHistoryIntoState() async {
    try {
      // 1. Load completed/failed history from DB
      final history = await _databaseService.getAllProcessingHistory();
      final historyItems = history.map(
        (h) => QueueItemProgress(
          id: h.itemId,
          content: h.content,
          type: h.type,
          progress: 1.0,
          stage:
              h.status == 'completed'
                  ? ProcessingStage.completed
                  : ProcessingStage.failed,
          statusText: h.status == 'completed' ? '완료' : '실패',
          isCurrent: false,
          error: h.error,
          memoTitle: h.memoTitle,
          memoId: h.memoId,
          completedAt: h.completedAt,
        ),
      );
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
            nativeActiveItems.add(
              QueueItemProgress(
                id: n.id,
                content: n.content,
                type: _nativeTypeToContentType(
                  n.type.name,
                ), // BackgroundQueueType → ContentType
                progress: isCurrent ? 0.3 : 0.0,
                stage: ProcessingStage.queued,
                statusText: isCurrent ? '처리 중' : '대기 중',
                isCurrent: isCurrent,
              ),
            );
          }
        }
      } catch (_) {
        // Native channel may not be available; fall through
      }

      // 3. Merge: native active items + in-memory queue + retry + history
      final combined = [
        ...nativeActiveItems,
        ..._buildActiveItemsFromMemory(),
        ..._buildRetryItems(),
        ...historyList,
      ];

      final completedCount =
          historyList.where((h) => h.stage == ProcessingStage.completed).length;
      final failedCount =
          historyList.where((h) => h.stage == ProcessingStage.failed).length;

      final isProcessing =
          nativeActiveItems.isNotEmpty ||
          _currentItem != null ||
          _queue.isNotEmpty ||
          _retryingMemo != null ||
          _retryQueue.isNotEmpty;

      // 4. Emit only if something changed
      final newHistoryOnly = historyList;
      final activeStageChanged =
          _currentItem != null && _currentStage != _lastEmittedActiveStage;
      final retryStageChanged =
          _retryingMemo != null && _retryStage != _lastEmittedRetryStage;
      // 재요약 시작/완료/큐 변동 전이 감지 (retry active id + 대기 큐 길이)
      final retryListChanged =
          (_retryingMemo?.id) != _lastEmittedRetryingMemoId ||
              _retryQueue.length != _lastRetryQueueLength;
      if (!_listEquals(newHistoryOnly, _historyFromDb) ||
          nativeActiveItems.length != _lastNativePendingCount ||
          activeStageChanged ||
          retryStageChanged ||
          retryListChanged) {
        _historyFromDb = newHistoryOnly;
        _lastNativePendingCount = nativeActiveItems.length;
        _lastEmittedActiveStage = _currentStage;
        _lastEmittedRetryStage = _retryStage;
        _lastRetryQueueLength = _retryQueue.length;
        _lastEmittedRetryingMemoId = _retryingMemo?.id;
        if (!_stateController.isClosed) {
          _stateController.add(
            QueueState(
              items: combined,
              isProcessing: isProcessing,
              pendingCount: _queue.length + nativeCount,
              completedCount: completedCount,
              failedCount: failedCount,
            ),
          );
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
      items.add(
        QueueItemProgress(
          id: _currentItemId ?? _uuid.v4(),
          content: _currentItem!.content,
          type: _currentItem!.type,
          progress: _currentProgress,
          stage: _currentStage,
          statusText: _currentStatusText,
          isCurrent: true,
        ),
      );
    }
    for (final item in _queue) {
      items.add(
        QueueItemProgress(
          id: _uuid.v4(),
          content: item.content,
          type: item.type,
          progress: 0.0,
          stage: ProcessingStage.queued,
          statusText: '대기 중',
          isCurrent: false,
        ),
      );
    }
    return items;
  }

  /// Build active items for retry operations.
  /// Returns one entry for the currently-executing retry plus one per queued
  /// retry, so the QueueScreen shows the full retry pipeline.
  List<QueueItemProgress> _buildRetryItems() {
    final items = <QueueItemProgress>[];
    if (_retryingMemo == null && _retryQueue.isEmpty) return items;

    // Currently processing retry
    if (_retryingMemo != null) {
      final memo = _retryingMemo!;
      items.add(
        QueueItemProgress(
          id: 'retry-${memo.id}',
          content: memo.title,
          type: _memoContentType(memo),
          progress: _retryProgress,
          stage: _retryStage,
          statusText: _retryStatusText,
          isCurrent: true,
        ),
      );
    }

    // Queued retries (waiting their turn)
    for (final memo in _retryQueue) {
      items.add(
        QueueItemProgress(
          id: 'retry-queued-${memo.id}',
          content: memo.title,
          type: _memoContentType(memo),
          progress: 0.0,
          stage: ProcessingStage.queued,
          statusText: '대기 중',
          isCurrent: false,
        ),
      );
    }
    return items;
  }

  ContentType _memoContentType(Memo memo) {
    if (memo.youtubeVideoId != null || memo.sourceUrl != null) {
      return ContentType.url;
    }
    if (memo.imagePath != null) return ContentType.image;
    return ContentType.text;
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

  /// Update the current item's stage/progress and emit immediately.
  /// Stage transitions are emitted at key processing milestones so the
  /// QueueScreen shows real-time progress (fetching → analyzing → saving).
  void _updateProgress(
    ProcessingStage stage,
    String statusText, {
    double? progress,
  }) {
    _currentStage = stage;
    _currentStatusText = statusText;
    _currentProgress = progress ?? stage.minProgress;
    _emitQueueState();
  }

  /// Update the retry operation's stage/progress and emit immediately.
  void _updateRetryProgress(
    ProcessingStage stage,
    String statusText, {
    double? progress,
  }) {
    if (_retryingMemo == null) return;
    _retryStage = stage;
    _retryStatusText = statusText;
    _retryProgress = progress ?? stage.minProgress;
    _emitQueueState();
  }

  /// Convenience: enqueue a URL for background processing.
  void enqueueUrl(String url) {
    enqueue(ProcessingItem(content: url, type: ContentType.url));
  }

  /// Convenience: enqueue plain text for AI analysis.
  void enqueueText(String text, {String? fallbackTitle}) {
    enqueue(
      ProcessingItem(
        content: text,
        type: ContentType.text,
        fallbackTitle: fallbackTitle,
      ),
    );
  }

  Future<void> _processNext() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      // Reset progress tracking for new item
      _currentItem = item;
      _currentItemId = _uuid.v4();
      _currentStage = ProcessingStage.fetchingContent;
      _currentProgress = ProcessingStage.fetchingContent.minProgress;
      _currentStatusText = stageLabel(
        ProcessingStage.fetchingContent,
        item.type,
      );
      _emitQueueState();
      await processItem(item, itemId: _currentItemId);
      // Clear current item and reset progress
      _currentItem = null;
      _currentItemId = null;
      _currentStage = ProcessingStage.queued;
      _currentProgress = 0.0;
      _currentStatusText = '';
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

    // Stage: fetchingContent (already set by _processNext)

    final videoInfo = await _youtubeService.getVideoInfo(videoId);
    if (videoInfo == null) {
      // Fallback: save raw URL
      return _saveFallback(url, '기타');
    }

    final transcript = await _youtubeService.fetchTranscript(videoId);
    final videoInfoWithTranscript = YouTubeVideoInfo(
      videoId: videoInfo.videoId,
      title: videoInfo.title,
      description: videoInfo.description,
      thumbnailUrl: videoInfo.thumbnailUrl,
      channelName: videoInfo.channelName,
      transcript: transcript,
    );

    final extractedContent = videoInfoWithTranscript.buildContentForAi();

    // Stage: analyzing — AI analysis
    _updateProgress(
      ProcessingStage.analyzing,
      'AI 요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    try {
      final result = await _aiService.analyzeContent(
        content: extractedContent,
        sourceUrl: url,
        youtubeVideoId: videoId,
      );

      // Stage: saving — persist to DB
      _updateProgress(ProcessingStage.saving, '저장 중');

      final title = result.title.isNotEmpty ? result.title : videoInfo.title;
      final searchKeyword =
          result.address.isEmpty
              ? extractSearchKeyword(
                result.content.isNotEmpty ? result.content : extractedContent,
              )
              : null;
      await _insertMemo(
        Memo(
          title: title,
          content:
              result.content.isNotEmpty ? result.content : extractedContent,
          category: result.category.isNotEmpty ? result.category : '기타',
          address: result.address.isNotEmpty ? result.address : null,
          searchKeyword: searchKeyword,
          sourceUrl: url,
          youtubeVideoId: videoId,
          thumbnailUrl: videoInfo.thumbnailUrl,
        ),
      );
      await _debug.log('CPS: YouTube memo saved');
      return title;
    } catch (e) {
      // AI failed — save with raw transcript data
      await _debug.log('CPS: YouTube AI failed ($e), saving fallback');
      _updateProgress(ProcessingStage.saving, '저장 중');
      final fallbackKeyword = extractSearchKeyword(extractedContent);
      await _insertMemo(
        Memo(
          title: videoInfo.title,
          content: extractedContent,
          category: '기타',
          searchKeyword: fallbackKeyword,
          sourceUrl: url,
          youtubeVideoId: videoId,
          thumbnailUrl: videoInfo.thumbnailUrl,
        ),
      );
      return videoInfo.title;
    }
  }

  Future<String> _processTikTok(String url) async {
    await _debug.log('CPS: TikTok URL: $url');

    // Stage: fetchingContent (already set by _processNext)

    final tiktokInfo = await _tiktokService.getVideoInfo(url);
    if (tiktokInfo == null) {
      return _saveFallback(url, '기타');
    }

    final extractedContent = tiktokInfo.buildContentForAi();

    // Stage: analyzing — AI analysis
    _updateProgress(
      ProcessingStage.analyzing,
      'AI 요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    try {
      final result = await _aiService.analyzeContent(
        content: extractedContent,
        sourceUrl: url,
      );

      // Stage: saving — persist to DB
      _updateProgress(ProcessingStage.saving, '저장 중');

      final title = result.title.isNotEmpty ? result.title : tiktokInfo.title;
      final searchKeyword =
          result.address.isEmpty
              ? extractSearchKeyword(
                result.content.isNotEmpty ? result.content : extractedContent,
              )
              : null;
      await _insertMemo(
        Memo(
          title: title,
          content:
              result.content.isNotEmpty ? result.content : extractedContent,
          category: result.category.isNotEmpty ? result.category : '기타',
          address: result.address.isNotEmpty ? result.address : null,
          searchKeyword: searchKeyword,
          sourceUrl: url,
          thumbnailUrl: tiktokInfo.thumbnailUrl,
        ),
      );
      await _debug.log('CPS: TikTok memo saved');
      return title;
    } catch (e) {
      await _debug.log('CPS: TikTok AI failed ($e), saving fallback');
      _updateProgress(ProcessingStage.saving, '저장 중');

      // Try to extract address from TikTok description as fallback
      String? fallbackAddress;
      final addressMatch = _roadAddressPattern.firstMatch(extractedContent);
      if (addressMatch != null) {
        fallbackAddress = addressMatch.group(0)!.trim();
      }
      if (fallbackAddress == null) {
        final landMatch = _landAddressPattern.firstMatch(extractedContent);
        if (landMatch != null) {
          fallbackAddress = landMatch.group(0)!.trim();
        }
      }

      final fallbackKeyword =
          fallbackAddress == null
              ? extractSearchKeyword(extractedContent)
              : null;

      await _insertMemo(
        Memo(
          title: tiktokInfo.title,
          content: extractedContent,
          category: '기타',
          address: fallbackAddress,
          searchKeyword: fallbackKeyword,
          sourceUrl: url,
          thumbnailUrl: tiktokInfo.thumbnailUrl,
        ),
      );
      return tiktokInfo.title;
    }
  }

  Future<String> _processWebPage(String url) async {
    await _debug.log('CPS: Web page: $url');

    // Stage: fetchingContent (already set by _processNext)

    String? extractedContent;
    String? pageTitle;

    // Try WebPageService first
    final pageInfo = await _webPageService.fetchPageContent(url);
    if (pageInfo != null && pageInfo.textContent.isNotEmpty) {
      pageTitle = pageInfo.title;
      extractedContent =
          '웹페이지 제목: ${pageInfo.title}\n'
          '설명: ${pageInfo.description}\n'
          '본문 내용:\n${pageInfo.textContent}';
    } else {
      // Fallback HTTP fetch
      try {
        final response = await http
            .get(
              Uri.parse(url),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                'Accept-Language': 'ko-KR,ko;q=0.9',
              },
            )
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
            extractedContent = [
              if (title.isNotEmpty) '[$title]',
              desc,
            ].where((s) => s.isNotEmpty).join(' ');
          }
        }
      } catch (_) {}
    }

    if (extractedContent == null || extractedContent.isEmpty) {
      return _saveFallback(url, '기타');
    }

    final finalTitle = pageTitle ?? url;
    final aiContent =
        extractedContent.length > 3000
            ? '${extractedContent.substring(0, 3000)}\n\n[...이하 생략...]'
            : extractedContent;

    // Stage: analyzing — AI analysis
    _updateProgress(
      ProcessingStage.analyzing,
      'AI 요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    try {
      final result = await _aiService.analyzeContent(
        content: aiContent,
        sourceUrl: url,
      );

      var finalContent =
          result.content.isNotEmpty ? result.content : extractedContent;
      var finalCategory = result.category.isNotEmpty ? result.category : '기타';

      // Check for AI echo
      if (result.content.isEmpty ||
          result.content.length > aiContent.length * 0.8) {
        await _debug.log('CPS: AI likely echoed input');
        finalContent =
            extractedContent.length > 500
                ? '${extractedContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.'
                : extractedContent;
        if (finalCategory == '기타' || finalCategory.isEmpty) {
          final detected = CategoryDetector.detect(extractedContent);
          if (detected != null) finalCategory = detected;
        }
      }

      // Stage: saving — persist to DB
      _updateProgress(ProcessingStage.saving, '저장 중');

      final title = result.title.isNotEmpty ? result.title : finalTitle;
      final searchKeyword =
          result.address.isEmpty
              ? extractSearchKeyword(
                result.content.isNotEmpty ? result.content : extractedContent,
              )
              : null;
      await _insertMemo(
        Memo(
          title: title,
          content: finalContent,
          category: finalCategory,
          address: result.address.isNotEmpty ? result.address : null,
          searchKeyword: searchKeyword,
          sourceUrl: url,
        ),
      );
      await _debug.log('CPS: Web memo saved');
      return title;
    } catch (e) {
      await _debug.log('CPS: Web AI failed ($e), saving fallback');
      _updateProgress(ProcessingStage.saving, '저장 중');
      final detected = CategoryDetector.detect(extractedContent);
      final truncated =
          extractedContent.length > 500
              ? '${extractedContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다.'
              : extractedContent;
      final fallbackKeyword = extractSearchKeyword(extractedContent);
      await _insertMemo(
        Memo(
          title: finalTitle,
          content: truncated,
          category: detected ?? '기타',
          searchKeyword: fallbackKeyword,
          sourceUrl: url,
        ),
      );
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
      final fallbackKeyword = extractSearchKeyword(content);
      await _insertMemo(
        Memo(
          title: item.fallbackTitle ?? '메모',
          content: content,
          category: item.fallbackCategory ?? '기타',
          searchKeyword: fallbackKeyword,
        ),
      );
      return item.fallbackTitle ?? '메모';
    }

    // Stage: analyzing — AI analysis
    _updateProgress(ProcessingStage.analyzing, 'AI 요약 중');

    try {
      final result = await _aiService.analyzeContent(content: content);

      // Stage: saving — persist to DB
      _updateProgress(ProcessingStage.saving, '저장 중');

      final title =
          result.title.isNotEmpty
              ? result.title
              : item.fallbackTitle ?? '제목 없음';
      final searchKeyword =
          result.address.isEmpty
              ? extractSearchKeyword(
                result.content.isNotEmpty ? result.content : content,
              )
              : null;
      await _insertMemo(
        Memo(
          title: title,
          content: result.content.isNotEmpty ? result.content : content,
          category: result.category.isNotEmpty ? result.category : '기타',
          address: result.address.isNotEmpty ? result.address : null,
          searchKeyword: searchKeyword,
        ),
      );
      await _debug.log('CPS: Text memo saved via AI');
      return title;
    } catch (e) {
      await _debug.log('CPS: Text AI failed ($e), saving raw');
      _updateProgress(ProcessingStage.saving, '저장 중');
      final fallbackKeyword = extractSearchKeyword(content);
      await _insertMemo(
        Memo(
          title: item.fallbackTitle ?? '메모',
          content: content,
          category: item.fallbackCategory ?? '기타',
          searchKeyword: fallbackKeyword,
        ),
      );
      return item.fallbackTitle ?? '메모';
    }
  }

  // ---------------------------------------------------------------------------
  // Image processing (OCR via native ML Kit)
  // ---------------------------------------------------------------------------

  Future<String> _processImage(String imageUri) async {
    await _debug.log('CPS: Processing image: $imageUri');

    // Stage: fetchingContent (already set by _processNext) — OCR is the "fetch" phase

    final queue = BackgroundQueueService();
    final ocrResult = await queue.performOcr(imageUri);
    final localImagePath = ocrResult.localImagePath;

    if (ocrResult.text != null && ocrResult.text!.isNotEmpty) {
      await _debug.log('CPS: OCR found text (${ocrResult.text!.length} chars)');

      if (await _llmService.isAvailable()) {
        // Stage: analyzing — AI analysis
        _updateProgress(ProcessingStage.analyzing, 'AI 요약 중');
        try {
          final result = await _aiService.analyzeContent(
            content: ocrResult.text!,
          );
          // Stage: saving — persist to DB
          _updateProgress(ProcessingStage.saving, '저장 중');
          final title = result.title.isNotEmpty ? result.title : '이미지 메모';
          final searchKeyword =
              result.address.isEmpty
                  ? extractSearchKeyword(
                    result.content.isNotEmpty
                        ? result.content
                        : ocrResult.text!,
                  )
                  : null;
          await _insertMemo(
            Memo(
              title: title,
              content:
                  result.content.isNotEmpty ? result.content : ocrResult.text!,
              category: result.category.isNotEmpty ? result.category : '기타',
              address: result.address.isNotEmpty ? result.address : null,
              searchKeyword: searchKeyword,
              imagePath: localImagePath,
            ),
          );
          await _debug.log('CPS: Image OCR memo saved via AI');
          return title;
        } catch (e) {
          await _debug.log('CPS: Image AI failed ($e), saving OCR text');
        }
      }

      _updateProgress(ProcessingStage.saving, '저장 중');
      final ocrFallbackKeyword = extractSearchKeyword(ocrResult.text!);
      await _insertMemo(
        Memo(
          title: '이미지 메모',
          content: ocrResult.text!,
          category: '기타',
          searchKeyword: ocrFallbackKeyword,
          imagePath: localImagePath,
        ),
      );
      return '이미지 메모';
    }

    await _debug.log('CPS: No text found in image');
    _updateProgress(ProcessingStage.saving, '저장 중');
    await _insertMemo(
      Memo(
        title: '이미지 메모',
        content: '📷 이미지가 공유되었습니다.\n\n이 이미지에서 인식된 텍스트가 없습니다.',
        category: '기타',
        imagePath: localImagePath,
      ),
    );
    return '이미지 메모';
  }

  /// Supabase 동기화 예약 — fire-and-forget.
  ///
  /// 메모 저장이 끝난 뒤 호출되며, 동기화 실패/예외가 절대 메모 저장 결과를
  /// 실패로 바꾸지 않도록 모든 예외를 삼킨다.
  /// (비로그인 또는 Supabase 미초기화 환경에서는 내부적으로 no-op)
  void _syncMemo(Memo memo) {
    try {
      _syncService.debouncePushMemo(memo);
    } catch (e) {
      unawaited(_debug.log('CPS: Sync push 예약 실패 (무시): $e'));
    }
  }

  Future<String> _saveFallback(String url, String category) async {
    final memo = Memo(
      title: url,
      content: 'URL: $url',
      category: category,
      sourceUrl: url,
    );
    final id = await _databaseService.insertMemo(memo);
    final saved = memo.copyWith(id: id);
    await _tryGeocode(saved);
    _syncMemo(saved);
    return url;
  }

  // ---------------------------------------------------------------------------
  // Address geocoding (post-processing after memo save)
  // ---------------------------------------------------------------------------

  /// Insert a memo into DB and trigger address geocoding.
  /// Geocoding is awaited so coordinates are guaranteed to be saved
  /// before the caller continues (important for background isolate).
  Future<int> _insertMemo(Memo memo) async {
    final id = await _databaseService.insertMemo(memo);
    final saved = memo.copyWith(id: id);
    await _tryGeocode(saved);
    _syncMemo(saved);
    return id;
  }

  /// Update a memo in DB and trigger address geocoding
  /// if it doesn't already have coordinates.
  Future<void> _updateMemo(Memo memo) async {
    await _databaseService.updateMemo(memo);
    if (!memo.hasCoordinates) {
      await _tryGeocode(memo);
    }
    _syncMemo(memo);
  }

  /// Regex to match Korean road address patterns (도로명 주소).
  /// Examples: "서울특별시 강남구 테헤란로 123", "경기 성남시 판교역로 235-7"
  static final RegExp _roadAddressPattern = RegExp(
    r'(?:서울|경기|인천|강원|충북|충남|충청|대전|경북|경남|경상|대구|전북|전남|전라|광주|부산|울산|제주|세종)'
    r'(?:특별시|광역시|도)?\s*'
    r'(?:[가-힣0-9]*(?:시|군|구)\s*)?'
    r'(?:[가-힣0-9]*(?:동|읍|면)\s*)?'
    r'(?:[가-힣0-9]*(?:로|길|대로))'
    r'\s*\d+[가-힣\d\-]*',
  );

  /// Regex to match Korean lot number address patterns (지번 주소).
  /// Examples: "서울 강남구 역삼동 123-4", "경기도 성남시 분당구 정자동 45"
  static final RegExp _landAddressPattern = RegExp(
    r'(?:서울|경기|인천|강원|충북|충남|충청|대전|경북|경남|경상|대구|전북|전남|전라|광주|부산|울산|제주|세종)'
    r'(?:특별시|광역시|도)?\s*'
    r'(?:[가-힣0-9]*(?:시|군|구)\s*)'
    r'(?:[가-힣0-9]*(?:동|읍|면)\s*)'
    r'\d+[가-힣\d\-]*',
  );

  /// Regex to extract [region + business type] search keywords from content.
  /// Used as fallback when no address is found.
  /// Examples: "신림 맛집", "강남역 카페", "판교 돈까스"
  static final RegExp searchKeywordPattern = RegExp(
    r'([가-힣]{2,}(?:역|입구|사거리|오거리)?)\s*'
    r'(맛집|카페|식당|음식점|술집|호프|주점|바|펍|찻집|제과점|빵집|분식|치킨|피자|국수|냉면|돈까스|초밥|구이|찜|탕|찌개|볶음|전|족발|닭발|파스타|샐러드|버거|샌드위치|떡볶이|순대|만두|고기|해산물|회|포장마차|포차|맛집)',
  );

  /// Extract a map search keyword ("[region] [business type]") when no address
  /// can be found in the content.
  static String? extractSearchKeyword(String content) {
    final match = searchKeywordPattern.firstMatch(content);
    if (match != null) {
      final region = match.group(1)!.trim();
      final business = match.group(2)!.trim();
      return '$region $business';
    }
    return null;
  }

  /// Try to extract an address from [content] and geocode it.
  /// Uses the stored [address] field first (from AI analysis), then falls back
  /// to regex pattern matching (도로명 주소 → 지번 주소), then falls back
  /// to search keyword → Kakao keyword search.
  /// Updates the memo in DB if coordinates are found.
  Future<void> _tryGeocode(Memo memo) async {
    // Skip if already has coordinates
    if (memo.hasCoordinates) {
      await _debug.log(
        'Geocode: memo id=${memo.id} already has coordinates, skipping',
      );
      return;
    }

    GeocodingResult? geoResult;

    // PRIORITY 1: Use the stored address from AI analysis (most reliable)
    if (memo.hasAddress) {
      await _debug.log(
        'Geocode: Using stored address from AI for memo id=${memo.id}: "${memo.address}"',
      );
      geoResult = await GeocodingService().searchAddress(memo.address!);
    }

    // PRIORITY 2: Fall back to regex pattern matching on title+content
    if (geoResult == null) {
      final searchText = '${memo.title}\n${memo.content}';
      String? foundAddress;

      // Try 도로명 주소 first
      final roadMatch = _roadAddressPattern.firstMatch(searchText);
      if (roadMatch != null) {
        foundAddress = roadMatch.group(0)!.trim();
        await _debug.log(
          'Geocode: Found road address via regex in memo id=${memo.id}: "$foundAddress"',
        );
        geoResult = await GeocodingService().searchAddress(foundAddress);
      }

      // Try 지번 주소 next
      if (geoResult == null) {
        final landMatch = _landAddressPattern.firstMatch(searchText);
        if (landMatch != null) {
          foundAddress = landMatch.group(0)!.trim();
          await _debug.log(
            'Geocode: Found land address via regex in memo id=${memo.id}: "$foundAddress"',
          );
          geoResult = await GeocodingService().searchAddress(foundAddress);
        }
      }
    }

    // PRIORITY 3: Use search keyword → Kakao keyword search
    if (geoResult == null && memo.hasSearchKeyword) {
      await _debug.log(
        'Geocode: Using search keyword for memo id=${memo.id}: "${memo.searchKeyword}"',
      );
      geoResult = await GeocodingService().searchKeyword(memo.searchKeyword!);
    }

    if (geoResult == null) {
      await _debug.log(
        'Geocode: No address or keyword found for memo id=${memo.id}',
      );
      return;
    }

    // Call Naver coordinate conversion (optional, best-effort)
    NaverCoordResult? naverResult;
    try {
      naverResult = await NaverCoordService().wgs84ToUtmk(
        geoResult.lat,
        geoResult.lng,
      );
    } catch (e) {
      await _debug.log('Geocode: Naver coordinate conversion failed: $e');
    }

    // Update memo in DB with coordinates
    final updatedMemo = memo.copyWith(
      kakaoLat: geoResult.lat,
      kakaoLng: geoResult.lng,
      naverX: naverResult?.x ?? geoResult.lat,
      naverY: naverResult?.y ?? geoResult.lng,
      updatedAt: DateTime.now(),
    );
    await _databaseService.updateMemo(updatedMemo);
    await _debug.log(
      'Geocode: Updated memo id=${memo.id} with coord '
      '(${geoResult.lat}, ${geoResult.lng})',
    );
  }

  // ---------------------------------------------------------------------------
  // Retry — re-process an existing memo with AI and update in-place
  // ---------------------------------------------------------------------------

  /// Re-run AI analysis on an existing memo and update its title / content /
  /// category in the database. Returns the updated [Memo], or null if retry
  /// is not applicable (e.g. image-only with no text).
  ///
  /// Retries are processed **sequentially** via an internal queue. If another
  /// retry is already in progress, this call is queued and processed after the
  /// current one finishes. This prevents concurrent AI inference that would
  /// crash the local model and avoids shared-field corruption.
  ///
  /// On completion a [ProcessingResult] is emitted via [onItemProcessed] so
  /// HomeScreen (and other listeners) can refresh automatically.
  Future<Memo?> retryMemo(Memo memo) async {
    await _debug.log('CPS: Retrying memo id=${memo.id}');

    // If a retry is already running, queue this one for later.
    if (_isRetryLock) {
      await _debug.log('CPS: Retry busy — queuing memo id=${memo.id}');
      _retryQueue.add(memo);
      _emitQueueState(); // Immediately show the queued item in QueueScreen
      return null;
    }

    _isRetryLock = true;

    try {
      // Process all queued retries sequentially
      await _processSingleRetry(memo);
      while (_retryQueue.isNotEmpty) {
        final next = _retryQueue.removeAt(0);
        await _debug.log('CPS: Processing queued retry id=${next.id}');
        await _processSingleRetry(next);
      }
    } finally {
      _isRetryLock = false;
      _retryingMemo = null;
      _retryStage = ProcessingStage.queued;
      _retryProgress = 0.0;
      _retryStatusText = '';
      _emitQueueState();
    }
    return null;
  }

  /// Retry a failed history entry by re-queueing it for processing.
  /// If the history item has a [memoId], delegates to [retryMemo] to update
  /// the existing memo in-place. Otherwise enqueues as a brand-new item.
  void retryFromHistory(QueueItemProgress historyItem) {
    if (historyItem.memoId != null) {
      // Fetch the memo and trigger retry
      unawaited(_retryFromHistoryWithMemo(historyItem));
    } else {
      // No memoId — enqueue as fresh item
      enqueue(
        ProcessingItem(content: historyItem.content, type: historyItem.type),
      );
    }
  }

  Future<void> _retryFromHistoryWithMemo(QueueItemProgress historyItem) async {
    // If the item has a memoId, load the memo from DB and retry it in-place
    if (historyItem.memoId == null) return;
    final memo = await _databaseService.getMemoById(historyItem.memoId!);
    if (memo != null) {
      await retryMemo(memo);
    }
  }

  /// Execute one retry with progress tracking and result emission.
  Future<void> _processSingleRetry(Memo memo) async {
    _retryingMemo = memo;
    _retryStage = ProcessingStage.fetchingContent;
    _retryProgress = ProcessingStage.fetchingContent.minProgress;
    _retryStatusText = 'AI 재요약 중';
    _emitQueueState();

    try {
      Memo? updated;
      if (memo.youtubeVideoId != null && memo.sourceUrl != null) {
        updated = await _retryYouTube(memo, memo.sourceUrl!);
      } else if (memo.sourceUrl != null &&
          _tiktokService.isTikTokUrl(memo.sourceUrl!)) {
        updated = await _retryTikTok(memo, memo.sourceUrl!);
      } else if (memo.sourceUrl != null) {
        updated = await _retryUrl(memo, memo.sourceUrl!);
      } else if (memo.imagePath != null) {
        updated = await _retryImage(memo);
      } else {
        updated = await _retryText(memo);
      }

      // Persist retry result to history DB
      await _saveRetryHistory(
        memo: memo,
        status: updated != null ? 'completed' : 'failed',
      );

      if (updated != null && !_resultController.isClosed) {
        _resultController.add(
          ProcessingResult(success: true, title: updated.title),
        );
      }
    } catch (e, stack) {
      // If the user explicitly cancelled, skip saving (cancelCurrentItem
      // already saved the failed entry).
      if (_userCancelled) {
        _userCancelled = false;
        await _debug.log('CPS: Retry cancelled by user');
        if (!_resultController.isClosed) {
          _resultController.add(
            ProcessingResult(success: false, error: '사용자가 처리를 취소했습니다.'),
          );
        }
      } else {
        await _debug.log('CPS: Retry failed: $e\n$stack');

        await _saveRetryHistory(
          memo: memo,
          status: 'failed',
          error: e.toString(),
        );

        if (!_resultController.isClosed) {
          _resultController.add(
            ProcessingResult(success: false, error: e.toString()),
          );
        }
      }
    } finally {
      _retryingMemo = null;
      _retryStage = ProcessingStage.queued;
      _retryProgress = 0.0;
      _retryStatusText = '';
    }
  }

  Future<Memo> _retryYouTube(Memo memo, String url) async {
    final videoId = memo.youtubeVideoId!;

    // Stage: fetchingContent (already set in retryMemo)

    final videoInfo = await _youtubeService.getVideoInfo(videoId);
    if (videoInfo == null) return memo; // Keep original

    final transcript = await _youtubeService.fetchTranscript(videoId);
    final videoInfoWithTranscript = YouTubeVideoInfo(
      videoId: videoInfo.videoId,
      title: videoInfo.title,
      description: videoInfo.description,
      thumbnailUrl: videoInfo.thumbnailUrl,
      channelName: videoInfo.channelName,
      transcript: transcript,
    );

    final extractedContent = videoInfoWithTranscript.buildContentForAi();

    // Stage: analyzing — AI analysis
    _updateRetryProgress(
      ProcessingStage.analyzing,
      'AI 재요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    final result = await _aiService.analyzeContent(
      content: extractedContent,
      sourceUrl: url,
      youtubeVideoId: videoId,
    );

    // Stage: saving — persist to DB
    _updateRetryProgress(ProcessingStage.saving, '저장 중');

    final title = result.title.isNotEmpty ? result.title : videoInfo.title;
    final updated = memo.copyWith(
      title: title,
      content: result.content.isNotEmpty ? result.content : extractedContent,
      category: result.category.isNotEmpty ? result.category : '기타',
      address: result.address.isNotEmpty ? result.address : memo.address,
      thumbnailUrl: videoInfo.thumbnailUrl,
      updatedAt: DateTime.now(),
    );
    await _updateMemo(updated);
    return updated;
  }

  Future<Memo> _retryUrl(Memo memo, String url) async {
    // Try to fetch page content, fall back to AI on current content
    String? extractedContent;
    String? pageTitle;

    // Stage: fetchingContent (already set in retryMemo)

    final pageInfo = await _webPageService.fetchPageContent(url);
    if (pageInfo != null && pageInfo.textContent.isNotEmpty) {
      pageTitle = pageInfo.title;
      extractedContent =
          '웹페이지 제목: ${pageInfo.title}\n'
          '설명: ${pageInfo.description}\n'
          '본문 내용:\n${pageInfo.textContent}';
    }

    if (extractedContent == null || extractedContent.isEmpty) {
      // Fallback: use current memo content as AI input
      return _retryText(memo);
    }

    final aiContent =
        extractedContent.length > 3000
            ? '${extractedContent.substring(0, 3000)}\n\n[...이하 생략...]'
            : extractedContent;

    // Stage: analyzing — AI analysis
    _updateRetryProgress(
      ProcessingStage.analyzing,
      'AI 재요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    final result = await _aiService.analyzeContent(
      content: aiContent,
      sourceUrl: url,
    );

    var finalContent =
        result.content.isNotEmpty ? result.content : extractedContent;
    var finalCategory = result.category.isNotEmpty ? result.category : '기타';

    if (result.content.isEmpty ||
        result.content.length > aiContent.length * 0.8) {
      finalContent =
          extractedContent.length > 500
              ? '${extractedContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.'
              : extractedContent;
      if (finalCategory == '기타') {
        final detected = CategoryDetector.detect(extractedContent);
        if (detected != null) finalCategory = detected;
      }
    }

    // Stage: saving — persist to DB
    _updateRetryProgress(ProcessingStage.saving, '저장 중');

    final title = result.title.isNotEmpty ? result.title : (pageTitle ?? url);
    final updated = memo.copyWith(
      title: title,
      content: finalContent,
      category: finalCategory,
      address: result.address.isNotEmpty ? result.address : memo.address,
      updatedAt: DateTime.now(),
    );
    await _updateMemo(updated);
    return updated;
  }

  Future<Memo> _retryTikTok(Memo memo, String url) async {
    await _debug.log('CPS: Retry TikTok URL: $url');

    // Fetch fresh TikTok data via oEmbed
    final tiktokInfo = await _tiktokService.getVideoInfo(url);
    if (tiktokInfo == null) {
      // Fallback to text retry using existing memo content
      return _retryText(memo);
    }

    final extractedContent = tiktokInfo.buildContentForAi();

    // Stage: analyzing — AI analysis
    _updateRetryProgress(
      ProcessingStage.analyzing,
      'AI 재요약 중',
      progress: ProcessingStage.analyzing.minProgress,
    );

    try {
      final result = await _aiService.analyzeContent(
        content: extractedContent,
        sourceUrl: url,
      );

      // Stage: saving — persist to DB
      _updateRetryProgress(ProcessingStage.saving, '저장 중');

      final title = result.title.isNotEmpty ? result.title : tiktokInfo.title;
      final updated = memo.copyWith(
        title: title,
        content: result.content.isNotEmpty ? result.content : extractedContent,
        category: result.category.isNotEmpty ? result.category : memo.category,
        address: result.address.isNotEmpty ? result.address : memo.address,
        thumbnailUrl: tiktokInfo.thumbnailUrl,
        updatedAt: DateTime.now(),
      );
      await _updateMemo(updated);
      return updated;
    } catch (e) {
      await _debug.log('CPS: TikTok retry AI failed ($e), saving fallback');

      // Try regex-based address extraction from TikTok description as fallback
      String? fallbackAddress;
      final addressMatch = _roadAddressPattern.firstMatch(extractedContent);
      if (addressMatch != null) {
        fallbackAddress = addressMatch.group(0)!.trim();
      }
      if (fallbackAddress == null) {
        final landMatch = _landAddressPattern.firstMatch(extractedContent);
        if (landMatch != null) {
          fallbackAddress = landMatch.group(0)!.trim();
        }
      }

      _updateRetryProgress(ProcessingStage.saving, '저장 중');
      final updated = memo.copyWith(
        title: tiktokInfo.title,
        content: extractedContent,
        category: '기타',
        address: fallbackAddress ?? memo.address,
        thumbnailUrl: tiktokInfo.thumbnailUrl,
        updatedAt: DateTime.now(),
      );
      await _updateMemo(updated);
      return updated;
    }
  }

  Future<Memo> _retryText(Memo memo) async {
    final content = memo.content;
    if (!await _llmService.isAvailable()) return memo;

    // Stage: analyzing — AI analysis
    _updateRetryProgress(ProcessingStage.analyzing, 'AI 재요약 중');

    final result = await _aiService.analyzeContent(content: content);

    // Stage: saving — persist to DB
    _updateRetryProgress(ProcessingStage.saving, '저장 중');

    final title = result.title.isNotEmpty ? result.title : memo.title;
    final updated = memo.copyWith(
      title: title,
      content: result.content.isNotEmpty ? result.content : content,
      category: result.category.isNotEmpty ? result.category : memo.category,
      address: result.address.isNotEmpty ? result.address : memo.address,
      updatedAt: DateTime.now(),
    );
    await _updateMemo(updated);
    return updated;
  }

  Future<Memo> _retryImage(Memo memo) async {
    final imagePath = memo.imagePath!;
    final queue = BackgroundQueueService();

    // Stage: fetchingContent (already set in retryMemo) — OCR phase

    final ocrResult = await queue.performOcr(imagePath);

    if (ocrResult.text == null || ocrResult.text!.isEmpty) {
      return memo; // No text found, keep original
    }

    if (await _llmService.isAvailable()) {
      // Stage: analyzing — AI analysis
      _updateRetryProgress(ProcessingStage.analyzing, 'AI 재요약 중');

      final result = await _aiService.analyzeContent(content: ocrResult.text!);

      // Stage: saving — persist to DB
      _updateRetryProgress(ProcessingStage.saving, '저장 중');

      final title = result.title.isNotEmpty ? result.title : memo.title;
      final updated = memo.copyWith(
        title: title,
        content: result.content.isNotEmpty ? result.content : ocrResult.text!,
        category: result.category.isNotEmpty ? result.category : memo.category,
        address: result.address.isNotEmpty ? result.address : memo.address,
        updatedAt: DateTime.now(),
      );
      await _updateMemo(updated);
      return updated;
    }

    return memo;
  }

  /// Clean up resources.
  void dispose() {
    _refreshTimer?.cancel();
    _resultController.close();
    _stateController.close();
  }
}
