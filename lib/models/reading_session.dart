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

  ReadingSession({
    required this.sessionId,
    required this.bookId,
    required this.readRound,
    required this.firstStartDate,
    this.completedDate,
    required this.accumulatedActiveTime,
    required this.status,
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
  }) {
    return ReadingSession(
      sessionId: sessionId ?? this.sessionId,
      bookId: bookId ?? this.bookId,
      readRound: readRound ?? this.readRound,
      firstStartDate: firstStartDate ?? this.firstStartDate,
      completedDate: completedDate ?? this.completedDate,
      accumulatedActiveTime: accumulatedActiveTime ?? this.accumulatedActiveTime,
      status: status ?? this.status,
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
    );
  }

  @override
  String toString() =>
      'ReadingSession(sessionId: $sessionId, bookId: $bookId, '
      'round: $readRound, status: ${status.label}, '
      'active: ${accumulatedActiveTime}s)';
}
