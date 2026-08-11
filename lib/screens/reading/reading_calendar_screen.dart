import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../models/book.dart';
import '../../models/reading_session.dart';
import '../../services/reading_service.dart';
import 'book_detail_screen.dart';
import 'reading_timer_screen.dart';

/// 독서 달력 화면.
///
/// 상단: 월 선택 + 이번 달 총 독서 권수/시간 요약 헤더
/// 중앙: 달력 뷰 (독서한 날짜에 Badge 표시)
/// 하단: 선택된 날짜의 읽은 책 목록 (Card 형태)
class ReadingCalendarScreen extends StatefulWidget {
  const ReadingCalendarScreen({super.key});

  @override
  State<ReadingCalendarScreen> createState() =>
      _ReadingCalendarScreenState();
}

class _ReadingCalendarScreenState extends State<ReadingCalendarScreen> {
  final _readingService = ReadingService();

  late DateTime _focusedDay;
  DateTime? _selectedDay;

  /// 전체 책 목록 — 달력 데이터 구성용
  List<Book> _allBooks = [];

  /// 날짜별 세션 맵 (YYYY-MM-DD → List<ReadingSession>)
  Map<DateTime, List<ReadingSession>> _sessionMap = {};

  /// 날짜별 책 맵 (YYYY-MM-DD → List<Book>)
  Map<DateTime, List<Book>> _bookMap = {};

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _focusedDay = DateTime.now();
    _selectedDay = _normalizeDate(DateTime.now());
    _loadData();
  }

  /// 시간 부분 제거하여 날짜만 남김.
  DateTime _normalizeDate(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      _allBooks = await _readingService.getAllBooks();
      _sessionMap.clear();
      _bookMap.clear();

      // 각 책의 세션을 순회하며 날짜별 맵 구성
      for (final book in _allBooks) {
        final sessions =
            await _readingService.getSessionsForBook(book.bookId);
        for (final s in sessions) {
          // 시작일
          final startDay = _normalizeDate(s.firstStartDate);
          _sessionMap.putIfAbsent(startDay, () => []).add(s);
          _bookMap.putIfAbsent(startDay, () => []).add(book);
          // 완료일 (시작일과 다른 경우)
          if (s.completedDate != null) {
            final endDay = _normalizeDate(s.completedDate!);
            if (endDay != startDay) {
              _sessionMap.putIfAbsent(endDay, () => []).add(s);
              _bookMap.putIfAbsent(endDay, () => []).add(book);
            }
          }
        }
      }

      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 선택된 날짜의 책 목록 반환 (중복 제거).
  List<Book> _getBooksForDay(DateTime day) {
    final normalized = _normalizeDate(day);
    final books = _bookMap[normalized] ?? [];
    // 동일한 bookId 중복 제거
    final seen = <String>{};
    return books.where((b) {
      if (seen.contains(b.bookId)) return false;
      seen.add(b.bookId);
      return true;
    }).toList();
  }

  /// 선택된 날짜의 세션 목록 반환.
  List<ReadingSession> _getSessionsForDay(DateTime day) {
    final normalized = _normalizeDate(day);
    return _sessionMap[normalized] ?? [];
  }

  /// 특정 월의 총 독서 권수 (고유 책 기준).
  int _getMonthlyBookCount(DateTime monthDay) {
    final year = monthDay.year;
    final month = monthDay.month;
    final bookIds = <String>{};
    _bookMap.forEach((day, books) {
      if (day.year == year && day.month == month) {
        for (final b in books) {
          bookIds.add(b.bookId);
        }
      }
    });
    return bookIds.length;
  }

  /// 특정 월의 총 활독 시간 (초).
  int _getMonthlyActiveTime(DateTime monthDay) {
    final year = monthDay.year;
    final month = monthDay.month;
    var total = 0;
    _sessionMap.forEach((day, sessions) {
      if (day.year == year && day.month == month) {
        for (final s in sessions) {
          // 중복 세션 제거 (같은 sessionId)
          total += s.accumulatedActiveTime;
        }
      }
    });
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('독서 달력'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // --- 상단: 월 요약 헤더 ---
                _buildMonthlyHeader(),
                // --- 중앙: 달력 ---
                _buildCalendar(),
                const Divider(height: 1),
                // --- 하단: 선택된 날짜의 책 목록 ---
                Expanded(child: _buildSelectedDayList()),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // 상단 헤더
  // ---------------------------------------------------------------------------

  Widget _buildMonthlyHeader() {
    final monthCount = _getMonthlyBookCount(_focusedDay);
    final monthTime = _getMonthlyActiveTime(_focusedDay);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(Icons.calendar_month,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            DateFormat('yyyy년 M월').format(_focusedDay),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          _buildHeaderStat(Icons.menu_book, '$monthCount권'),
          const SizedBox(width: 12),
          _buildHeaderStat(
              Icons.timer_outlined, _formatDuration(monthTime)),
        ],
      ),
    );
  }

  Widget _buildHeaderStat(IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 달력
  // ---------------------------------------------------------------------------

  Widget _buildCalendar() {
    return TableCalendar(
      firstDay: DateTime(2020, 1, 1),
      lastDay: DateTime(2100, 12, 31),
      focusedDay: _focusedDay,
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      onDaySelected: (selectedDay, focusedDay) {
        setState(() {
          _selectedDay = selectedDay;
          _focusedDay = focusedDay;
        });
      },
      onPageChanged: (focusedDay) {
        setState(() => _focusedDay = focusedDay);
      },
      calendarFormat: CalendarFormat.month,
      locale: 'ko_KR',
      headerStyle: const HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      calendarStyle: CalendarStyle(
        // 오늘 날짜
        todayDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        todayTextStyle: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
        // 선택된 날짜
        selectedDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
        selectedTextStyle: const TextStyle(color: Colors.white),
        // 기본 날짜
        defaultTextStyle: const TextStyle(fontSize: 13),
        weekendTextStyle: TextStyle(fontSize: 13, color: Colors.red[400]),
        outsideDaysVisible: false,
      ),
      // 커스텀 셀 빌더 — 독서한 날짜에 읽은 권수 Badge 표시
      calendarBuilders: CalendarBuilders(
        defaultBuilder: (context, day, focusedDay) =>
            _buildCalendarCell(day, false, false, false),
        todayBuilder: (context, day, focusedDay) =>
            _buildCalendarCell(day, true, false, false),
        selectedBuilder: (context, day, focusedDay) =>
            _buildCalendarCell(day, false, false, false),
      ),
    );
  }

  /// 달력 셀 빌더 — 독서한 날짜에 읽은 권수 Badge 표시.
  Widget _buildCalendarCell(
      DateTime day, bool isToday, bool isWeekend, bool isOutside) {
    final normalized = _normalizeDate(day);
    final isSelected = isSameDay(_selectedDay, day);
    final booksForDay = _getBooksForDay(normalized);
    final hasReading = booksForDay.isNotEmpty;

    Color dayColor;
    if (isSelected) {
      dayColor = Colors.white;
    } else if (hasReading) {
      dayColor = Theme.of(context).colorScheme.primary;
    } else if (isWeekend) {
      dayColor = Colors.red[400]!;
    } else if (isOutside) {
      dayColor = Colors.grey[400]!;
    } else {
      dayColor = Colors.black87;
    }

    // 첫 번째 책의 썸네일 (있으면)
    final firstBook = hasReading ? booksForDay.first : null;

    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : (isToday
                ? Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.12)
                : Colors.transparent),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 날짜 숫자
          if (firstBook != null && firstBook.coverThumbnailPath.isNotEmpty)
            // 썸네일이 있으면 작은 원으로 표시 (배경)
            _buildCellThumbnail(firstBook, isSelected)
          else if (hasReading)
            // 썸네일 없으면 점 표시
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          // 날짜 숫자
          Positioned(
            bottom: hasReading ? 2 : null,
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: hasReading || isToday ? FontWeight.w700 : null,
                color: dayColor,
              ),
            ),
          ),
          // 읽은 권수 Badge (우측 상단)
          if (hasReading && booksForDay.length > 1)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(
                  minWidth: 16,
                  minHeight: 16,
                ),
                child: Text(
                  '${booksForDay.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 셀 내부 썸네일 (작은 원형)
  Widget _buildCellThumbnail(Book book, bool isSelected) {
    final thumbnailUrl = book.thumbnailUrl;
    final hasRemote = thumbnailUrl != null && thumbnailUrl.isNotEmpty;

    Widget imageWidget;
    if (hasRemote) {
      imageWidget = CachedNetworkImage(
        imageUrl: thumbnailUrl!,
        fit: BoxFit.contain,
        placeholder: (context, url) => Container(
          color: Colors.grey[200],
        ),
        errorWidget: (context, url, error) => _buildLocalThumb(book),
      );
    } else {
      imageWidget = _buildLocalThumb(book);
    }

    return ClipOval(
      child: SizedBox(
        width: 32,
        height: 32,
        child: imageWidget,
      ),
    );
  }

  Widget _buildLocalThumb(Book book) {
    final file = File(book.coverThumbnailPath);
    final exists = file.existsSync();
    if (exists) {
      return Image.file(file, fit: BoxFit.contain);
    }
    return Container(
      color: Colors.grey[200],
      child: Icon(Icons.menu_book, size: 16, color: Colors.grey[400]),
    );
  }

  // ---------------------------------------------------------------------------
  // 하단: 선택된 날짜의 책 목록
  // ---------------------------------------------------------------------------

  Widget _buildSelectedDayList() {
    final books = _getBooksForDay(_selectedDay ?? _focusedDay);
    final sessions = _getSessionsForDay(_selectedDay ?? _focusedDay);
    // 그날 총 읽은 시간(초) — 세션 누적 활독 시간 합산
    final dayTotalSeconds = sessions.fold<int>(
      0,
      (sum, s) => sum + s.accumulatedActiveTime,
    );

    return Column(
      children: [
        // 선택된 날짜 헤더
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            _selectedDay != null
                ? '${DateFormat('M월 d일 EEEE', 'ko_KR').format(_selectedDay!)}'
                    '  •  ${books.length}권  •  ${sessions.length}회차'
                    '  •  총 ${_formatDuration(dayTotalSeconds)}'
                : '날짜를 선택하세요',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ),
        const Divider(height: 1),
        // 책 목록
        Expanded(
          child: books.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.event_busy,
                          size: 48, color: Colors.grey[300]),
                      const SizedBox(height: 8),
                      Text(
                        '이 날에 읽은 책이 없습니다',
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 80),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    final bookSessions = sessions
                        .where((s) => s.bookId == book.bookId)
                        .toList();
                    return _CalendarBookCard(
                      book: book,
                      sessions: bookSessions,
                      onChanged: _loadData,
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 헬퍼
  // ---------------------------------------------------------------------------

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0분';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h == 0) return '$m분';
    return '$h시간 $m분';
  }
}

// =============================================================================
// _CalendarBookCard — 달력 하단 리스트의 책 카드.
// 기존 reading_dashboard_screen.dart의 _BookCard와 동일한 동작:
//   - 카드 탭 → BookDetailScreen 이동
//   - 독서 시작 버튼 → ReadingTimerScreen 이동
// =============================================================================

class _CalendarBookCard extends StatefulWidget {
  final Book book;
  final List<ReadingSession> sessions;
  final VoidCallback onChanged;

  const _CalendarBookCard({
    required this.book,
    required this.sessions,
    required this.onChanged,
  });

  @override
  State<_CalendarBookCard> createState() => _CalendarBookCardState();
}

class _CalendarBookCardState extends State<_CalendarBookCard> {
  final _readingService = ReadingService();

  @override
  Widget build(BuildContext context) {
    final sessions = widget.sessions;
    final hasActive =
        sessions.any((s) => s.isInProgress);
    final totalActive = sessions.fold<int>(
        0, (acc, s) => acc + s.accumulatedActiveTime);

    final activeSession = sessions.firstWhere(
      (s) => s.isInProgress,
      orElse: () => sessions.isNotEmpty
          ? sessions.last
          : ReadingSession(
              sessionId: '',
              bookId: '',
              readRound: 0,
              firstStartDate: DateTime.fromMillisecondsSinceEpoch(0),
              accumulatedActiveTime: 0,
              status: ReadingSessionStatus.reading,
            ),
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.book.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.book.author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.book.author,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                    const SizedBox(height: 8),
                    // 세션 정보
                    if (sessions.isNotEmpty)
                      ...sessions.map((s) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Icon(_statusIcon(s.status),
                                    size: 14, color: _statusColor(s.status)),
                                const SizedBox(width: 4),
                                Text(
                                  '${s.readRound}회차 · ${_statusLabel(s.status)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _formatDuration(s.accumulatedActiveTime),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          )),
                    const SizedBox(height: 8),
                    // 독서 시작 버튼
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () =>
                            _onStartTimer(hasActive, activeSession),
                        icon: Icon(
                          hasActive
                              ? Icons.play_arrow
                              : (widget.book.totalReadCount > 0
                                  ? Icons.replay
                                  : Icons.menu_book),
                          size: 18,
                        ),
                        label: Text(
                          hasActive
                              ? (activeSession.status ==
                                      ReadingSessionStatus.paused
                                  ? '이어 읽기'
                                  : '진행하기')
                              : (widget.book.totalReadCount > 0
                                  ? '다시 읽기'
                                  : '독서 시작'),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          minimumSize: const Size(0, 34),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 카드 탭 → 책 상세 화면으로 이동 (기존 대시보드와 동일).
  Future<void> _onTap() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailScreen(book: widget.book),
      ),
    );
    widget.onChanged();
  }

  /// 독서 시작 버튼 → 타이머 화면으로 이동 (기존 대시보드와 동일).
  Future<void> _onStartTimer(
      bool hasActive, ReadingSession activeSession) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingTimerScreen(
          existingBook: widget.book,
          forceNewRound: !hasActive && widget.book.totalReadCount > 0,
        ),
      ),
    );
    if (result == true) {
      widget.onChanged();
    }
  }

  Widget _buildCover() {
    final thumbnailUrl = widget.book.thumbnailUrl;
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      return Container(
        width: 72,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: thumbnailUrl,
          fit: BoxFit.contain,
          placeholder: (context, url) => const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (context, url, error) => _buildLocalCover(),
        ),
      );
    }
    return _buildLocalCover();
  }

  Widget _buildLocalCover() {
    final file = File(widget.book.coverThumbnailPath);
    final exists = file.existsSync();
    return Container(
      width: 72,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: exists
          ? Image.file(file, fit: BoxFit.contain)
          : const Icon(Icons.menu_book, color: Colors.grey),
    );
  }

  static IconData _statusIcon(ReadingSessionStatus status) {
    return switch (status) {
      ReadingSessionStatus.reading => Icons.play_arrow,
      ReadingSessionStatus.paused => Icons.pause,
      ReadingSessionStatus.completed => Icons.check_circle,
    };
  }

  static Color _statusColor(ReadingSessionStatus status) {
    return switch (status) {
      ReadingSessionStatus.reading => Colors.green,
      ReadingSessionStatus.paused => Colors.orange,
      ReadingSessionStatus.completed => Colors.blue,
    };
  }

  static String _statusLabel(ReadingSessionStatus status) {
    return switch (status) {
      ReadingSessionStatus.reading => '읽는 중',
      ReadingSessionStatus.paused => '일시정지',
      ReadingSessionStatus.completed => '완독',
    };
  }

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0분';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h == 0) return '$m분';
    return '$h시간 $m분';
  }
}
