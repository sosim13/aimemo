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

  /// The memo id this history entry links to (if known).
  final int? memoId;

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
    this.memoId,
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
    int? memoId,
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
      memoId: memoId ?? this.memoId,
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

  /// The memo id this history entry produced (null for legacy records).
  final int? memoId;

  final DateTime createdAt;
  final DateTime? completedAt;

  /// 동기화용 사용자 식별자 (Supabase auth.users.id).
  /// 비로그인 상태에서 생성된 이력은 null.
  final String? userId;

  /// 최종 수정 시각 — Supabase와의 last-write-wins 충돌 해결에 사용.
  /// 로컬 DB에서는 TEXT(ISO 8601) 형태로 저장.
  final DateTime? updatedAt;

  /// 소프트 삭제 시각. null이면 활성 이력, 값이 있으면 삭제된 이력.
  final DateTime? deletedAt;

  ProcessingHistoryItem({
    this.id,
    required this.itemId,
    required this.content,
    required this.type,
    required this.status,
    this.progress = 1.0,
    this.error,
    this.memoTitle,
    this.memoId,
    DateTime? createdAt,
    this.completedAt,
    this.userId,
    this.updatedAt,
    this.deletedAt,
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
        'memoId': memoId,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'userId': userId,
        'updatedAt': updatedAt?.toIso8601String(),
        'deletedAt': deletedAt?.toIso8601String(),
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
      memoId: map['memoId'] as int?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      completedAt: map['completedAt'] != null
          ? DateTime.parse(map['completedAt'] as String)
          : null,
      userId: _parseNullableString(map['userId']),
      updatedAt: _parseDateTime(map['updatedAt']),
      deletedAt: _parseDateTime(map['deletedAt']),
    );
  }

  /// null 또는 빈 문자열 → null 반환 (String? 필드 안전 파싱용)
  static String? _parseNullableString(dynamic value) {
    if (value == null) return null;
    final s = value.toString();
    return s.isEmpty ? null : s;
  }

  /// TEXT 형태의 ISO 8601 날짜 문자열 → DateTime?. 빈 값/파싱 실패 시 null.
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    final s = value.toString();
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
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
