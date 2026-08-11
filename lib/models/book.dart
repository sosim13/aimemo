/// 독서 트래커(Reading Tracker)로 등록된 책.
///
/// 하나의 [Book]은 여러 [ReadingSession](1회독, 2회독, …)을 가질 수 있다.
/// [category]는 항상 `'독서'`이며, 메인 메모 목록의 카테고리 필터에
/// 자연스럽게 표시되도록 한다.
///
/// 동기화 관련 필드 (Supabase):
/// - [thumbnailUrl]: Supabase Storage의 public URL (원격 썸네일)
/// - [userId]: 동기화용 현재 로그인 사용자 식별자 (user_id)
/// - [updatedAt]: last-write-wins 충돌 해결용 최종 수정 시각
/// - [deletedAt]: 소프트 삭제(soft delete) 시각. null이면 활성 상태.
class Book {
  final String bookId;
  final String title;

  /// 비전 모델이 인식한 저자. 인식하지 못한 경우 빈 문자열.
  final String author;

  /// 디바이스에 저장된 잘린 표지 썸네일의 절대 경로.
  /// 동기화된 원격 책이고 로컬 파일이 아직 없는 경우 빈 문자열일 수 있음.
  final String coverThumbnailPath;

  /// 항상 `'독서'` (Reading Tracker로 생성된 책).
  final String category;

  /// 완독 횟수. 회차가 [ReadingSessionStatus.completed]에 도달할 때마다 증가.
  final int totalReadCount;

  /// Supabase Storage의 public URL. 로컬에 없는 경우 원격에서 다운로드 가능.
  /// 비로그인/오프라인 상태이거나 업로드 전이면 null.
  final String? thumbnailUrl;

  /// 동기화용 사용자 식별자 (Supabase auth.users.id).
  /// 비로그인 상태에서 생성된 책은 null.
  final String? userId;

  /// 최종 수정 시각 — Supabase와의 last-write-wins 충돌 해결에 사용.
  /// 로컬 DB에서는 TEXT(ISO 8601) 형태로 저장.
  final DateTime? updatedAt;

  /// 소프트 삭제 시각. null이면 활성 책, 값이 있으면 삭제된 책.
  final DateTime? deletedAt;

  Book({
    required this.bookId,
    required this.title,
    this.author = '',
    required this.coverThumbnailPath,
    this.category = '독서',
    this.totalReadCount = 0,
    this.thumbnailUrl,
    this.userId,
    this.updatedAt,
    this.deletedAt,
  });

  Book copyWith({
    String? bookId,
    String? title,
    String? author,
    String? coverThumbnailPath,
    String? category,
    int? totalReadCount,
    String? thumbnailUrl,
    String? userId,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return Book(
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      author: author ?? this.author,
      coverThumbnailPath: coverThumbnailPath ?? this.coverThumbnailPath,
      category: category ?? this.category,
      totalReadCount: totalReadCount ?? this.totalReadCount,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      userId: userId ?? this.userId,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  /// 로컬 DB(sqflite) 저장용 맵.
  /// coverThumbnailPath는 빈 문자열 또는 null 가능 (원격 동기화된 책).
  Map<String, dynamic> toMap() {
    return {
      'bookId': bookId,
      'title': title,
      'author': author,
      'coverThumbnailPath': coverThumbnailPath,
      'category': category,
      'totalReadCount': totalReadCount,
      // 동기화 관련 컬럼 (version 9에서 추가)
      'thumbnailUrl': thumbnailUrl,
      'userId': userId,
      'updatedAt': updatedAt?.toIso8601String(),
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      bookId: map['bookId'] as String,
      title: map['title'] as String,
      author: (map['author'] as String?) ?? '',
      // coverThumbnailPath는 NOT NULL 제약을 완화 — 빈 문자열 또는 null 가능
      coverThumbnailPath: (map['coverThumbnailPath'] as String?) ?? '',
      category: (map['category'] as String?) ?? '독서',
      totalReadCount: (map['totalReadCount'] as int?) ?? 0,
      // 동기화 관련 필드 — 안전 파싱 (null 또는 빈 문자열 처리)
      thumbnailUrl: _parseNullableString(map['thumbnailUrl']),
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
      'Book(bookId: $bookId, title: $title, author: $author, '
      'totalReadCount: $totalReadCount, thumbnailUrl: $thumbnailUrl, '
      'userId: $userId, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}
