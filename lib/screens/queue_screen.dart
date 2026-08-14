import 'dart:async';
import 'package:flutter/material.dart';
import '../models/queue_state.dart';
import '../services/background_queue_service.dart';
import '../services/content_processing_service.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';
import 'memo_detail_screen.dart';

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final _processingService = ContentProcessingService();
  final _databaseService = DatabaseService();
  final _syncService = SyncService();
  QueueState _queueState = const QueueState(
    items: [],
    isProcessing: false,
    pendingCount: 0,
  );
  StreamSubscription<QueueState>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = _processingService.queueState.listen((state) {
      if (mounted) {
        setState(() => _queueState = state);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('처리 기록 삭제'),
        content: const Text('모든 처리 기록을 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // 원격(처리 이력)도 함께 삭제 — 로컬 삭제 전에 itemId 수집 후 soft delete push
      final historyItems = await _databaseService.getAllProcessingHistory();
      for (final item in historyItems) {
        _syncService.pushProcessingHistoryDelete(item.itemId).catchError((e) {
          debugPrint('[QueueScreen] 처리 이력 삭제 sync 오류: ${item.itemId} — $e');
        });
      }
      await _databaseService.clearAllProcessingHistory();
      // DB 기록만 지우면 2초 폴링이 native pending을 다시 읽어와서
      // UI에 계속 표시되므로 native 큐도 함께 비운다.
      await BackgroundQueueService().clearAll();
      await _processingService.loadHistoryIntoState();
    }
  }

  List<QueueItemProgress> get _activeItems =>
      _queueState.items.where((i) => !i.stage.isCompleted).toList();

  List<QueueItemProgress> get _historyItems =>
      _queueState.items.where((i) => i.stage.isCompleted).toList()
        ..sort((a, b) {
          // Most recent first
          final ta = a.completedAt ?? DateTime(2000);
          final tb = b.completedAt ?? DateTime(2000);
          return tb.compareTo(ta);
        });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('처리 현황'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_queueState.isProcessing)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          if (_queueState.completedCount + _queueState.failedCount > 0)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '기록 삭제',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final active = _activeItems;
    final history = _historyItems;

    if (active.isEmpty && history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64,
                color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              '처리 내역이 없습니다',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Text(
              'URL이나 텍스트를 공유하면 여기에 표시됩니다',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Summary bar
        _buildSummaryBar(),

        // Scrollable content area
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              // ── Active queue section ──
              if (active.isNotEmpty) ...[
                _buildSectionHeader(
                  icon: Icons.hourglass_bottom,
                  title: '처리 중 (${active.length})',
                  color: Theme.of(context).colorScheme.primary,
                ),
                ...active.map((item) => _buildActiveItemCard(item)),
                const SizedBox(height: 12),
              ],

              // ── History section ──
              if (history.isNotEmpty) ...[
                _buildSectionHeader(
                  icon: Icons.history,
                  title: '처리 기록 (${history.length})',
                  color: Colors.grey[600]!,
                ),
                ...history.map((item) => _buildHistoryItemTile(item)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Summary bar
  // ---------------------------------------------------------------------------

  Widget _buildSummaryBar() {
    final state = _queueState;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          _summaryChip(
            Icons.hourglass_bottom,
            '대기 ${state.pendingCount}',
            Colors.orange,
          ),
          const SizedBox(width: 10),
          _summaryChip(
            Icons.check_circle,
            '완료 ${state.completedCount}',
            Colors.green,
          ),
          const SizedBox(width: 10),
          _summaryChip(
            Icons.error_outline,
            '실패 ${state.failedCount}',
            Colors.red,
          ),
          const Spacer(),
          if (state.isProcessing)
            Text(
              '처리 중...',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Active (in-progress / queued) item card
  // ---------------------------------------------------------------------------

  Widget _buildActiveItemCard(QueueItemProgress item) {
    final isCurrent = item.isCurrent;
    final progressPercent = (item.progress * 100).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        elevation: isCurrent ? 2 : 0.5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: isCurrent
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  width: 1.5,
                )
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: emoji + preview + % + cancel button
              Row(
                children: [
                  Text(item.typeEmoji, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.displayPreview,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$progressPercent%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _activeProgressColor(item),
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.close),
                        color: Colors.red[400],
                        tooltip: '현재 건 취소 (나머지 큐는 유지)',
                        onPressed: () async {
                          await _processingService.cancelCurrentItem();
                        },
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: item.progress,
                  minHeight: 5,
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 4),

              // Status text row
              Row(
                children: [
                  if (isCurrent)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      item.statusText,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey[500],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _activeProgressColor(QueueItemProgress item) {
    if (item.progress < 0.3) return Colors.orange;
    if (item.progress < 0.7) return Colors.amber;
    return Colors.green;
  }

  // ---------------------------------------------------------------------------
  // History item tile (completed / failed)
  // ---------------------------------------------------------------------------

  Future<void> _onHistoryItemTap(QueueItemProgress item) async {
    int? memoId = item.memoId;

    // If no stored memoId, try to resolve by title
    if (memoId == null && item.memoTitle != null) {
      memoId = await _databaseService.getMemoIdByTitle(item.memoTitle!);
    }

    if (memoId == null || !mounted) return;

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MemoDetailScreen(memoId: memoId!),
      ),
    );
    if (changed == true) {
      // Memo was deleted — refresh queue state to keep in sync
      await _processingService.loadHistoryIntoState();
    }
  }

  Widget _buildHistoryItemTile(QueueItemProgress item) {
    final isSuccess = item.stage == ProcessingStage.completed;
    final timeStr = _formatTime(item.completedAt);
    final canOpen = isSuccess && (item.memoId != null || item.memoTitle != null);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Card(
        elevation: canOpen ? 0.5 : 0,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: canOpen ? () => _onHistoryItemTap(item) : null,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status icon
              Container(
                margin: const EdgeInsets.only(top: 1),
                child: Icon(
                  isSuccess ? Icons.check_circle : Icons.cancel,
                  size: 18,
                  color: isSuccess ? Colors.green[400] : Colors.red[400],
                ),
              ),
              const SizedBox(width: 10),

              // Content + meta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title (memoTitle if available) + content preview
                    if (item.memoTitle != null) ...[
                      Text(
                        item.memoTitle!,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      item.displayPreview,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: item.memoTitle != null ? FontWeight.w400 : FontWeight.w500,
                        color: isSuccess ? Colors.grey[700] : Colors.red[700],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),

                    // Meta row: type + time
                    Row(
                      children: [
                        Text(
                          item.typeEmoji,
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isSuccess ? '처리 완료' : '처리 실패',
                          style: TextStyle(
                            fontSize: 10,
                            color: isSuccess ? Colors.green[600] : Colors.red[500],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (timeStr != null) ...[
                          Text(
                            ' · ',
                            style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                          ),
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[400],
                            ),
                          ),
                        ],
                      ],
                    ),

                    // Error message if failed
                    if (!isSuccess && item.error != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.error!,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.red[300],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              // Retry button for failed items
              if (!isSuccess)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: const Icon(Icons.refresh),
                    color: Colors.orange[400],
                    tooltip: '재시도',
                    onPressed: () {
                      _processingService.retryFromHistory(item);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  /// Format a DateTime to a short relative time string.
  String? _formatTime(DateTime? dt) {
    if (dt == null) return null;
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inSeconds < 10) return '방금';
    if (diff.inMinutes < 1) return '${diff.inSeconds}초 전';
    if (diff.inHours < 1) return '${diff.inMinutes}분 전';
    if (diff.inDays < 1) {
      return '${diff.inHours}시간 전';
    }
    // Show date for older items
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
