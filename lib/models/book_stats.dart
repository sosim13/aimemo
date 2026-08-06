/// Aggregated completion statistics for a [Book] across all of its
/// completed [ReadingSession]s.
class BookStats {
  /// Shortest active reading time among completed sessions, in seconds.
  /// 0 when the book has only been read once.
  final int minReadingTime;

  /// Longest active reading time among completed sessions, in seconds.
  final int maxReadingTime;

  /// Mean active reading time across all completed sessions, in seconds.
  final double avgReadingTime;

  /// Number of completed sessions used to compute these stats.
  final int completedCount;

  BookStats({
    required this.minReadingTime,
    required this.maxReadingTime,
    required this.avgReadingTime,
    required this.completedCount,
  });

  /// Build stats from a list of completed-session active-time values
  /// (each in seconds). Returns an all-zero [BookStats] when the list is
  /// empty (book has not been completed yet).
  factory BookStats.fromDurations(List<int> durationsSeconds) {
    if (durationsSeconds.isEmpty) {
      return BookStats(
        minReadingTime: 0,
        maxReadingTime: 0,
        avgReadingTime: 0,
        completedCount: 0,
      );
    }
    final sorted = [...durationsSeconds]..sort();
    final min = sorted.first;
    final max = sorted.last;
    final sum = durationsSeconds.fold<int>(0, (a, b) => a + b);
    final avg = sum / durationsSeconds.length;
    return BookStats(
      minReadingTime: min,
      maxReadingTime: max,
      avgReadingTime: avg,
      completedCount: durationsSeconds.length,
    );
  }

  @override
  String toString() =>
      'BookStats(min: ${minReadingTime}s, max: ${maxReadingTime}s, '
      'avg: ${avgReadingTime.toStringAsFixed(1)}s, count: $completedCount)';
}
