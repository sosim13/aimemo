/// Represents a book registered via the Reading Tracker feature.
///
/// One [Book] row can have multiple [ReadingSession]s (1st read, 2nd read, …).
/// The [category] field is always `'독서'` so that books naturally appear in
/// the existing category filter of the main memo list.
class Book {
  final String bookId;
  final String title;

  /// Optional author recognized by the local vision model. Empty string when
  /// the model could not determine the author.
  final String author;

  /// Absolute path to the cropped cover thumbnail stored on the device.
  final String coverThumbnailPath;

  /// Always `'독서'` for books created via Reading Tracker.
  final String category;

  /// Number of times this book has been fully read (incremented each time a
  /// session reaches [ReadingSessionStatus.completed]).
  final int totalReadCount;

  Book({
    required this.bookId,
    required this.title,
    this.author = '',
    required this.coverThumbnailPath,
    this.category = '독서',
    this.totalReadCount = 0,
  });

  Book copyWith({
    String? bookId,
    String? title,
    String? author,
    String? coverThumbnailPath,
    String? category,
    int? totalReadCount,
  }) {
    return Book(
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      author: author ?? this.author,
      coverThumbnailPath: coverThumbnailPath ?? this.coverThumbnailPath,
      category: category ?? this.category,
      totalReadCount: totalReadCount ?? this.totalReadCount,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'bookId': bookId,
      'title': title,
      'author': author,
      'coverThumbnailPath': coverThumbnailPath,
      'category': category,
      'totalReadCount': totalReadCount,
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      bookId: map['bookId'] as String,
      title: map['title'] as String,
      author: (map['author'] as String?) ?? '',
      coverThumbnailPath: map['coverThumbnailPath'] as String,
      category: (map['category'] as String?) ?? '독서',
      totalReadCount:
          (map['totalReadCount'] as int?) ?? 0,
    );
  }

  @override
  String toString() =>
      'Book(bookId: $bookId, title: $title, author: $author, '
      'totalReadCount: $totalReadCount)';
}
