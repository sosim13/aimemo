/// Lifecycle states for a [ReadingSession].
enum ReadingSessionStatus {
  reading,
  paused,
  completed;

  String get label {
    switch (this) {
      case ReadingSessionStatus.reading:
        return 'READING';
      case ReadingSessionStatus.paused:
        return 'PAUSED';
      case ReadingSessionStatus.completed:
        return 'COMPLETED';
    }
  }

  static ReadingSessionStatus fromString(String raw) {
    switch (raw) {
      case 'READING':
        return ReadingSessionStatus.reading;
      case 'PAUSED':
        return ReadingSessionStatus.paused;
      case 'COMPLETED':
        return ReadingSessionStatus.completed;
      default:
        return ReadingSessionStatus.reading;
    }
  }
}

/// A single continuous reading attempt for a [Book].
///
/// A book can have multiple sessions — `readRound` is 1 for the first read,
/// 2 for the second (re-read), etc. Active reading time accumulates across
/// pause/resume cycles within the same session via [accumulatedActiveTime].
///
/// 동기화 관련 필드 (Supabase):
/// - [userId]: 동기화용 현재 로그인 사용자 식별자 (user_id)
/// - [updatedAt]: last-write-wins 충돌 해결용 최종 수정 시각
/// - [deletedAt]: 소프트 삭제(soft delete) 시각. null이면 활성 상태.
class ReadingSession {
  final String sessionId;
  final String bookId;

  /// 1-based: 1st read, 2nd read, etc.
  final int readRound;

  /// When the reading session first started.
  final DateTime firstStartDate;

  /// Set when the user taps "독서 종료". Null while reading/paused.
  final DateTime? completedDate;

  /// Total active reading time, in seconds, accumulated across all
  /// pause/resume cycles of this session.
  final int accumulatedActiveTime;

  /// Current lifecycle state of the session.
  final ReadingSessionStatus status;

  /// 동기화용 사용자 식별자 (Supabase auth.users.id).
  /// 비로그인 상태에서 생성된 세션은 null.
  final String? userId;

  /// 최종 수정 시각 — Supabase와의 last-write-wins 충돌 해결에 사용.
  /// 로컬 DB에서는 TEXT(ISO 8601) 형태로 저장.
  final DateTime? updatedAt;

  /// 소프트 삭제 시각. null이면 활성 세션, 값이 있으면 삭제된 세션.
  final DateTime? deletedAt;

  ReadingSession({
    required this.sessionId,
    required this.bookId,
    required this.readRound,
    required this.firstStartDate,
    this.completedDate,
    required this.accumulatedActiveTime,
    required this.status,
    this.userId,
    this.updatedAt,
    this.deletedAt,
  });

  /// True when [status] is [ReadingSessionStatus.completed].
  bool get isCompleted => status == ReadingSessionStatus.completed;

  /// True when [status] is [ReadingSessionStatus.reading] or
  /// [ReadingSessionStatus.paused] — i.e. the book is still being read.
  bool get isInProgress =>
      status == ReadingSessionStatus.reading ||
      status == ReadingSessionStatus.paused;

  ReadingSession copyWith({
    String? sessionId,
    String? bookId,
    int? readRound,
    DateTime? firstStartDate,
    DateTime? completedDate,
    int? accumulatedActiveTime,
    ReadingSessionStatus? status,
    String? userId,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return ReadingSession(
      sessionId: sessionId ?? this.sessionId,
      bookId: bookId ?? this.bookId,
      readRound: readRound ?? this.readRound,
      firstStartDate: firstStartDate ?? this.firstStartDate,
      completedDate: completedDate ?? this.completedDate,
      accumulatedActiveTime: accumulatedActiveTime ?? this.accumulatedActiveTime,
      status: status ?? this.status,
      userId: userId ?? this.userId,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'sessionId': sessionId,
      'bookId': bookId,
      'readRound': readRound,
      'firstStartDate': firstStartDate.toIso8601String(),
      'completedDate': completedDate?.toIso8601String(),
      'accumulatedActiveTime': accumulatedActiveTime,
      'status': status.label,
      'userId': userId,
      'updatedAt': updatedAt?.toIso8601String(),
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory ReadingSession.fromMap(Map<String, dynamic> map) {
    return ReadingSession(
      sessionId: map['sessionId'] as String,
      bookId: map['bookId'] as String,
      readRound: (map['readRound'] as int?) ?? 1,
      firstStartDate: DateTime.parse(map['firstStartDate'] as String),
      completedDate: map['completedDate'] == null
          ? null
          : DateTime.parse(map['completedDate'] as String),
      accumulatedActiveTime:
          (map['accumulatedActiveTime'] as int?) ?? 0,
      status: ReadingSessionStatus.fromString(
          (map['status'] as String?) ?? 'READING'),
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

  @override
  String toString() =>
      'ReadingSession(sessionId: $sessionId, bookId: $bookId, '
      'round: $readRound, status: ${status.label}, '
      'active: ${accumulatedActiveTime}s)';
}
