import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/book.dart';
import '../../models/book_stats.dart';
import '../../models/reading_session.dart';
import '../../services/reading_service.dart';
import '../../services/database_service.dart';
import '../../widgets/app_bottom_nav_bar.dart';
import 'reading_timer_screen.dart';

/// 책 상세 화면.
///
/// 표시 항목:
/// - 책 표지, 제목, 저자
/// - 완독 횟수, 총 활독 시간
/// - 회차별 독서 이력 (시작일, 종료일, 활독 시간, 상태)
/// - 회차별 통계 (최단/최장/평균)
///
/// 버튼:
/// - 진행 중인 세션이 있으면 "이어 읽기"
/// - 완독한 책이면 "다시 읽기"
/// - 읽은 적 없는 책이면 "독서 시작"
class BookDetailScreen extends StatefulWidget {
  final Book book;

  const BookDetailScreen({super.key, required this.book});

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  final _readingService = ReadingService();
  List<ReadingSession>? _sessions;
  BookStats? _stats;
  late Book _book;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _loadData();
  }

  Future<void> _loadData() async {
    final sessions = await _readingService.getSessionsForBook(_book.bookId);
    final stats = await _readingService.getBookStats(_book.bookId);
    final book = await _readingService.getBookById(_book.bookId);
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _stats = stats;
        if (book != null) _book = book;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('책 상세'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final activeSession = _sessions!.firstWhere(
      (s) => s.isInProgress,
      orElse: () => _sessions!.isEmpty ? _placeholder : _sessions!.last,
    );
    final hasActive = activeSession.isInProgress;
    final totalActive =
        _sessions!.fold<int>(0, (acc, s) => acc + s.accumulatedActiveTime);
    final completedCount = _book.totalReadCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('책 상세'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '책 정보 수정',
            onPressed: _editBookInfo,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '책 삭제',
            onPressed: _deleteBook,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // --- 책 정보 (표지 + 제목/저자) ---
            _buildBookHeader(),
            const SizedBox(height: 24),

            // --- 요약 통계 ---
            _buildSummaryCard(completedCount, totalActive),
            const SizedBox(height: 16),

            // --- 회차별 통계 ---
            if (_stats != null &&
                _stats!.completedCount > 1) ...[
              _buildRoundStatsCard(),
              const SizedBox(height: 16),
            ],

            // --- 회차별 독서 이력 ---
            _buildSessionList(),
            const SizedBox(height: 80),
          ],
        ),
      ),
      // --- 하단 고정 버튼: 독서 시작 / 이어 읽기 / 다시 읽기 + 하단 메뉴 바 ---
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBottomButton(hasActive, activeSession),
          AppBottomNavBar(
            // 독서기록/독서달력은 모두 "더보기" 탭 하위 — 해당 탭을 선택된 상태로 표시
            selectedIndex: AppBottomNavBar.moreTabIndex,
            onDestinationSelected: _onNavDestinationSelected,
          ),
        ],
      ),
    );
  }

  /// 하단 메뉴 바에서 탭 선택 시:
  /// 1. 책 상세 화면을 닫고
  /// 2. MainShell의 해당 탭으로 전환.
  void _onNavDestinationSelected(int index) {
    Navigator.of(context).pop(); // 상세 화면 닫기
    AppBottomNavBar.onSwitchTabRequested?.call(index);
  }

  // ---------------------------------------------------------------------------
  // 위젯 빌더
  // ---------------------------------------------------------------------------

  Widget _buildBookHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCover(),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _book.title,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (_book.author.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _book.author,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _book.category,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCover() {
    final thumbnailUrl = _book.thumbnailUrl;
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      return Container(
        width: 120,
        height: 170,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(2, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: thumbnailUrl,
          fit: BoxFit.contain,
          placeholder: (context, url) => const Center(
            child: SizedBox(
              width: 28,
              height: 28,
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
    final file = File(_book.coverThumbnailPath);
    final exists = file.existsSync();
    return Container(
      width: 120,
      height: 170,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: exists
          ? Image.file(file, fit: BoxFit.contain)
          : const Icon(Icons.menu_book, size: 48, color: Colors.grey),
    );
  }

  Widget _buildSummaryCard(int completedCount, int totalActive) {
    return Card(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('독서 요약',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            // 2x2 그리드 통계
            Row(
              children: [
                Expanded(
                    child: _buildStatTile(Icons.check_circle, '완독 횟수',
                        '$completedCount회', Colors.blue)),
                Expanded(
                    child: _buildStatTile(Icons.timer_outlined, '총 활독 시간',
                        _formatDuration(totalActive), Colors.green)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatTile(
      IconData icon, String label, String value, Color color) {
    return Column(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(height: 8),
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  Widget _buildRoundStatsCard() {
    return Card(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('회차별 통계',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _StatLine('최단 독서', _formatDuration(_stats!.minReadingTime),
                Icons.fast_forward),
            _StatLine('최장 독서', _formatDuration(_stats!.maxReadingTime),
                Icons.schedule),
            _StatLine('평균 독서',
                _formatDuration(_stats!.avgReadingTime.round()), Icons.balance),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionList() {
    if (_sessions!.isEmpty) {
      return Card(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text('아직 독서 기록이 없습니다.\n아래 버튼을 눌러 독서를 시작하세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('독서 이력 (${_sessions!.length}회차)',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        ..._sessions!.asMap().entries.map((entry) {
          final idx = entry.key;
          final session = entry.value;
          return Dismissible(
            key: ValueKey(session.sessionId),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) => _confirmDeleteSession(idx + 1),
            onDismissed: (_) => _deleteSession(session),
            child: _SessionTile(
              index: idx + 1,
              session: session,
              onEdit: () => _editSession(idx + 1, session),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildBottomButton(bool hasActive, ReadingSession activeSession) {
    String label;
 IconData icon;
    if (hasActive) {
      label = activeSession.status == ReadingSessionStatus.paused
          ? '이어 읽기'
          : '독서 진행하기';
      icon = Icons.play_arrow;
    } else if (_book.totalReadCount > 0) {
      label = '다시 읽기';
      icon = Icons.replay;
    } else {
      label = '독서 시작';
      icon = Icons.menu_book;
    }

    // 하단 인셋(홈 인디케이터 등)은 아래 AppBottomNavBar가 처리하므로
    // 여기서는 패딩만 적용.
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.icon(
        onPressed: () => _startTimer(hasActive),
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 16)),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 동작
  // ---------------------------------------------------------------------------

  Future<void> _startTimer(bool hasActive) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingTimerScreen(
          existingBook: _book,
          forceNewRound: !hasActive && _book.totalReadCount > 0,
        ),
      ),
    );
    if (result == true) {
      _loadData(); // 데이터 갱신
    }
  }

  // --- 책 정보 수정 ---

  Future<void> _editBookInfo() async {
    final titleCtrl = TextEditingController(text: _book.title);
    final authorCtrl = TextEditingController(text: _book.author);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책 정보 수정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                labelText: '저자',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      final updated = _book.copyWith(
        title: titleCtrl.text.trim(),
        author: authorCtrl.text.trim(),
        updatedAt: DateTime.now(),
      );
      await _readingService.getBookById(_book.bookId); // ensure exists
      await _db_updateBook(updated);
      _loadData();
    }
  }

  /// DatabaseService에 직접 접근하여 책 정보 업데이트.
  Future<void> _db_updateBook(Book book) async {
    final db = DatabaseService();
    await db.updateBook(book);
  }

  // --- 책 삭제 ---

  Future<void> _deleteBook() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책 삭제'),
        content: Text(
            '"${_book.title}"의 모든 독서 기록과 썸네일이 삭제됩니다.\n이 작업은 되돌릴 수 없습니다.'),
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

    if (confirm == true && mounted) {
      await _readingService.deleteBookCompletely(_book.bookId);
      if (mounted) Navigator.pop(context); // 상세 화면 닫기
    }
  }

  // --- 세션 수정 ---

  Future<void> _editSession(int round, ReadingSession session) async {
    final minutesCtrl = TextEditingController(
      text: (session.accumulatedActiveTime ~/ 60).toString(),
    );
    String selectedStatus = session.status.label;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('$round회차 수정'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: minutesCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '활독 시간 (분)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedStatus,
                decoration: const InputDecoration(
                  labelText: '상태',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: 'READING', child: Text('읽는 중')),
                  const DropdownMenuItem(value: 'PAUSED', child: Text('일시 정지')),
                  const DropdownMenuItem(value: 'COMPLETED', child: Text('완독')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => selectedStatus = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;

    final minutes = int.tryParse(minutesCtrl.text.trim()) ?? 0;
    final newActiveTime = minutes * 60;
    final newStatus = ReadingSessionStatus.fromString(selectedStatus);

    // 완독 상태로 변경하되 completedDate가 없으면 현재 시간으로 설정
    DateTime? newCompletedDate = session.completedDate;
    if (newStatus == ReadingSessionStatus.completed &&
        session.completedDate == null) {
      newCompletedDate = DateTime.now();
    } else if (newStatus != ReadingSessionStatus.completed) {
      newCompletedDate = null;
    }

    final updated = session.copyWith(
      accumulatedActiveTime: newActiveTime,
      status: newStatus,
      completedDate: newCompletedDate,
    );

    final db = DatabaseService();
    await db.updateReadingSession(updated);

    // 상태가 완독으로 변경된 경우 totalReadCount 재계산
    await _recalcReadCount();
    _loadData();
  }

  /// 완독 횟수를 세션 기반으로 재계산하여 업데이트.
  Future<void> _recalcReadCount() async {
    final sessions = await _readingService.getSessionsForBook(_book.bookId);
    final completedCount =
        sessions.where((s) => s.isCompleted).length;
    if (completedCount != _book.totalReadCount) {
      final updated = _book.copyWith(
        totalReadCount: completedCount,
        updatedAt: DateTime.now(),
      );
      final db = DatabaseService();
      await db.updateBook(updated);
    }
  }

  // --- 세션 삭제 ---

  Future<bool?> _confirmDeleteSession(int round) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$round회차 삭제'),
        content: const Text('이 독서 기록을 삭제하시겠습니까?'),
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
  }

  Future<void> _deleteSession(ReadingSession session) async {
    await _readingService.deleteSession(session.sessionId);
    await _recalcReadCount();
    _loadData();
  }

  // ---------------------------------------------------------------------------
  // 헬퍼
  // ---------------------------------------------------------------------------

  static final _placeholder = ReadingSession(
    sessionId: '',
    bookId: '',
    readRound: 0,
    firstStartDate: DateTime.fromMillisecondsSinceEpoch(0),
    accumulatedActiveTime: 0,
    status: ReadingSessionStatus.reading,
  );

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0분';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h == 0) return '$m분';
    return '$h시간 $m분';
  }
}

// =============================================================================
// 하위 위젯
// =============================================================================

/// 단일 통계 라인 (회차별 통계 카드 내부)
class _StatLine extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatLine(this.label, this.value, this.icon);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey[700])),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 회차별 독서 이력 타일
class _SessionTile extends StatelessWidget {
  final int index;
  final ReadingSession session;
  final VoidCallback? onEdit;

  const _SessionTile({
    required this.index,
    required this.session,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy.MM.dd');
    final (label, color, icon) = switch (session.status) {
      ReadingSessionStatus.reading =>
        ('읽는 중', Colors.green, Icons.play_arrow),
      ReadingSessionStatus.paused => ('일시 정지', Colors.orange, Icons.pause),
      ReadingSessionStatus.completed =>
        ('완독', Colors.blue, Icons.check_circle),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$index',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      height: 1.5,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('$index회차',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 3),
                      Text(label,
                          style: TextStyle(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                if (onEdit != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                    tooltip: '수정',
                    onPressed: onEdit,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // 시작일
            _DateRow(
              icon: Icons.event,
              label: '시작일',
              value: dateFormat.format(session.firstStartDate),
            ),
            const SizedBox(height: 6),
            // 종료일 또는 진행 중 표시
            if (session.completedDate != null)
              _DateRow(
                icon: Icons.event_available,
                label: '종료일',
                value: dateFormat.format(session.completedDate!),
              )
            else
              _DateRow(
                icon: Icons.more_time,
                label: '종료일',
                value: '진행 중',
                valueColor: Colors.orange,
              ),
            const Divider(height: 20),
            // 활독 시간
            Row(
              children: [
                Icon(Icons.timer_outlined, size: 16, color: Colors.grey[500]),
                const SizedBox(width: 6),
                Text('활독 시간',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                const Spacer(),
                Text(
                  _formatDuration(session.accumulatedActiveTime),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            // 읽은 기간 (완독한 경우)
            if (session.isCompleted && session.completedDate != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.date_range, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 6),
                  Text('읽은 기간',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[600])),
                  const Spacer(),
                  Text(
                    _readingPeriod(session),
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey[700]),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0분';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h == 0) return '$m분';
    return '$h시간 $m분';
  }

  static String _readingPeriod(ReadingSession session) {
    final duration =
        session.completedDate!.difference(session.firstStartDate);
    final days = duration.inHours ~/ 24;
    if (days == 0) return '1일';
    return '$days일';
  }
}

/// 날짜 라인 위젯
class _DateRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DateRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[500]),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        const Spacer(),
        Text(value,
            style: TextStyle(
              fontSize: 13,
              color: valueColor,
              fontWeight: valueColor != null ? FontWeight.w600 : null,
            )),
      ],
    );
  }
}
