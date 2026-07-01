import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/memo.dart';
import '../services/background_queue_service.dart';
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
  final _titleController = TextEditingController();
  final _categoryController = TextEditingController();
  final _urlController = TextEditingController();
  final _databaseService = DatabaseService();
  final _llmService = LlmService();
  final _urlHandler = UrlHandlerService();
  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();
  final _backgroundQueue = BackgroundQueueService();

  bool _isAiAvailable = false;
  bool _manualMode = false;
  bool _isSubmitting = false;

  /// Direct file fallback logger — bypasses DebugLogger entirely.
  /// Auto-truncates to 300 lines to prevent unbounded growth.
  Future<void> _diag(String msg) async {
    // ignore: avoid_print
    print('[DIAG_MIS] $msg');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/mis_diag.txt');
      final ts = DateTime.now().toIso8601String();
      final line = '[$ts] $msg\n';

      // Check file size: truncate if > 100KB (about 500+ lines)
      if (await f.exists()) {
        final len = await f.length();
        if (len > 100 * 1024) {
          // Keep only last 50 lines
          final existing = await f.readAsLines();
          final tail = existing.length > 50
              ? existing.sublist(existing.length - 50)
              : existing;
          await f.writeAsString('${tail.join('\n')}\n');
        }
      }

      await f.writeAsString(line, mode: FileMode.append);
    } catch (_) {}
  }

  /// Check if [text] looks like a general web page URL (not YouTube/TikTok)
  bool _isWebUrl(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null) return false;
    // Must have a scheme (http/https) and a host with a dot (e.g. m.10000recipe.com)
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (!uri.host.contains('.')) return false;
    // Exclude already-handled types
    if (_youtubeService.isYouTubeUrl(text)) return false;
    if (_tiktokService.isTikTokUrl(text)) return false;
    return true;
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.auto_awesome,
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
    if (widget.initialUrl != null) {
      _urlController.text = widget.initialUrl!;
    }
    if (widget.initialContent != null) {
      _contentController.text = widget.initialContent!;
    }
    if (mounted) {
      setState(() => _isAiAvailable = available);
    }

    if (widget.initialUrl != null && available) {
      await _analyzeWithAI();
    }
  }

  Future<void> _analyzeWithAI() async {
    if (!_isAiAvailable) {
      _showSnackBar('설정에서 AI 모델 제공자를 확인해주세요.', isError: true);
      return;
    }

    final content = _contentController.text.trim();
    final url = widget.initialUrl ?? _urlController.text.trim();
    if (content.isEmpty && url.isEmpty) {
      _showSnackBar('분석할 내용을 입력해주세요.', isError: true);
      return;
    }

    setState(() => _isSubmitting = true);

    final items = <BackgroundQueueItem>[];
    if (url.isNotEmpty) {
      items.addAll(SharedContentParser.parse(url));
    } else if (content.isNotEmpty) {
      items.add(BackgroundQueueItem(
        content: content,
        type: BackgroundQueueType.text,
      ));
    }

    await _backgroundQueue.enqueueItems(items);

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    _showSnackBar('AI 요약중입니다');
    Navigator.pop(context, true);
  }

  Future<void> _saveManual() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final category = _categoryController.text.trim();
    final url = _urlController.text.trim();

    if (title.isEmpty) {
      _showSnackBar('제목을 입력해주세요.', isError: true);
      return;
    }
    if (content.isEmpty) {
      _showSnackBar('내용을 입력해주세요.', isError: true);
      return;
    }

    final videoId = url.isNotEmpty ? _urlHandler.parseUrl(url).youtubeVideoId : null;

    await _databaseService.insertMemo(Memo(
      title: title,
      content: content,
      category: category.isNotEmpty ? category : '기타',
      sourceUrl: url.isNotEmpty ? url : null,
      youtubeVideoId: videoId,
    ));

    if (!mounted) return;
    _showSnackBar('메모가 저장되었습니다.');
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _contentController.dispose();
    _titleController.dispose();
    _categoryController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_manualMode ? '메모 작성' : 'AI 메모 분석'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(
            onPressed: _isSubmitting
                ? null
                : () => setState(() => _manualMode = !_manualMode),
            child: Text(_manualMode ? 'AI 모드' : '직접 입력'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _manualMode ? buildManualForm() : buildAiForm(),
      ),
    );
  }

  Widget buildAiForm() {
    final hasUrl = widget.initialUrl != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasUrl) ...[
          Card(
            color: Colors.blue[50],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        Text(
          '분석할 내용',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _contentController,
          maxLines: 8,
          decoration: InputDecoration(
            hintText: hasUrl
                ? 'URL과 함께 추가로 요약할 내용을 입력할 수 있습니다.'
                : '메모할 내용이나 URL을 입력하세요.',
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: '관련 URL (선택사항)',
            hintText: 'https://youtube.com/watch?v=...',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _isAiAvailable && !_isSubmitting ? _analyzeWithAI : null,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_isAiAvailable ? 'AI 분석 및 저장' : 'AI 연결 필요'),
          ),
        ),
        if (!_isAiAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '설정 메뉴에서 Gemma 모델을 다운로드하거나 엔진을 초기화해주세요.',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget buildManualForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            labelText: '제목',
            hintText: '메모 제목을 입력하세요',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.title),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _categoryController,
          decoration: const InputDecoration(
            labelText: '카테고리',
            hintText: '예: 요리/레시피, IT/기술',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.category),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _contentController,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: '내용',
            hintText: '메모 내용을 입력하세요',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: '관련 URL (선택사항)',
            hintText: 'https://...',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _saveManual,
            icon: const Icon(Icons.save),
            label: const Text('저장'),
          ),
        ),
      ],
    );
  }
}
