import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../widgets/category_chip.dart';
import '../services/category_detector.dart';

class MemoDetailScreen extends StatefulWidget {
  final int memoId;

  const MemoDetailScreen({super.key, required this.memoId});

  @override
  State<MemoDetailScreen> createState() => _MemoDetailScreenState();
}

class _MemoDetailScreenState extends State<MemoDetailScreen> {
  final _databaseService = DatabaseService();
  Memo? _memo;
  bool _isLoading = true;
  bool _isEditing = false;

  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late TextEditingController _categoryController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _contentController = TextEditingController();
    _categoryController = TextEditingController();
    _loadMemo();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _loadMemo() async {
    final memo = await _databaseService.getMemoById(widget.memoId);
    if (mounted) {
      setState(() {
        _memo = memo;
        _isLoading = false;
        if (memo != null) {
          _titleController.text = memo.title;
          _contentController.text = memo.content;
          _categoryController.text = memo.category;
        }
      });
    }
  }

  void _enterEditMode() {
    if (_memo == null) return;
    _titleController.text = _memo!.title;
    _contentController.text = _memo!.content;
    _categoryController.text = _memo!.category;
    setState(() => _isEditing = true);
  }

  Future<void> _saveEdit() async {
    if (_memo == null) return;
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final category = _categoryController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('제목을 입력해주세요.')),
      );
      return;
    }

    // Normalize category to canonical name
    String finalCategory = category;
    if (category.isNotEmpty) {
      final normalized = AppCategories.normalize(category);
      if (normalized != null) {
        finalCategory = normalized;
      }
    }

    final updated = _memo!.copyWith(
      title: title,
      content: content,
      category: finalCategory,
      updatedAt: DateTime.now(),
    );

    await _databaseService.updateMemo(updated);

    if (mounted) {
      setState(() {
        _memo = updated;
        _isEditing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ 메모가 수정되었습니다.')),
      );
    }
  }

  void _cancelEdit() {
    setState(() => _isEditing = false);
  }

  Future<void> _deleteMemo() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('메모 삭제'),
        content: Text('"${_memo!.title}" 을(를) 삭제하시겠습니까?'),
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
      await _databaseService.deleteMemo(widget.memoId);
      if (mounted) Navigator.pop(context, true);
    }
  }

  void _copyContent() {
    if (_memo == null) return;
    final combined =
        '${_memo!.title}\n\n${_memo!.content}';
    Clipboard.setData(ClipboardData(text: combined));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📋 메모가 복사되었습니다.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _copyContentOnly() {
    if (_memo == null) return;
    Clipboard.setData(ClipboardData(text: _memo!.content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📋 내용이 복사되었습니다.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('링크를 열 수 없습니다: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_memo == null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        body: const Center(child: Text('메모를 찾을 수 없습니다.')),
      );
    }

    final memo = _memo!;
    final dateFormat = DateFormat('yyyy년 MM월 dd일 HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '메모 편집' : '메모 상세'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_isEditing) ...[
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '취소',
              onPressed: _cancelEdit,
            ),
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: '저장',
              onPressed: _saveEdit,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '전체 복사',
              onPressed: _copyContent,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '편집',
              onPressed: _enterEditMode,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
              onPressed: _deleteMemo,
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Category + Date row
            Row(
              children: [
                if (_isEditing)
                  Expanded(
                    child: TextField(
                      controller: _categoryController,
                      decoration: InputDecoration(
                        labelText: '카테고리',
                        hintText: '예: 요리 & 레시피, 개발',
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        isDense: true,
                        suffixIcon: PopupMenuButton<String>(
                          icon: const Icon(Icons.arrow_drop_down, size: 20),
                          onSelected: (cat) {
                            _categoryController.text = cat;
                          },
                          itemBuilder: (context) {
                            return AppCategories.all
                                .where((c) => c != '기타')
                                .map((cat) => PopupMenuItem(
                                      value: cat,
                                      child: Text(cat, style: const TextStyle(fontSize: 14)),
                                    ))
                                .toList();
                          },
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  )
                else
                  CategoryChip(category: memo.category),
                const SizedBox(width: 12),
                Text(
                  dateFormat.format(memo.createdAt),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Title
            if (_isEditing)
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '제목',
                  border: OutlineInputBorder(),
                ),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                maxLines: 2,
              )
            else
              Text(
                memo.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            const SizedBox(height: 8),

            // YouTube link
            if (memo.youtubeVideoId != null) ...[
              _buildYoutubeSection(context, memo),
              const SizedBox(height: 16),
            ],

            // Source URL
            if (memo.sourceUrl != null && memo.youtubeVideoId == null && !_isEditing) ...[
              Card(
                color: Colors.blue[50],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openUrl(memo.sourceUrl!),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.link, color: Colors.blue[600], size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            memo.sourceUrl!,
                            style: TextStyle(
                              color: Colors.blue[700],
                              fontSize: 13,
                              decoration: TextDecoration.underline,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.open_in_new,
                            color: Colors.blue[400], size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Separator
            const Divider(),

            // Content
            if (_isEditing) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '내용',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  TextButton.icon(
                    onPressed: _copyContentOnly,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('복사', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _contentController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.6,
                    ),
                maxLines: null,
                keyboardType: TextInputType.multiline,
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox.shrink(),
                  TextButton.icon(
                    onPressed: _copyContentOnly,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('내용 복사', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
              SelectableText(
                memo.content,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.6,
                    ),
              ),
            ],

            const SizedBox(height: 32),

            // Updated time
            if (memo.updatedAt != memo.createdAt)
              Text(
                '수정됨: ${dateFormat.format(memo.updatedAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[400],
                    ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildYoutubeSection(BuildContext context, Memo memo) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _openUrl(
            'https://www.youtube.com/watch?v=${memo.youtubeVideoId}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail placeholder
            Container(
              height: 180,
              width: double.infinity,
              color: Colors.grey[200],
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: Icon(Icons.play_circle_fill,
                        size: 56, color: Colors.red[600]),
                  ),
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow,
                              size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'YouTube',
                            style: TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.play_circle_outline,
                      size: 18, color: Colors.red[400]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'YouTube에서 영상 보기',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Icon(Icons.open_in_new,
                      size: 16, color: Colors.grey[500]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
