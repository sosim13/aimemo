import 'dart:io';

import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../models/book_stats.dart';
import '../models/reading_session.dart';
import 'database_service.dart';

/// Business logic for the Reading Tracker feature.
///
/// Owns all CRUD and timer arithmetic for [Book] / [ReadingSession],
/// plus the statistics computation backing the Reading Dashboard.
/// The in-flight timer lives in the UI layer (ReadingTimerScreen), which
/// periodically calls [addActiveTime] to persist accumulated seconds.
class ReadingService {
  static final ReadingService _instance = ReadingService._internal();
  factory ReadingService() => _instance;
  ReadingService._internal();

  final _db = DatabaseService();
  final _uuid = const Uuid();

  // ---------------------------------------------------------------------------
  // Books
  // ---------------------------------------------------------------------------

  Future<String> insertBook({
    required String title,
    String author = '',
    required String coverThumbnailPath,
  }) async {
    final bookId = _uuid.v4();
    final book = Book(
      bookId: bookId,
      title: title,
      author: author,
      coverThumbnailPath: coverThumbnailPath,
    );
    await _db.insertBook(book);
    return bookId;
  }

  Future<List<Book>> getAllBooks() async => _db.getAllBooks();

  Future<Book?> getBookById(String bookId) async => _db.getBookById(bookId);

  /// Looks up any book whose normalized title matches [title].
  ///
  /// Matching is case-insensitive and whitespace-insensitive. Returns the
  /// most recently registered matching book first (so the "recent" book
  /// wins when there are duplicate registrations).
  Future<Book?> findBookByTitle(String title) async {
    final all = await getAllBooks();
    final needle = _normalizeTitle(title);
    Book? match;
    for (final b in all) {
      if (_normalizeTitle(b.title) == needle) {
        // Prefer the one with a later firstStartDate — but since Book itself
        // only exposes totalReadCount, we keep the latest iteration by
        // simply replacing. Callers needing session info will fetch sessions.
        match = b;
      }
    }
    return match;
  }

  Future<int> deleteBook(String bookId) async => _db.deleteBook(bookId);

  /// Permanently deletes a book, all of its reading sessions, and the
  /// cropped cover thumbnail file from disk. Returns the number of DB
  /// rows affected (book row).
  Future<int> deleteBookCompletely(String bookId) async {
    final book = await getBookById(bookId);
    if (book == null) return 0;

    // Delete the on-disk thumbnail (ignore failures — file may already
    // be gone if the user cleared app data).
    if (book.coverThumbnailPath.isNotEmpty) {
      try {
        final file = File(book.coverThumbnailPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }

    // Delete sessions + book row. The DB layer already cascades session
    // deletion inside a single transaction.
    return _db.deleteBook(bookId);
  }

  Future<void> _bumpReadCount(String bookId) async {
    final book = await getBookById(bookId);
    if (book == null) return;
    await _db.updateBook(
      book.copyWith(totalReadCount: book.totalReadCount + 1),
    );
  }

  // ---------------------------------------------------------------------------
  // Reading Sessions
  // ---------------------------------------------------------------------------

  /// Creates the very first reading session for a freshly-registered book.
  /// `readRound` starts at 1.
  Future<ReadingSession> startReading(String bookId) async {
    final sessionId = _uuid.v4();
    final session = ReadingSession(
      sessionId: sessionId,
      bookId: bookId,
      readRound: 1,
      firstStartDate: DateTime.now(),
      accumulatedActiveTime: 0,
      status: ReadingSessionStatus.reading,
    );
    await _db.insertReadingSession(session);
    return session;
  }

  /// Starts a new reading round for a book that already has one or more
  /// completed sessions. `readRound` is max(existing) + 1.
  Future<ReadingSession> startReRead(String bookId) async {
    final sessions = await getSessionsForBook(bookId);
    final maxRound = sessions.isEmpty
        ? 0
        : sessions.map((s) => s.readRound).reduce((a, b) => a > b ? a : b);
    final sessionId = _uuid.v4();
    final session = ReadingSession(
      sessionId: sessionId,
      bookId: bookId,
      readRound: maxRound + 1,
      firstStartDate: DateTime.now(),
      accumulatedActiveTime: 0,
      status: ReadingSessionStatus.reading,
    );
    await _db.insertReadingSession(session);
    return session;
  }

  /// Resumes a paused session — status flips from PAUSED back to READING.
  /// The accumulated time is preserved as-is; new active time is appended
  /// via [addActiveTime] while the timer runs.
  Future<void> resumeSession(ReadingSession session) async {
    if (session.status != ReadingSessionStatus.paused) return;
    await _db.updateReadingSession(
      session.copyWith(status: ReadingSessionStatus.reading),
    );
  }

  /// Marks a session as paused without finalizing the reading.
  /// Caller should add the most recent timer delta to the accumulated time
  /// (or use [pauseAndCommit], which does it in one shot).
  Future<void> pauseSession(ReadingSession session) async {
    if (session.status == ReadingSessionStatus.completed) return;
    await _db.updateReadingSession(
      session.copyWith(status: ReadingSessionStatus.paused),
    );
  }

  /// Adds [deltaSeconds] of active time to the session and (optionally)
  /// flips its status — used by the timer screen to persist accumulated
  /// time on either Pause or Complete, without an extra round-trip.
  Future<ReadingSession> addActiveTime(
    ReadingSession session,
    int deltaSeconds, {
    bool pause = false,
  }) async {
    final newTotal = session.accumulatedActiveTime + deltaSeconds;
    final newStatus = pause
        ? ReadingSessionStatus.paused
        : session.status;
    final updated = session.copyWith(
      accumulatedActiveTime: newTotal,
      status: newStatus,
    );
    await _db.updateReadingSession(updated);
    return updated;
  }

  /// Finalizes a reading session:
  /// - Sets [completedDate] to now.
  /// - Marks status as COMPLETED.
  /// - Increments [Book.totalReadCount].
  /// Returns the finalized session so callers can read [completedDate].
  Future<ReadingSession> completeReading(
    ReadingSession session, {
    DateTime? completedAt,
  }) async {
    final now = completedAt ?? DateTime.now();
    final activeTime = session.accumulatedActiveTime;
    final updated = session.copyWith(
      accumulatedActiveTime: activeTime,
      completedDate: now,
      status: ReadingSessionStatus.completed,
    );
    await _db.updateReadingSession(updated);
    await _bumpReadCount(session.bookId);
    return updated;
  }

  Future<List<ReadingSession>> getSessionsForBook(String bookId) async =>
      _db.getReadingSessionsForBook(bookId);

  Future<ReadingSession?> getActiveSessionForBook(String bookId) async {
    final sessions = await getSessionsForBook(bookId);
    for (final s in sessions) {
      if (s.status == ReadingSessionStatus.reading ||
          s.status == ReadingSessionStatus.paused) {
        return s;
      }
    }
    return null;
  }

  Future<int> deleteSession(String sessionId) async =>
      _db.deleteReadingSession(sessionId);

  // ---------------------------------------------------------------------------
  // Statistics
  // ---------------------------------------------------------------------------

  /// Computes [BookStats] across all completed sessions of [bookId].
  /// Sessions that are still in-progress or paused are excluded from
  /// min/max/avg calculations.
  Future<BookStats> getBookStats(String bookId) async {
    final sessions = await getSessionsForBook(bookId);
    final completed = sessions
        .where((s) => s.status == ReadingSessionStatus.completed)
        .map((s) => s.accumulatedActiveTime)
        .toList();
    return BookStats.fromDurations(completed);
  }

  /// Returns the most recent active (READING or PAUSED) session across all
  /// books, or `null` when no session is in flight. Useful for surfacing a
  /// "Resume reading" quick action on the dashboard.
  Future<ReadingSession?> getMostRecentActiveSession() async {
    final books = await getAllBooks();
    ReadingSession? mostRecent;
    for (final book in books) {
      final active = await getActiveSessionForBook(book.bookId);
      if (active != null) {
        if (mostRecent == null ||
            active.firstStartDate.isAfter(mostRecent.firstStartDate)) {
          mostRecent = active;
        }
      }
    }
    return mostRecent;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _normalizeTitle(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
