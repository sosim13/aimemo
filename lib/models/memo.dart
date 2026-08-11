import 'package:uuid/uuid.dart';

class Memo {
  final int? id;

  /// 글로벌 고유 식별자 (UUID). Supabase 동기화용.
  /// 신규 메모는 생성 시 자동 할당되며, 기존 메모는 마이그레이션 시 자동 부여.
  final String memoId;

  final String title;
  final String content;
  final String category;
  final String? sourceUrl;
  final String? youtubeVideoId;
  final String? thumbnailUrl;
  final String? imagePath;

  /// Extracted address from AI analysis (e.g. "인천 남동구 백범로 109")
  final String? address;

  /// Search keyword for map lookup when no address found
  /// (e.g. "신림 맛집", "강남역 카페")
  final String? searchKeyword;

  /// Kakao (WGS84) coordinates from address geocoding
  final double? kakaoLat;
  final double? kakaoLng;

  /// Naver (UTMK) coordinates from coordinate conversion
  final double? naverX;
  final double? naverY;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 동기화용 사용자 식별자 (Supabase auth.users.id).
  /// 비로그인 상태에서 생성된 메모는 null.
  final String? userId;

  /// 소프트 삭제 시각. null이면 활성 메모, 값이 있으면 삭제된 메모.
  final DateTime? deletedAt;

  Memo({
    this.id,
    String? memoId,
    required this.title,
    required this.content,
    required this.category,
    this.sourceUrl,
    this.youtubeVideoId,
    this.thumbnailUrl,
    this.imagePath,
    this.address,
    this.searchKeyword,
    this.kakaoLat,
    this.kakaoLng,
    this.naverX,
    this.naverY,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.userId,
    this.deletedAt,
  })  : memoId = memoId ?? _generateMemoId(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// UUID v4 생성 — Supabase 동기화용 글로벌 고유 식별자.
  static const _uuid = Uuid();
  static String _generateMemoId() => _uuid.v4();

  /// Whether this memo has a YouTube thumbnail to show
  bool get hasThumbnail =>
      thumbnailUrl != null && thumbnailUrl!.isNotEmpty;

  /// Whether this memo has a local image to show
  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  /// Whether this memo is associated with any media (video or image)
  bool get hasMedia => hasThumbnail || hasImage;

  /// Whether this memo has geocoded coordinates
  bool get hasCoordinates => kakaoLat != null && kakaoLng != null;

  /// Whether this memo has an extracted address from AI analysis
  bool get hasAddress => address != null && address!.isNotEmpty && address != '없음';

  /// Whether this memo has a search keyword for map lookup
  bool get hasSearchKeyword => searchKeyword != null && searchKeyword!.isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'memoId': memoId,
      'title': title,
      'content': content,
      'category': category,
      'sourceUrl': sourceUrl,
      'youtubeVideoId': youtubeVideoId,
      'thumbnailUrl': thumbnailUrl,
      'imagePath': imagePath,
      'address': address,
      'searchKeyword': searchKeyword,
      'kakaoLat': kakaoLat,
      'kakaoLng': kakaoLng,
      'naverX': naverX,
      'naverY': naverY,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'userId': userId,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory Memo.fromMap(Map<String, dynamic> map) {
    return Memo(
      id: map['id'] as int?,
      memoId: (map['memoId'] as String?) ?? '',
      title: map['title'] as String,
      content: map['content'] as String,
      category: map['category'] as String,
      sourceUrl: map['sourceUrl'] as String?,
      youtubeVideoId: map['youtubeVideoId'] as String?,
      thumbnailUrl: map['thumbnailUrl'] as String?,
      imagePath: map['imagePath'] as String?,
      address: map['address'] as String?,
      searchKeyword: map['searchKeyword'] as String?,
      kakaoLat: (map['kakaoLat'] as num?)?.toDouble(),
      kakaoLng: (map['kakaoLng'] as num?)?.toDouble(),
      naverX: (map['naverX'] as num?)?.toDouble(),
      naverY: (map['naverY'] as num?)?.toDouble(),
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      userId: (map['userId'] as String?)?.isEmpty == false
          ? map['userId'] as String?
          : null,
      deletedAt: _parseDate(map['deletedAt']),
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  Memo copyWith({
    int? id,
    String? memoId,
    String? title,
    String? content,
    String? category,
    String? sourceUrl,
    String? youtubeVideoId,
    String? thumbnailUrl,
    String? imagePath,
    String? address,
    String? searchKeyword,
    double? kakaoLat,
    double? kakaoLng,
    double? naverX,
    double? naverY,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? userId,
    DateTime? deletedAt,
  }) {
    return Memo(
      id: id ?? this.id,
      memoId: memoId ?? this.memoId,
      title: title ?? this.title,
      content: content ?? this.content,
      category: category ?? this.category,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      imagePath: imagePath ?? this.imagePath,
      address: address ?? this.address,
      searchKeyword: searchKeyword ?? this.searchKeyword,
      kakaoLat: kakaoLat ?? this.kakaoLat,
      kakaoLng: kakaoLng ?? this.kakaoLng,
      naverX: naverX ?? this.naverX,
      naverY: naverY ?? this.naverY,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userId: userId ?? this.userId,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'memoId': memoId,
      'title': title,
      'content': content,
      'category': category,
      'sourceUrl': sourceUrl,
      'youtubeVideoId': youtubeVideoId,
      'thumbnailUrl': thumbnailUrl,
      'imagePath': imagePath,
      'address': address,
      'searchKeyword': searchKeyword,
      'kakaoLat': kakaoLat,
      'kakaoLng': kakaoLng,
      'naverX': naverX,
      'naverY': naverY,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'userId': userId,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as int?,
      memoId: (json['memoId'] as String?) ?? '',
      title: json['title'] as String,
      content: json['content'] as String,
      category: json['category'] as String,
      sourceUrl: json['sourceUrl'] as String?,
      youtubeVideoId: json['youtubeVideoId'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      imagePath: json['imagePath'] as String?,
      address: json['address'] as String?,
      searchKeyword: json['searchKeyword'] as String?,
      kakaoLat: (json['kakaoLat'] as num?)?.toDouble(),
      kakaoLng: (json['kakaoLng'] as num?)?.toDouble(),
      naverX: (json['naverX'] as num?)?.toDouble(),
      naverY: (json['naverY'] as num?)?.toDouble(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      userId: (json['userId'] as String?)?.isEmpty == false
          ? json['userId'] as String?
          : null,
      deletedAt: _parseDate(json['deletedAt']),
    );
  }

  @override
  String toString() {
    return 'Memo(id: $id, memoId: $memoId, title: $title, category: $category)';
  }
}
