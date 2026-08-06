import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/book_stats.dart';
import '../../models/reading_session.dart';
import '../../services/reading_service.dart';
import 'reading_timer_screen.dart';

/// Dashboard for the "독서" category.
///
/// Lists every registered book with its completion count, total active
/// reading time, reading period, and (for multi-read books) the per-round
/// min / max / average statistics. Tapping a book that has an in-flight
/// session opens [ReadingTimerScreen] to resume; tapping a fully-read book
/// offers a "다시 읽기" action.
class ReadingDashboardScreen extends StatefulWidget {
  const ReadingDashboardScreen({super.key});

  @override
  State<ReadingDashboardScreen> createState() =>
      _ReadingDashboardScreenState();
}

class _ReadingDashboardScreenState extends State<ReadingDashboardScreen> {
  final _readingService = ReadingService();
  List<Book> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() => _isLoading = true);
    final books = await _readingService.getAllBooks();
    if (mounted) {
      setState(() {
        _books = books;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('독서 기록'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.menu_book,
                          size: 64, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      const Text('등록된 책이 없습니다'),
                      const SizedBox(height: 8),
                      const Text(
                        '메모 작성 화면에서 책 아이콘을 눌러 시작하세요.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadBooks,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 80),
                    itemCount: _books.length,
                    itemBuilder: (context, index) =>
                        _BookCard(book: _books[index], onChanged: _loadBooks),
                  ),
                ),
    );
  }
}

/// Card showing a single book's reading stats. Taps open the timer/resume
/// flow depending on the book's current session state.
class _BookCard extends StatefulWidget {
  final Book book;
  final VoidCallback onChanged;

  const _BookCard({required this.book, required this.onChanged});

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  final _readingService = ReadingService();
  List<ReadingSession>? _sessions;
  BookStats? _stats;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions =
        await _readingService.getSessionsForBook(widget.book.bookId);
    final stats = await _readingService.getBookStats(widget.book.bookId);
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _stats = stats;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final activeSession = _sessions!.firstWhere(
      (s) => s.isInProgress,
      orElse: () => _sessions!.isEmpty
          ? _placeholder
          : _sessions!.last,
    );
    final hasActive = activeSession.isInProgress;
    final lastCompleted = _sessions!.lastWhere(
      (s) => s.isCompleted,
      orElse: () => _placeholder,
    );
    final totalActive = _sessions!.fold<int>(
        0, (acc, s) => acc + s.accumulatedActiveTime);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onTap(hasActive, activeSession),
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
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
                    _StatusChip(
                      status: activeSession.status,
                      completedCount: widget.book.totalReadCount,
                    ),
                    const SizedBox(height: 8),
                    _StatRow(
                      icon: Icons.timer_outlined,
                      label: '총 활독 시간',
                      value: _formatDuration(totalActive),
                    ),
                    if (lastCompleted.isCompleted) ...[
                      const SizedBox(height: 4),
                      _StatRow(
                        icon: Icons.event_available,
                        label: '읽은 기간',
                        value: _readingPeriod(lastCompleted),
                      ),
                    ],
                    if (widget.book.totalReadCount > 1 &&
                        _stats != null &&
                        _stats!.completedCount > 0) ...[
                      const SizedBox(height: 4),
                      _StatRow(
                        icon: Icons.insights,
                        label: '회차별',
                        value:
                            '최단 ${_formatDuration(_stats!.minReadingTime)}'
                            ' / 최장 ${_formatDuration(_stats!.maxReadingTime)}'
                            ' / 평균 ${_formatDuration(_stats!.avgReadingTime.round())}',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static final _placeholder = ReadingSession(
    sessionId: '',
    bookId: '',
    readRound: 0,
    firstStartDate: DateTime.fromMillisecondsSinceEpoch(0),
    accumulatedActiveTime: 0,
    status: ReadingSessionStatus.reading,
  );

  Widget _buildCover() {
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
          ? Image.file(file, fit: BoxFit.cover)
          : const Icon(Icons.menu_book, color: Colors.grey),
    );
  }

  Future<void> _onTap(bool hasActive, ReadingSession activeSession) async {
    final book = widget.book;
    final shouldResume =
        hasActive && activeSession.status == ReadingSessionStatus.paused;
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingTimerScreen(
          existingBook: book,
          forceNewRound: !hasActive && book.totalReadCount > 0,
        ),
      ),
    );
    if (result == true) {
      widget.onChanged();
      _loadSessions();
    } else if (shouldResume) {
      // User backed out without resuming — no-op.
    }
  }

  String _readingPeriod(ReadingSession session) {
    if (!session.isCompleted || session.completedDate == null) return '-';
    final duration = session.completedDate!.difference(session.firstStartDate);
    final days = duration.inHours ~/ 24;
    if (days == 0) return '1일';
    return '$days일';
  }

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0분';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h == 0) return '$m분';
    return '$h시간 $m분';
  }
}

/// Pill showing the session status + completion count.
class _StatusChip extends StatelessWidget {
  final ReadingSessionStatus status;
  final int completedCount;

  const _StatusChip({required this.status, required this.completedCount});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      ReadingSessionStatus.reading => ('읽는 중', Colors.green, Icons.play_arrow),
      ReadingSessionStatus.paused => ('일시 정지', Colors.orange, Icons.pause),
      ReadingSessionStatus.completed =>
        ('완독', Colors.blue, Icons.check_circle),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        if (completedCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            '$completedCount회 완독',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey[500]),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
