import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/memo.dart';
import '../models/reading_session.dart';
import '../screens/reading/camera_scan_screen.dart';
import '../screens/reading/reading_timer_screen.dart';
import '../services/background_queue_service.dart';
import '../services/book_vision_service.dart';
import '../services/category_detector.dart';
import '../services/content_processing_service.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/reading_service.dart';
import '../services/shared_content_parser.dart';
import '../services/sync_service.dart';
import '../services/tiktok_service.dart';
import '../services/url_handler_service.dart';
import '../services/youtube_service.dart';

class MemoInputScreen extends StatefulWidget {
  final String? initialUrl;
  final String? initialContent;
  final String? youtubeVideoId;

  const MemoInputScreen({
    super.key,
    this.initialUrl,
    this.initialContent,
    this.youtubeVideoId,
  });

  @override
  State<MemoInputScreen> createState() => _MemoInputScreenState();
}

class _MemoInputScreenState extends State<MemoInputScreen> {
  final _contentController = TextEditingController();
  final _databaseService = DatabaseService();
  final _syncService = SyncService();
  final _llmService = LlmService();
  final _urlHandler = UrlHandlerService();
  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();
  final _backgroundQueue = BackgroundQueueService();

  bool _isAiAvailable = false;
  bool _isSubmitting = false;

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: isError ? Colors.red[600] : Colors.green[600],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final available = await _llmService.isAvailable();
    if (widget.initialContent != null) {
      _contentController.text = widget.initialContent!;
    }
    if (mounted) {
      setState(() => _isAiAvailable = available);
    }

    // If a URL was shared from another app, process it via background queue
    if (widget.initialUrl != null && available) {
      await _processSharedUrl();
    }
  }

  /// Process a shared URL (YouTube, TikTok, or web page) via background queue.
  Future<void> _processSharedUrl() async {
    setState(() => _isSubmitting = true);

    final items = SharedContentParser.parse(widget.initialUrl!);
    if (items.isNotEmpty) {
      await _backgroundQueue.enqueueItems(items);
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    _showSnackBar('URL 처리가 백그라운드에서 진행됩니다.');
    Navigator.pop(context, true);
  }

  /// Save manually entered text — auto-generates title and category.
  Future<void> _saveMemo() async {
    final content = _contentController.text.trim();

    if (content.isEmpty) {
      _showSnackBar('내용을 입력해주세요.', isError: true);
      return;
    }

    setState(() => _isSubmitting = true);

    // Auto-generate title from first line
    final firstLine = content.split('\n').first.trim();
    final title = firstLine.length > 30
        ? '${firstLine.substring(0, 30)}...'
        : firstLine;

    // Auto-detect category via keyword matching (no LLM needed)
    final detected = CategoryDetector.detect(content);
    final category = (detected != null && detected != '기타') ? detected : '기타';

    final memo = Memo(
      title: title,
      content: content,
      category: category,
      searchKeyword: ContentProcessingService.extractSearchKeyword(content),
    );
    final id = await _databaseService.insertMemo(memo);
    final saved = memo.copyWith(id: id);
    // Supabase 동기화 (비로그인 시 no-op)
    _syncService.debouncePushMemo(saved);

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    _showSnackBar('메모가 저장되었습니다.');
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메모 작성'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '독서 기록 시작',
            onPressed: _openReadingScanner,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: buildMemoForm(),
      ),
    );
  }

  /// Reading Tracker entry point — opens the camera, scans the cover,
  /// matches against existing books, then jumps into the timer screen.
  ///
  /// The flow:
  ///   1. Open [CameraScanScreen]. User captures the cover.
  ///   2. Gemma 4 E2B recognizes the title & author and crops the cover
  ///      to a local thumbnail.
  ///   3. Look the title up against the local DB.
  ///      - Active (READING/PAUSED) session: show [ReadingTimerScreen]
  ///        with the existing book for "이어서 읽기".
  ///      - Only COMPLETED sessions: show [ReadingTimerScreen] with
  ///        [ReadingTimerScreen.forceNewRound] for "다시 읽기".
  ///      - No match at all: open [ReadingTimerScreen] with the
  ///        [ScanResult] to register a brand-new book.
  Future<void> _openReadingScanner() async {
    final scanResult = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScanScreen()),
    );
    if (scanResult == null || !mounted) return;

    // Show the OCR result to the user for confirmation / editing.
    // Gemma 4 E2B's OCR can make mistakes (e.g., "Guide o the galaxy"
    // instead of "Guide to the Galaxy"), so we let the user fix it.
    final edited = await _showScanResultEditor(scanResult);
    if (edited == null || !mounted) return; // cancelled
    final confirmedScan = edited;

    final readingService = ReadingService();
    final existing = await readingService.findBookByTitle(confirmedScan.title);

    Book? book;
    bool forceNewRound = false;

    if (existing != null) {
      final active =
          await readingService.getActiveSessionForBook(existing.bookId);
      if (active != null) {
        // Reading is in progress (READING) so they can resume implicitly in
        // the timer screen. PAUSED sessions also fall here for one-tap
        // resume; we surface the choice in a quick dialog.
        book = existing;
        if (active.status == ReadingSessionStatus.paused) {
          // Confirm resume vs start a fresh round, since paused ≠ forced.
          final decision = await _askResumeOrReread();
          if (decision == null) return; // cancelled
          if (decision) {
            // Resume — open timer with the existing book, no new round.
            book = existing;
            forceNewRound = false;
          } else {
            // Treat as a fresh round.
            book = existing;
            forceNewRound = true;
          }
        }
      } else {
        // All sessions completed (or no session) — offer to re-read.
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
          scanResult: book == null ? confirmedScan : null,
          forceNewRound: forceNewRound,
        ),
      ),
    );
    // No setState needed — we navigated to a self-contained flow.
  }

  /// Shows a dialog with the OCR-recognized title and author, allowing
  /// the user to confirm or edit before proceeding to the reading timer.
  /// Returns null when cancelled, or a [ScanResult] with the (possibly
  /// edited) title and author. The thumbnail path is preserved.
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
            // Thumbnail preview
            if (scan.thumbnailPath.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(scan.thumbnailPath),
                  width: 120,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 120,
                    height: 160,
                    child: Icon(Icons.book, size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              '스캔된 정보가 정확한지 확인해주세요.',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: '제목',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.book),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: authorCtrl,
              decoration: const InputDecoration(
                labelText: '저자',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
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

  /// Quick dialog: "이어서 읽기" (resume) vs "새 회차 시작" (re-read) for a
  /// paused book. Returns `true` for resume, `false` for re-read, `null`
  /// when cancelled.
  Future<bool?> _askResumeOrReread() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이어서 읽기'),
        content: const Text('이 책은 일시 정지된 상태입니다. 어떻게 진행할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('취소'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('새 회차 시작'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('이어서 읽기'),
          ),
        ],
      ),
    );
  }

  /// Confirm dialog for "다시 읽기" when all sessions for an existing book
  /// are completed. Returns `true` when the user confirms re-reading.
  Future<bool?> _askReread() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('다시 읽기'),
        content: const Text('이미 완독한 책입니다. 새 회차로 다시 읽으시겠어요?'),
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

  Widget buildMemoForm() {
    final hasSharedUrl = widget.initialUrl != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasSharedUrl) ...[
          Card(
            color: Colors.blue[50],
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.link, color: Colors.blue[600]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.initialUrl!,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _contentController,
          maxLines: 12,
          minLines: 6,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '메모할 내용을 입력하세요\n\n'
                '제목과 카테고리는 자동으로 생성됩니다.',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _isSubmitting ? null : _saveMemo,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(_isSubmitting ? '저장 중...' : '저장'),
          ),
        ),
        if (!_isAiAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '※ 제목은 첫 줄, 카테고리는 내용 기반으로 자동 생성됩니다.',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ),
      ],
    );
  }
}
