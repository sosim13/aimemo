import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/memo.dart';
import '../models/reading_session.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/native_share_service.dart';
import '../services/content_processing_service.dart';
import '../services/background_queue_service.dart';
import '../services/reading_service.dart';
import '../services/shared_content_parser.dart';
import '../services/sync_service.dart';
import '../widgets/memo_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/category_chip.dart';
import 'memo_input_screen.dart';
import 'memo_detail_screen.dart';
import 'reading/camera_scan_screen.dart';
import 'reading/reading_timer_screen.dart';
import '../services/book_vision_service.dart';


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _databaseService = DatabaseService();
  final _syncService = SyncService();
  final _llmService = LlmService();
  final _processingService = ContentProcessingService();
  final _backgroundQueue = BackgroundQueueService();

  /// Scroll controller for the memo list — preserves scroll position
  /// after returning from detail view or reloading memos.
  final ScrollController _scrollController = ScrollController();

  List<Memo> _memos = [];
  Map<String, int> _categoryCounts = {};
  String? _selectedCategory;
  bool _isLoading = true;
  bool _isAiAvailable = false;

  /// 무한 스크롤 페이지네이션 — 한 번에 10개씩만 불러온다.
  static const _pageSize = 10;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  /// 검색어 입력 시 매 글자마다 DB 쿼리를 날리지 않도록 디바운스.
  Timer? _searchDebounce;

  /// "맛집 & 카페" 카테고리에서만 쓰는 "지도 정보 없는 메모만 보기" 필터.
  static const _noLocationCategory = '맛집 & 카페';
  bool _noLocationOnly = false;

  /// Simple text search state
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  StreamSubscription<ProcessingResult>? _processingSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _initialize();

    // Listen for background processing results to refresh UI
    _processingSubscription = _processingService.onItemProcessed.listen((result) {
      if (!mounted) return;
      _loadMemos();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.success
              ? '✅ 메모가 저장되었습니다'
              : '❌ 처리 실패: ${result.error ?? "알 수 없는 오류"}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _processingSubscription?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedContent();
      _loadMemos();  // 백그라운드에서 처리된 메모 반영
      // Supabase에서 메모 pull (비로그인 시 no-op)
      _syncService.pullFromSupabase().catchError((e) {
        debugPrint('[Home] pullFromSupabase 오류: $e');
      });
      _syncService.processSyncQueue().catchError((e) {
        debugPrint('[Home] processSyncQueue 오류: $e');
      });
    }
  }

  Future<void> _initialize() async {
    // 메모 목록(로컬 DB)을 먼저 로드해 화면에 표시하고,
    // AI 가용성 체크(및 이어지는 클라우드 동기화)는 그 이후에 진행한다.
    await _loadMemos();
    if (!mounted) return;
    final aiAvailable = await _llmService.isAvailable();
    if (mounted) {
      setState(() => _isAiAvailable = aiAvailable);
    }
  }

  Future<void> _checkSharedContent() async {
    final sharedText = await NativeShareService.getSharedText();
    if (sharedText != null && sharedText.isNotEmpty && mounted) {
      await _handleSharedText(sharedText);
    }
  }

  Future<void> _handleSharedText(String text) async {
    final items = SharedContentParser.parse(text);
    await _backgroundQueue.enqueueItems(items);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            items.length > 1
                ? '${items.length}개 링크를 큐에 추가했습니다.'
                : '백그라운드에서 요약 중입니다.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// 첫 페이지(10개)를 새로 불러온다 — 카테고리/검색 필터가 바뀌었을 때,
  /// 또는 새로고침(pull-to-refresh)/외부 변경 반영 시 호출.
  Future<void> _loadMemos() async {
    // Save current scroll offset before reload
    final savedOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    setState(() => _isLoading = true);
    try {
      final categoryCounts = await _databaseService.getMemoCountByCategory();
      final memos = await _databaseService.getMemosPage(
        limit: _pageSize,
        offset: 0,
        category: _selectedCategory,
        searchQuery: _searchQuery,
        noLocationOnly: _noLocationOnly,
      );
      // 독서 기록은 이제 전체메뉴(더보기)에서 접근 — 카테고리 chip에서 제거.
      // books가 '독서' 카테고리에 노출되지 않도록 주입하지 않음.
      if (mounted) {
        setState(() {
          _memos = memos;
          _categoryCounts = categoryCounts;
          _hasMore = memos.length == _pageSize;
          _isLoading = false;
        });
        // Restore scroll position after the frame renders
        if (savedOffset > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                savedOffset.clamp(
                  0.0,
                  _scrollController.position.maxScrollExtent,
                ),
              );
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 목록 끝에 가까워지면 다음 10개를 이어서 불러온다.
  void _onScroll() {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _loadMoreMemos();
    }
  }

  Future<void> _loadMoreMemos() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final nextPage = await _databaseService.getMemosPage(
        limit: _pageSize,
        offset: _memos.length,
        category: _selectedCategory,
        searchQuery: _searchQuery,
        noLocationOnly: _noLocationOnly,
      );
      if (mounted) {
        setState(() {
          _memos = [..._memos, ...nextPage];
          _hasMore = nextPage.length == _pageSize;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  /// 카테고리/검색 필터는 이미 DB 쿼리 단계에서 적용되어 있으므로
  /// 화면에는 로드된 목록을 그대로 보여준다.
  List<Memo> get _filteredMemos => _memos;

  /// 카테고리 무관, 전체 메모 개수 (검색 필터와도 무관 — 상단 "전체" 칩용).
  int get _totalMemoCount =>
      _categoryCounts.values.fold(0, (sum, count) => sum + count);

  Future<void> _deleteMemo(Memo memo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('메모 삭제'),
        content: Text('"${memo.title}" 을(를) 삭제하시겠습니까?'),
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
      // 소프트 삭제 — SyncService가 원격에도 반영 (비로그인 시 no-op).
      await _databaseService.softDeleteMemo(memo.id!);
      _syncService.pushMemoDelete(memo.memoId).catchError((e) {
        debugPrint('[Home] pushMemoDelete 오류: $e');
      });
      await _loadMemos();
    }
  }

  /// "$_noLocationCategory" 카테고리에서 지도 정보(좌표)가 없는 메모를
  /// 한 번에 모두 삭제한다. 목록에 로드된 것만이 아니라 조건에 맞는 전체를 대상으로 한다.
  Future<void> _deleteAllNoLocationMemos() async {
    final targets = await _databaseService.getAllMemosMissingLocation(
      _noLocationCategory,
    );
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('지도 정보가 없는 메모가 없습니다'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('전체 삭제'),
        content: Text(
          '지도 정보가 없는 "$_noLocationCategory" 메모 ${targets.length}개를 '
          '모두 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.',
        ),
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
    if (confirm != true || !mounted) return;

    setState(() => _isLoading = true);
    for (final memo in targets) {
      // 소프트 삭제 — SyncService가 원격에도 반영 (비로그인 시 no-op).
      await _databaseService.softDeleteMemo(memo.id!);
      _syncService.pushMemoDelete(memo.memoId).catchError((e) {
        debugPrint('[Home] pushMemoDelete 오류: $e');
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${targets.length}개 메모를 삭제했습니다'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
    await _loadMemos();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              Icons.auto_stories_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 10),
            const Text('Aimemo'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.search_off : Icons.search),
            tooltip: _isSearching ? '검색 닫기' : '메모 검색',
            onPressed: () => _toggleSearch(),
          ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '독서 기록 시작',
            onPressed: _openReadingScanner,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '메모 추가',
            onPressed: () => _openMemoInput(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Category filter bar
          if (_categoryCounts.isNotEmpty)
            Container(
              height: 52,
              margin: const EdgeInsets.only(top: 8),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _buildCategoryChip('전체 (${_totalMemoCount})', null),
                  ..._categoryCounts.entries.map((entry) {
                    return _buildCategoryChip(
                      '${entry.key} (${entry.value})',
                      entry.key,
                    );
                  }),
                ],
              ),
            ),

          // "맛집 & 카페" 카테고리에서만 노출되는 "지도 정보 없음" 필터 + 전체 삭제
          if (_selectedCategory == _noLocationCategory)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setState(() => _noLocationOnly = !_noLocationOnly);
                        _loadMemos();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(
                              _noLocationOnly
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              size: 20,
                              color: _noLocationOnly
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey[600],
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '지도 정보 없는 메모만 보기',
                              style: TextStyle(
                                fontSize: 13,
                                color: _noLocationOnly
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey[700],
                                fontWeight: _noLocationOnly
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_noLocationOnly)
                    TextButton.icon(
                      onPressed: _deleteAllNoLocationMemos,
                      icon: const Icon(
                        Icons.delete_sweep_outlined,
                        size: 18,
                        color: Colors.red,
                      ),
                      label: const Text(
                        '전체 삭제',
                        style: TextStyle(color: Colors.red, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),

          // Search bar
          if (_isSearching)
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                decoration: InputDecoration(
                  hintText: '제목, 내용, 카테고리 검색...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _searchDebounce?.cancel();
                            setState(() => _searchQuery = '');
                            _loadMemos();
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 14),
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                    if (mounted) _loadMemos();
                  });
                },
              ),
            ),

          // Memo list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredMemos.isEmpty
                    ? (_searchQuery.isNotEmpty
                        ? EmptyState(
                            icon: Icons.search_off,
                            title: '검색 결과가 없습니다',
                            subtitle: '"$_searchQuery"에 해당하는 메모가 없습니다',
                          )
                        : _noLocationOnly
                        ? const EmptyState(
                            icon: Icons.location_on_outlined,
                            title: '지도 정보 없는 메모가 없습니다',
                            subtitle: '이 카테고리의 메모에는 모두 지도 정보가 있어요',
                          )
                        : _selectedCategory == null
                        ? EmptyState(
                            icon: Icons.note_alt_outlined,
                            title: '아직 메모가 없습니다',
                            subtitle: _isAiAvailable
                                ? '상단 + 버튼을 눌러 메모를 추가하거나\nYouTube에서 영상을 공유해보세요!'
                                : '설정에서 AI 모델 제공자를 연결해주세요.',
                            action: null,
                          )
                        : EmptyState(
                            icon: Icons.filter_alt_off,
                            title: '이 카테고리의 메모가 없습니다',
                            subtitle: '다른 카테고리를 선택해보세요',
                          ))
                    : RefreshIndicator(
                        onRefresh: _loadMemos,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(top: 8, bottom: 80),
                          // 목록 끝에 "더 불러오는 중" 표시용 아이템 1개 추가
                          // (더 불러올 데이터가 있을 때만).
                          itemCount:
                              _filteredMemos.length + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _filteredMemos.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final memo = _filteredMemos[index];
                            return MemoCard(
                              memo: memo,
                              onTap: () => _openMemoDetail(memo),
                              onDelete: () => _deleteMemo(memo),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(String label, String? category) {
    final isSelected = _selectedCategory == category;
    final color = category != null
        ? CategoryChip.getColor(category)
        : Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (selected) {
          final newCategory = selected ? category : null;
          setState(() {
            _selectedCategory = newCategory;
            if (newCategory != _noLocationCategory) {
              _noLocationOnly = false;
            }
          });
          _loadMemos();
        },
        selectedColor: color.withValues(alpha: 0.2),
        checkmarkColor: color,
        labelStyle: TextStyle(
          color: isSelected ? color : null,
          fontWeight: isSelected ? FontWeight.w600 : null,
          fontSize: 13,
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _openMemoInput() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const MemoInputScreen()),
    );
    if (result == true && mounted) {
      await _loadMemos();
    }
  }

  /// Reading Tracker entry point — opens the camera, scans the cover,
  /// matches against existing books, then jumps into the timer screen.
  Future<void> _openReadingScanner() async {
    final scanResult = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScanScreen()),
    );
    if (scanResult == null || !mounted) return;

    final edited = await _showScanResultEditor(scanResult);
    if (edited == null || !mounted) return;
    final confirmedScan = edited;

    final readingService = ReadingService();
    final existing = await readingService.findBookByTitle(confirmedScan.title);

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
          scanResult: book == null ? confirmedScan : null,
          forceNewRound: forceNewRound,
        ),
      ),
    );
    if (mounted) await _loadMemos();
  }

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
                  width: 120, height: 160, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 120, height: 160,
                    child: Icon(Icons.book, size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text('스캔된 정보가 정확한지 확인해주세요.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: '제목', border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.book),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: authorCtrl,
              decoration: const InputDecoration(
                labelText: '저자', border: OutlineInputBorder(),
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
            onPressed: () => Navigator.pop(context, ScanResult(
              title: titleCtrl.text.trim(),
              author: authorCtrl.text.trim(),
              thumbnailPath: scan.thumbnailPath,
            )),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

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

  void _toggleSearch() {
    final wasSearching = _isSearching && _searchQuery.isNotEmpty;
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
        _searchFocusNode.unfocus();
      } else {
        // Focus the search field after the frame renders
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
    });
    // 검색어가 있는 상태로 검색창을 닫았다면 필터 없이 다시 로드.
    if (wasSearching) {
      _searchDebounce?.cancel();
      _loadMemos();
    }
  }

  Future<void> _openMemoDetail(Memo memo) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => MemoDetailScreen(memoId: memo.id!)),
    );
    // Only reload if memo was deleted (pop returned true).
    // Otherwise scroll position is preserved.
    if (changed == true) {
      await _loadMemos();
    }
  }
}
