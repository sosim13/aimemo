/// Type of content to process
enum ContentType { url, text, image }

/// Processing stages for a queue item, ordered by progression.
/// Each stage maps to a percentage range for progress display.
enum ProcessingStage {
  /// Item is waiting in queue, not yet started
  queued(0.0, 0.0),

  /// Fetching external content (web page, YouTube transcript, etc.)
  fetchingContent(0.05, 0.20),

  /// AI is analyzing/summarizing the content
  analyzing(0.25, 0.75),

  /// Saving result to database
  saving(0.80, 0.90),

  /// Processing completed successfully
  completed(1.0, 1.0),

  /// Processing failed
  failed(1.0, 1.0);

  final double rangeStart;
  final double rangeEnd;
  const ProcessingStage(this.rangeStart, this.rangeEnd);

  /// Maximum progress achievable while in this stage
  double get maxProgress => rangeEnd;

  /// Minimum progress when entering this stage
  double get minProgress => rangeStart;

  /// Whether this stage represents a terminal (done) state
  bool get isCompleted => this == ProcessingStage.completed || this == ProcessingStage.failed;
}

/// Localized status label for each stage
String stageLabel(ProcessingStage stage, ContentType type) {
  switch (stage) {
    case ProcessingStage.queued:
      return '대기 중';
    case ProcessingStage.fetchingContent:
      return switch (type) {
        ContentType.url => '링크 분석 중',
        ContentType.text => '텍스트 분석 중',
        ContentType.image => '이미지 분석 중',
      };
    case ProcessingStage.analyzing:
      return 'AI 요약 중';
    case ProcessingStage.saving:
      return '저장 중';
    case ProcessingStage.completed:
      return '완료';
    case ProcessingStage.failed:
      return '실패';
  }
}

/// Per-item progress tracker
class QueueItemProgress {
  final String id;
  final String content;
  final ContentType type;
  final double progress; // 0.0 ~ 1.0
  final ProcessingStage stage;
  final String statusText;
  final bool isCurrent; // Currently being processed
  final String? error;
  final String? memoTitle; // Title of memo created (if success)

  /// When the item reached a terminal stage (completed/failed).
  /// null if still pending/processing.
  final DateTime? completedAt;

  const QueueItemProgress({
    required this.id,
    required this.content,
    required this.type,
    required this.progress,
    required this.stage,
    required this.statusText,
    this.isCurrent = false,
    this.error,
    this.memoTitle,
    this.completedAt,
  });

  QueueItemProgress copyWith({
    String? id,
    String? content,
    ContentType? type,
    double? progress,
    ProcessingStage? stage,
    String? statusText,
    bool? isCurrent,
    String? error,
    String? memoTitle,
    DateTime? completedAt,
  }) {
    return QueueItemProgress(
      id: id ?? this.id,
      content: content ?? this.content,
      type: type ?? this.type,
      progress: progress ?? this.progress,
      stage: stage ?? this.stage,
      statusText: statusText ?? this.statusText,
      isCurrent: isCurrent ?? this.isCurrent,
      error: error ?? this.error,
      memoTitle: memoTitle ?? this.memoTitle,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  /// Content preview (truncated for display)
  String get displayPreview {
    final maxLen = 80;
    final clean = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}...';
  }

  /// Type icon
  String get typeEmoji => switch (type) {
        ContentType.url => '🔗',
        ContentType.text => '📝',
        ContentType.image => '🖼️',
      };
}

/// Persisted processing history record stored in SQLite.
class ProcessingHistoryItem {
  final int? id;
  final String itemId;
  final String content;
  final ContentType type;
  final String status; // 'completed' | 'failed'
  final double progress;
  final String? error;
  final String? memoTitle;
  final DateTime createdAt;
  final DateTime? completedAt;

  ProcessingHistoryItem({
    this.id,
    required this.itemId,
    required this.content,
    required this.type,
    required this.status,
    this.progress = 1.0,
    this.error,
    this.memoTitle,
    DateTime? createdAt,
    this.completedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'itemId': itemId,
        'content': content,
        'type': switch (type) {
          ContentType.url => 'url',
          ContentType.text => 'text',
          ContentType.image => 'image',
        },
        'status': status,
        'progress': progress,
        'error': error,
        'memoTitle': memoTitle,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
      };

  factory ProcessingHistoryItem.fromMap(Map<String, dynamic> map) {
    return ProcessingHistoryItem(
      id: map['id'] as int?,
      itemId: map['itemId'] as String,
      content: map['content'] as String,
      type: switch (map['type'] as String) {
        'url' => ContentType.url,
        'image' => ContentType.image,
        _ => ContentType.text,
      },
      status: map['status'] as String,
      progress: (map['progress'] as num?)?.toDouble() ?? 1.0,
      error: map['error'] as String?,
      memoTitle: map['memoTitle'] as String?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      completedAt: map['completedAt'] != null
          ? DateTime.parse(map['completedAt'] as String)
          : null,
    );
  }
}

/// Full queue state emitted on every change
class QueueState {
  final List<QueueItemProgress> items;
  final bool isProcessing;
  final int pendingCount;
  final int completedCount;
  final int failedCount;

  const QueueState({
    required this.items,
    required this.isProcessing,
    required this.pendingCount,
    this.completedCount = 0,
    this.failedCount = 0,
  });

  int get totalCount => items.length;

  QueueItemProgress? get currentItem =>
      items.where((i) => i.isCurrent).firstOrNull;
}
