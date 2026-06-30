import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/native_share_service.dart';
import '../widgets/memo_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/category_chip.dart';
import 'settings_screen.dart';
import 'memo_input_screen.dart';
import 'memo_detail_screen.dart';
import 'url_processing_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _databaseService = DatabaseService();
  final _llmService = LlmService();

  List<Memo> _memos = [];
  Map<String, int> _categoryCounts = {};
  String? _selectedCategory;
  bool _isLoading = true;
  bool _isAiAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _checkSharedContent();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedContent();
    }
  }

  Future<void> _initialize() async {
    _isAiAvailable = await _llmService.isAvailable();
    await _loadMemos();
  }

  Future<void> _checkSharedContent() async {
    final sharedText = await NativeShareService.getSharedText();
    if (sharedText != null && sharedText.isNotEmpty && mounted) {
      _handleSharedText(sharedText);
    }
  }

  void _handleSharedText(String text) {
    // Check if it's a URL
    final isUrl = text.startsWith('http://') || text.startsWith('https://');
    if (isUrl) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UrlProcessingScreen(sharedUrl: text),
        ),
      ).then((_) => _loadMemos());
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MemoInputScreen(
            initialContent: text,
          ),
        ),
      ).then((_) => _loadMemos());
    }
  }

  Future<void> _loadMemos() async {
    setState(() => _isLoading = true);
    try {
      final memos = await _databaseService.getAllMemos();
      final categoryCounts = await _databaseService.getMemoCountByCategory();
      if (mounted) {
        setState(() {
          _memos = memos;
          _categoryCounts = categoryCounts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Memo> get _filteredMemos {
    if (_selectedCategory == null) return _memos;
    return _memos.where((m) => m.category == _selectedCategory).toList();
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
        title: const Text('Aimemo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_isAiAvailable)
            IconButton(
              icon: Icon(Icons.warning_amber_rounded, color: Colors.orange[700]),
              tooltip: 'AI 모델 연결 필요',
              onPressed: () => _openSettings(),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _openSettings(),
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
                  _buildCategoryChip('전체', null),
                  ..._categoryCounts.entries.map((entry) {
                    return _buildCategoryChip(
                      '${entry.key} (${entry.value})',
                      entry.key,
                    );
                  }),
                ],
              ),
            ),

          // Memo list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredMemos.isEmpty
                    ? (_selectedCategory == null
                        ? EmptyState(
                            icon: Icons.note_alt_outlined,
                            title: '아직 메모가 없습니다',
                            subtitle: _isAiAvailable
                                ? '하단 + 버튼을 눌러 메모를 추가하거나\nYouTube에서 영상을 공유해보세요!'
                                : '설정에서 AI 모델 제공자를 연결해주세요.',
                            action: !_isAiAvailable
                                ? FilledButton.tonalIcon(
                                    onPressed: _openSettings,
                                    icon: const Icon(Icons.settings),
                                    label: const Text('설정으로 이동'),
                                  )
                                : null,
                          )
                        : EmptyState(
                            icon: Icons.filter_alt_off,
                            title: '이 카테고리의 메모가 없습니다',
                            subtitle: '다른 카테고리를 선택해보세요',
                          ))
                    : RefreshIndicator(
                        onRefresh: _loadMemos,
                        child: ListView.builder(
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openMemoInput(),
        child: const Icon(Icons.add),
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

  Future<void> _openSettings() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    _isAiAvailable = await _llmService.isAvailable();
    setState(() {});
  }

  Future<void> _openMemoInput() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MemoInputScreen()),
    );
    if (result == true) {
      await _loadMemos();
    }
  }

  Future<void> _openMemoDetail(Memo memo) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MemoDetailScreen(memoId: memo.id!)),
    );
    if (result == true) {
      await _loadMemos();
    }
  }
}
