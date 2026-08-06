import 'dart:async';
import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/native_share_service.dart';
import '../services/content_processing_service.dart';
import '../services/background_queue_service.dart';
import '../services/reading_service.dart';
import '../services/shared_content_parser.dart';
import '../widgets/memo_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/category_chip.dart';
import 'memo_input_screen.dart';
import 'memo_detail_screen.dart';
import 'reading/reading_dashboard_screen.dart';


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _databaseService = DatabaseService();
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
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _processingSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedContent();
      _loadMemos();  // 백그라운드에서 처리된 메모 반영
    }
  }

  Future<void> _initialize() async {
    _isAiAvailable = await _llmService.isAvailable();
    await _loadMemos();
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

  Future<void> _loadMemos() async {
    // Save current scroll offset before reload
    final savedOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    setState(() => _isLoading = true);
    try {
      final memos = await _databaseService.getAllMemos();
      final categoryCounts = await _databaseService.getMemoCountByCategory();
      // Reading Tracker: books are kept in a separate table. Inject a
      // "독서" chip when there's at least one registered book so the user
      // can reach the dashboard from the category filter bar.
      final books = await ReadingService().getAllBooks();
      if (books.isNotEmpty) {
        categoryCounts['독서'] = books.length;
      }
      if (mounted) {
        setState(() {
          _memos = memos;
          _categoryCounts = categoryCounts;
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

  List<Memo> get _filteredMemos {
    var memos = _memos;

    // Category filter
    if (_selectedCategory != null) {
      memos = memos.where((m) => m.category == _selectedCategory).toList();
    }

    // Simple text search filter (title, content, category)
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      memos = memos.where((m) =>
        m.title.toLowerCase().contains(query) ||
        m.content.toLowerCase().contains(query) ||
        m.category.toLowerCase().contains(query)
      ).toList();
    }

    return memos;
  }

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
      await _databaseService.deleteMemo(memo.id!);
      await _loadMemos();
    }
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
                  _buildCategoryChip('전체 (${_memos.length})', null),
                  ..._categoryCounts.entries.map((entry) {
                    return _buildCategoryChip(
                      '${entry.key} (${entry.value})',
                      entry.key,
                    );
                  }),
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
                            setState(() => _searchQuery = '');
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
                          itemCount: _filteredMemos.length,
                          itemBuilder: (context, index) {
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
          // Reading Tracker: tapping the '독서' chip opens the dashboard
          // instead of filtering the main memo list inline — books are
          // stored in their own table, not the memos table.
          if (selected && category == '독서') {
            _openReadingDashboard();
            return;
          }
          setState(() => _selectedCategory = selected ? category : null);
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

  Future<void> _openReadingDashboard() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ReadingDashboardScreen()),
    );
    // Books live in a separate table from memos, so the main memo list
    // doesn't need to reload here.
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

  void _toggleSearch() {
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
