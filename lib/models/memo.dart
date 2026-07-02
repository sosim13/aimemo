class Memo {
  final int? id;
  final String title;
  final String content;
  final String category;
  final String? sourceUrl;
  final String? youtubeVideoId;
  final String? thumbnailUrl;
  final String? imagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  Memo({
    this.id,
    required this.title,
    required this.content,
    required this.category,
    this.sourceUrl,
    this.youtubeVideoId,
    this.thumbnailUrl,
    this.imagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Whether this memo has a YouTube thumbnail to show
  bool get hasThumbnail =>
      thumbnailUrl != null && thumbnailUrl!.isNotEmpty;

  /// Whether this memo has a local image to show
  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  /// Whether this memo is associated with any media (video or image)
  bool get hasMedia => hasThumbnail || hasImage;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'content': content,
      'category': category,
      'sourceUrl': sourceUrl,
      'youtubeVideoId': youtubeVideoId,
      'thumbnailUrl': thumbnailUrl,
      'imagePath': imagePath,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory Memo.fromMap(Map<String, dynamic> map) {
    return Memo(
      id: map['id'] as int?,
      title: map['title'] as String,
      content: map['content'] as String,
      category: map['category'] as String,
      sourceUrl: map['sourceUrl'] as String?,
      youtubeVideoId: map['youtubeVideoId'] as String?,
      thumbnailUrl: map['thumbnailUrl'] as String?,
      imagePath: map['imagePath'] as String?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
    );
  }

  Memo copyWith({
    int? id,
    String? title,
    String? content,
    String? category,
    String? sourceUrl,
    String? youtubeVideoId,
    String? thumbnailUrl,
    String? imagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Memo(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      category: category ?? this.category,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      imagePath: imagePath ?? this.imagePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'category': category,
      'sourceUrl': sourceUrl,
      'youtubeVideoId': youtubeVideoId,
      'thumbnailUrl': thumbnailUrl,
      'imagePath': imagePath,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as int?,
      title: json['title'] as String,
      content: json['content'] as String,
      category: json['category'] as String,
      sourceUrl: json['sourceUrl'] as String?,
      youtubeVideoId: json['youtubeVideoId'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      imagePath: json['imagePath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  @override
  String toString() {
    return 'Memo(id: $id, title: $title, category: $category)';
  }
}
