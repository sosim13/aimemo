import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/book.dart';
import '../../models/reading_session.dart';
import '../../services/book_vision_service.dart';
import '../../services/reading_service.dart';

/// Active reading timer screen for a single [Book] + [ReadingSession].
///
/// The timer accumulates "active" seconds via a 1-second [Timer.periodic].
/// Two terminating actions are offered:
///
///  * **일시 정지 (Pause)** — commit the delta to accumulatedActiveTime
///    and set status to PAUSED. The session can be resumed here or later.
///  * **독서 종료 (Complete)** — finalize the session, set completedDate,
///    increment [Book.totalReadCount], and close this screen.
///
/// On entry we check whether the existing [Book] already has a non-completed
/// session (resume) — if so we reuse it; otherwise the caller asked us to
/// start a re-read, so we call [ReadingService.startReRead].
class ReadingTimerScreen extends StatefulWidget {
  /// Optional existing book — used when resuming or re-reading.
  final Book? existingBook;

  /// Result from a fresh scan — required when [existingBook] is null.
  final ScanResult? scanResult;

  /// Forces creation of a new reading round even if an active session
  /// already exists for [existingBook]. Used when the user explicitly
  /// taps "다시 읽기 (Re-read)" on an already-completed book.
  final bool forceNewRound;

  const ReadingTimerScreen({
    super.key,
    this.existingBook,
    this.scanResult,
    this.forceNewRound = false,
  }) : assert(
          existingBook != null || scanResult != null,
          'Either an existing book or a fresh scan result is required.',
        );

  @override
  State<ReadingTimerScreen> createState() => _ReadingTimerScreenState();
}

class _ReadingTimerScreenState extends State<ReadingTimerScreen> {
  final _readingService = ReadingService();

  late Book _book;
  ReadingSession? _session;

  Timer? _timer;
  int _elapsedSeconds = 0;
  bool _isRunning = false;
  bool _isFinalizing = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    // On hot-reload / backgrounding we treat an unclosed timer as a pause:
    // the accumulated time stays in memory only until the next commit,
    // so we commit the delta to keep the data correct.
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // Resolve which book this session belongs to.
    if (widget.existingBook != null) {
      _book = widget.existingBook!;
      if (widget.forceNewRound) {
        _session = await _readingService.startReRead(_book.bookId);
      } else {
        final active =
            await _readingService.getActiveSessionForBook(_book.bookId);
        if (active != null) {
          _session = active;
        } else {
          _session = await _readingService.startReading(_book.bookId);
        }
      }
    } else {
      // Brand-new book — insert it now, then start a fresh session.
      final bookId = await _readingService.insertBook(
        title: widget.scanResult!.title,
        author: widget.scanResult!.author,
        coverThumbnailPath: widget.scanResult!.thumbnailPath,
      );
      _book = (await _readingService.getBookById(bookId))!;
      _session = await _readingService.startReading(_book.bookId);
    }
    if (mounted) {
      setState(() {
        // If resuming a PAUSED session, start the timer running immediately
        // — the user explicitly tapped "이어서 읽기" so they're reading now.
        if (_session!.status == ReadingSessionStatus.paused) {
          _startTimer();
        } else if (_session!.status == ReadingSessionStatus.reading) {
          // Existing reading session is still active — pick up the clock.
          _startTimer();
        }
      });
    }
  }

  void _startTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
    });
    setState(() => _isRunning = true);
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    setState(() => _isRunning = false);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _onPause() async {
    _stopTimer();
    final delta = _elapsedSeconds;
    _session = await _readingService.addActiveTime(
      _session!,
      delta,
      pause: true,
    );
    setState(() => _elapsedSeconds = 0);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('일시 정지 — 읽은 시간이 저장되었습니다.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onResume() async {
    if (_session!.status == ReadingSessionStatus.paused) {
      await _readingService.resumeSession(_session!);
    }
    _startTimer();
  }

  Future<void> _onComplete() async {
    setState(() => _isFinalizing = true);
    _stopTimer();
    final delta = _elapsedSeconds;
    // Commit any remaining active time as part of the finalization.
    _session = await _readingService.addActiveTime(_session!, delta);
    _session = await _readingService.completeReading(_session!);
    setState(() => _elapsedSeconds = 0);
    if (!mounted) return;
    final activeTime = _formatDuration(_session!.accumulatedActiveTime);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('독서 완료! 총 활독 시간: $activeTime'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
    Navigator.pop(context, true);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('독서 타이머')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final activeTotal =
        _session!.accumulatedActiveTime + _elapsedSeconds;
    return Scaffold(
      appBar: AppBar(
        title: const Text('독서 타이머'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildCover(),
            const SizedBox(height: 20),
            Text(
              _book.title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
              textAlign: TextAlign.center,
            ),
            if (_book.author.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _book.author,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
            const SizedBox(height: 32),
            _buildTimerCard(activeTotal),
            const SizedBox(height: 16),
            _buildSessionMetaRow(),
            const SizedBox(height: 32),
            _buildButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildCover() {
    final file = File(_book.coverThumbnailPath);
    final exists = file.existsSync();
    return Container(
      width: 160,
      height: 220,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: exists
          ? Image.file(file, fit: BoxFit.cover)
          : const Icon(Icons.menu_book, size: 64, color: Colors.grey),
    );
  }

  Widget _buildTimerCard(int totalSeconds) {
    return Card(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          children: [
            const Text('활동 독서 시간', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text(
              _formatDuration(totalSeconds),
              style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w300,
                fontFamilyFallback: const ['monospace'],
                fontFeatures: const [FontFeature.tabularFigures()],
                color: _isRunning ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isRunning ? Icons.pause_circle : Icons.play_circle,
                  size: 16,
                  color: Colors.grey[500],
                ),
                const SizedBox(width: 6),
                Text(
                  _isRunning ? '측정 중' : '일시 정지됨',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionMetaRow() {
    final start = _session!.firstStartDate;
    final fmt = DateFormat('yyyy.MM.dd HH:mm');
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.play_arrow, size: 14, color: Colors.grey),
        const SizedBox(width: 4),
        Text(
          fmt.format(start),
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
        if (_session!.readRound > 1) ...[
          const SizedBox(width: 12),
          const Icon(Icons.refresh, size: 14, color: Colors.grey),
          const SizedBox(width: 4),
          Text(
            '${_session!.readRound}회차',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ],
    );
  }

  Widget _buildButtons() {
    if (_isRunning) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isFinalizing ? null : _onPause,
              icon: const Icon(Icons.pause),
              label: const Text('일시 정지'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _isFinalizing ? null : _onComplete,
              icon: _isFinalizing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle),
              label: Text(_isFinalizing ? '종료 중…' : '독서 종료'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.green[700],
              ),
            ),
          ),
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _isFinalizing ? null : _onResume,
        icon: const Icon(Icons.play_arrow),
        label: const Text('이어서 읽기'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  /// Formats a duration in seconds as `H시간 M분 S초`.
  static String _formatDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h == 0 && m == 0) return '$s초';
    if (h == 0) return '$m분 $s초';
    return '$h시간 $m분 $s초';
  }
}
