import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/memo.dart';
import '../services/background_queue_service.dart';
import '../services/category_detector.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/shared_content_parser.dart';
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

    await _databaseService.insertMemo(Memo(
      title: title,
      content: content,
      category: category,
    ));

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
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: buildMemoForm(),
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
