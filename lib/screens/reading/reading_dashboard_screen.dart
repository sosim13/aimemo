import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/book_stats.dart';
import '../../models/reading_session.dart';
import '../../services/book_vision_service.dart';
import '../../services/reading_service.dart';
import '../../services/sync_service.dart';
import 'book_detail_screen.dart';
import 'camera_scan_screen.dart';
import 'reading_timer_screen.dart';

/// Dashboard for the "독서" category.
///
/// 모든 등록된 책을 카드 형태로 표시. 책 탭 → 상세 화면(BookDetailScreen)으로 이동.
/// 각 카드 하단에 "독서 시작 / 이어 읽기 / 다시 읽기" 버튼이 있어
/// 대시보드에서 바로 독서를 시작할 수 있음.
class ReadingDashboardScreen extends StatefulWidget {
  const ReadingDashboardScreen({super.key});

  @override
  State<ReadingDashboardScreen> createState() =>
      _ReadingDashboardScreenState();
}

class _ReadingDashboardScreenState extends State<ReadingDashboardScreen> {
  final _readingService = ReadingService();
  final _syncService = SyncService();
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

  /// pull-to-refresh: Supabase에서 풀한 뒤 로컬 목록 갱신.
  /// 비로그인 상태면 SyncService 내부에서 no-op 처리되어 로컬만 reload.
  Future<void> _refreshFromSupabase() async {
    // 1. 원격에서 풀 + 충돌 해결 + 로컬 DB 업데이트 (백그라운드)
    await _syncService.pullFromSupabase();
    // 2. 로컬 DB에서 최신 목록 조회하여 UI 갱신
    await _loadBooks();
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
                        '아래 + 버튼을 눌러 책을 등록하세요.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refreshFromSupabase,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 80),
                    itemCount: _books.length,
                    itemBuilder: (context, index) =>
                        _BookCard(book: _books[index], onChanged: _loadBooks),
                  ),
                ),
      // 새 책 등록 버튼
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openReadingScanner,
        icon: const Icon(Icons.add),
        label: const Text('새 책 등록'),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 새 책 등록 (카메라 스캔 플로우)
  // ---------------------------------------------------------------------------

  /// 카메라를 열어 책 표지를 스캔하고, 기존 책 매칭 후 타이머 화면으로 이동.
  /// home_screen.dart의 _openReadingScanner와 동일한 플로우.
  Future<void> _openReadingScanner() async {
    final scanResult = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScanScreen()),
    );
    if (scanResult == null || !mounted) return;

    final edited = await _showScanResultEditor(scanResult);
    if (edited == null || !mounted) return;

    final readingService = ReadingService();
    final existing = await readingService.findBookByTitle(edited.title);

    Book? book;
    bool forceNewRound = false;

    if (existing != null) {
      final active =
          await readingService.getActiveSessionForBook(existing.bookId);
      if (active != null) {
        book = existing;
        if (active.status == ReadingSessionStatus.paused) {
          final decision = await _askResumeOrReread();
          if (decision == null) return;
          forceNewRound = !decision;
        }
      } else {
        final decision = await _askReread();
        if (decision != true) return;
        book = existing;
        forceNewRound = true;
      }
    }

    if (!mounted) return;
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingTimerScreen(
          existingBook: book,
          scanResult: book == null ? edited : null,
          forceNewRound: forceNewRound,
        ),
      ),
    );
    if (mounted) await _loadBooks();
  }

  /// 스캔 결과 편집 다이얼로그.
  Future<ScanResult?> _showScanResultEditor(ScanResult scan) {
    final titleCtrl = TextEditingController(text: scan.title);
    final authorCtrl = TextEditingController(text: scan.author);

    return showDialog<ScanResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('책 정보 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (scan.thumbnailPath.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(scan.thumbnailPath),
                  width: 120, height: 160, fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: '책 제목',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: authorCtrl,
              decoration: const InputDecoration(
                labelText: '저자 (선택)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              ScanResult(
                title: titleCtrl.text.trim(),
                author: authorCtrl.text.trim(),
                thumbnailPath: scan.thumbnailPath,
              ),
            ),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  /// 일시 정지 중인 세션이 있을 때: 이어 읽기(true) / 다시 읽기(false) 선택.
  Future<bool?> _askResumeOrReread() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이어 읽기'),
        content: const Text('이 책은 진행 중인 독서 기록이 있습니다.\n이어 읽으시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('다시 읽기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('이어 읽기'),
          ),
        ],
      ),
    );
  }

  /// 완독한 책 다시 읽기 확인.
  Future<bool?> _askReread() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('다시 읽기'),
        content: const Text('이미 완독한 책입니다.\n다시 읽으시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('다시 읽기'),
          ),
        ],
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            widget.book.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              size: 20, color: Colors.grey[400]),
                          onPressed: _onDelete,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          splashRadius: 16,
                          tooltip: '삭제',
                        ),
                      ],
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
                    const SizedBox(height: 10),
                    // 독서 시작 / 이어 읽기 / 다시 읽기 버튼
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () =>
                            _onStartTimer(hasActive, activeSession),
                        icon: Icon(
                          hasActive
                              ? (activeSession.status ==
                                      ReadingSessionStatus.paused
                                  ? Icons.play_arrow
                                  : Icons.play_arrow)
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

  static final _placeholder = ReadingSession(
    sessionId: '',
    bookId: '',
    readRound: 0,
    firstStartDate: DateTime.fromMillisecondsSinceEpoch(0),
    accumulatedActiveTime: 0,
    status: ReadingSessionStatus.reading,
  );

  Widget _buildCover() {
    // 1. thumbnail_url(Supabase Storage)이 있으면 CachedNetworkImage로 먼저 표시
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
          errorWidget: (context, url, error) =>
              _buildLocalCover(), // 원격 실패 시 로컬 fallback
        ),
      );
    }

    // 2. thumbnail_url이 없으면 로컬 파일 표시
    return _buildLocalCover();
  }

  /// 로컬 파일 썸네일 위젯. 파일이 없으면 기본 아이콘.
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

  Future<void> _onTap(bool hasActive, ReadingSession activeSession) async {
    // 상세 화면으로 이동 — 이력, 통계, 독서 시작 버튼이 모두 있음.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailScreen(book: widget.book),
      ),
    );
    // 상세 화면에서 돌아오면 데이터 갱신
    widget.onChanged();
    _loadSessions();
  }

  /// 카드 내부 "독서 시작" 버튼 클릭 시 바로 타이머 화면으로 이동.
  Future<void> _onStartTimer(bool hasActive, ReadingSession activeSession) async {
    final book = widget.book;
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
    }
  }

  Future<void> _onDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('독서 기록 삭제'),
        content: Text(
            '"${widget.book.title}"의 모든 독서 기록과 썸네일이 삭제됩니다.\n이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _readingService.deleteBookCompletely(widget.book.bookId);
      widget.onChanged();
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
