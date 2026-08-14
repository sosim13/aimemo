import 'dart:io';

import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../models/book_stats.dart';
import '../models/reading_session.dart';
import 'database_service.dart';
import 'sync_service.dart';

/// Business logic for the Reading Tracker feature.
///
/// Owns all CRUD and timer arithmetic for [Book] / [ReadingSession],
/// plus the statistics computation backing the Reading Dashboard.
/// The in-flight timer lives in the UI layer (ReadingTimerScreen), which
/// periodically calls [addActiveTime] to persist accumulated seconds.
///
/// 동기화: 로컬 DB에 먼저 저장한 뒤 SyncService.debouncePush()로 1초 debounce 후
/// Supabase에 push 시도. 비로그인 상태면 SyncService 내부에서 no-op 처리됨.
class ReadingService {
  static final ReadingService _instance = ReadingService._internal();
  factory ReadingService() => _instance;
  ReadingService._internal();

  final _db = DatabaseService();
  final _uuid = const Uuid();
  final _sync = SyncService();

  // ---------------------------------------------------------------------------
  // Books
  // ---------------------------------------------------------------------------

  Future<String> insertBook({
    required String title,
    String author = '',
    required String coverThumbnailPath,
  }) async {
    final bookId = _uuid.v4();
    final now = DateTime.now();
    final book = Book(
      bookId: bookId,
      title: title,
      author: author,
      coverThumbnailPath: coverThumbnailPath,
      updatedAt: now,
    );
    await _db.insertBook(book);
    // 동기화 — 비로그인 상태면 debouncePush 내부에서 no-op
    _sync.debouncePush(book);
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

  Future<int> deleteBook(String bookId) async {
    // 세션들도 함께 삭제되므로 원격 세션 삭제를 먼저 예약
    await _pushDeleteAllSessions(bookId);
    final result = _db.deleteBook(bookId);
    // 동기화 — 원격에서도 삭제 (soft delete push)
    _sync.pushDelete(bookId).catchError((e) {
      // ignore: avoid_print
      print('[ReadingService] deleteBook sync 오류: $e');
    });
    return result;
  }

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
    // 세션들도 함께 삭제되므로 원격 세션 삭제를 먼저 예약
    await _pushDeleteAllSessions(bookId);
    final result = await _db.deleteBook(bookId);

    // 동기화 — 원격에서도 삭제 (soft delete push)
    _sync.pushDelete(bookId).catchError((e) {
      // ignore: avoid_print
      print('[ReadingService] deleteBookCompletely sync 오류: $e');
    });

    return result;
  }

  Future<void> _bumpReadCount(String bookId) async {
    final book = await getBookById(bookId);
    if (book == null) return;
    final updated = book.copyWith(
      totalReadCount: book.totalReadCount + 1,
      updatedAt: DateTime.now(),
    );
    await _db.updateBook(updated);
    // 동기화 — totalReadCount 변경 시 push (간접 updateBook 동기화)
    _sync.debouncePush(updated);
  }

  /// [bookId]에 속한 모든 세션을 원격에서 soft delete (책 삭제 시 호출).
  Future<void> _pushDeleteAllSessions(String bookId) async {
    try {
      final sessions = await getSessionsForBook(bookId);
      for (final s in sessions) {
        _sync.pushReadingSessionDelete(s.sessionId).catchError((e) {
          // ignore: avoid_print
          print('[ReadingService] book 세션 삭제 sync 오류: ${s.sessionId} — $e');
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ReadingService] _pushDeleteAllSessions 오류: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Reading Sessions
  // ---------------------------------------------------------------------------

  /// Creates the very first reading session for a freshly-registered book.
  /// `readRound` starts at 1.
  Future<ReadingSession> startReading(String bookId) async {
    final sessionId = _uuid.v4();
    final now = DateTime.now();
    final session = ReadingSession(
      sessionId: sessionId,
      bookId: bookId,
      readRound: 1,
      firstStartDate: now,
      accumulatedActiveTime: 0,
      status: ReadingSessionStatus.reading,
      updatedAt: now,
    );
    await _db.insertReadingSession(session);
    // 동기화 — 독서 이력도 Supabase에 반영
    _sync.debouncePushReadingSession(session);
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
    final now = DateTime.now();
    final session = ReadingSession(
      sessionId: sessionId,
      bookId: bookId,
      readRound: maxRound + 1,
      firstStartDate: now,
      accumulatedActiveTime: 0,
      status: ReadingSessionStatus.reading,
      updatedAt: now,
    );
    await _db.insertReadingSession(session);
    // 동기화
    _sync.debouncePushReadingSession(session);
    return session;
  }

  /// Resumes a paused session — status flips from PAUSED back to READING.
  /// The accumulated time is preserved as-is; new active time is appended
  /// via [addActiveTime] while the timer runs.
  Future<void> resumeSession(ReadingSession session) async {
    if (session.status != ReadingSessionStatus.paused) return;
    final updated = session.copyWith(
      status: ReadingSessionStatus.reading,
      updatedAt: DateTime.now(),
    );
    await _db.updateReadingSession(updated);
    // 동기화
    _sync.debouncePushReadingSession(updated);
  }

  /// Marks a session as paused without finalizing the reading.
  /// Caller should add the most recent timer delta to the accumulated time
  /// (or use [pauseAndCommit], which does it in one shot).
  Future<void> pauseSession(ReadingSession session) async {
    if (session.status == ReadingSessionStatus.completed) return;
    final updated = session.copyWith(
      status: ReadingSessionStatus.paused,
      updatedAt: DateTime.now(),
    );
    await _db.updateReadingSession(updated);
    // 동기화
    _sync.debouncePushReadingSession(updated);
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
      updatedAt: DateTime.now(),
    );
    await _db.updateReadingSession(updated);
    // 동기화 — 1초마다 호출되므로 debounce가 과도한 호출을 막는다.
    _sync.debouncePushReadingSession(updated);
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
      updatedAt: now,
    );
    await _db.updateReadingSession(updated);
    await _bumpReadCount(session.bookId);
    // 동기화 — 완료된 세션까지 원격에 반영
    _sync.debouncePushReadingSession(updated);
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

  Future<int> deleteSession(String sessionId) async {
    final result = await _db.deleteReadingSession(sessionId);
    // 동기화 — 원격에서도 세션 삭제 (soft delete push)
    _sync.pushReadingSessionDelete(sessionId).catchError((e) {
      // ignore: avoid_print
      print('[ReadingService] deleteSession sync 오류: $e');
    });
    return result;
  }

  // ---------------------------------------------------------------------------
  // Calendar — 날짜별 세션 조회
  // ---------------------------------------------------------------------------

  /// 특정 날짜(연-월-일)에 독서 활동이 있은 모든 세션을 반환.
  /// firstStartDate가 해당 날짜인 세션 또는 completedDate가 해당 날짜인 세션.
  /// [date]는 시간 부분이 0으로 정규화되어야 함.
  Future<List<ReadingSession>> getSessionsForDate(DateTime date) async {
    final allBooks = await getAllBooks();
    final dateStr = _dateOnly(date);
    final sessions = <ReadingSession>[];
    for (final book in allBooks) {
      final bookSessions = await getSessionsForBook(book.bookId);
      for (final s in bookSessions) {
        // firstStartDate 또는 completedDate가 해당 날짜인 세션
        if (_dateOnly(s.firstStartDate) == dateStr) {
          sessions.add(s);
        } else if (s.completedDate != null &&
            _dateOnly(s.completedDate!) == dateStr) {
          sessions.add(s);
        }
      }
    }
    // 최신순 정렬
    sessions.sort((a, b) => b.firstStartDate.compareTo(a.firstStartDate));
    return sessions;
  }

  /// YYYY-MM-DD 형식 문자열로 변환.
  static String _dateOnly(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}'
        '-${dt.month.toString().padLeft(2, '0')}'
        '-${dt.day.toString().padLeft(2, '0')}';
  }

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
