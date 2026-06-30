import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/llm_service.dart';
import '../services/url_handler_service.dart';
import '../services/youtube_service.dart';
import '../services/tiktok_service.dart';
import '../services/web_page_service.dart';
import '../services/debug_logger.dart';
import '../services/category_detector.dart';

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
  final _aiService = AiService();
  final _llmService = LlmService();
  final _urlHandler = UrlHandlerService();
  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();
  final _debug = DebugLogger();

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

  bool _isAnalyzing = false;
  bool _isAiAvailable = false;
  bool _manualMode = false;

  // Manual input fields
  final _titleController = TextEditingController();
  final _categoryController = TextEditingController();
  final _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final available = await _llmService.isAvailable();
    if (mounted) {
      setState(() => _isAiAvailable = available);
    }

    if (widget.initialUrl != null) {
      _urlController.text = widget.initialUrl!;
    }
    if (widget.initialContent != null) {
      _contentController.text = widget.initialContent!;
    }

    // If URL was shared, auto-analyze after short delay
    if (widget.initialUrl != null && _isAiAvailable) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _analyzeWithAI();
      });
    }
  }

  Future<void> _analyzeWithAI() async {
    await _diag('analyzeWithAI ENTER');
    if (!_isAiAvailable) {
      _showSnackBar('설정에서 AI 모델 제공자를 확인해주세요.', isError: true);
      return;
    }

    final content = _contentController.text.trim();
    if (content.isEmpty && widget.initialUrl == null) {
      _showSnackBar('분석할 내용을 입력해주세요.', isError: true);
      return;
    }

    setState(() => _isAnalyzing = true);

    // Variables shared between try and catch blocks
    var sourceUrl = widget.initialUrl ?? _urlController.text.trim();
    var videoId = widget.youtubeVideoId;
    String analysisContent = content;

    try {
      // If no URL from URL field, check if content itself looks like a URL
      if (sourceUrl.isEmpty && Uri.tryParse(content)?.hasScheme == true) {
        sourceUrl = content;
      }

      analysisContent = content;
      await _diag('sourceUrl=$sourceUrl analysisContent.length=${analysisContent.length}');

      // If we have a URL, try to fetch content from it
      if (sourceUrl.isNotEmpty) {
        // 1. Try YouTube
        final candidateVideoId = videoId ?? _youtubeService.extractVideoId(sourceUrl);
        if (candidateVideoId != null) {
          setState(() => _isAnalyzing = true);
          videoId = candidateVideoId;
          await _diag('YouTube video detected: $candidateVideoId');

          final videoInfo = await _youtubeService.getVideoInfo(candidateVideoId);
          if (videoInfo != null) {
            final transcript =
                await _youtubeService.fetchTranscript(candidateVideoId);
            final videoInfoWithTranscript = YouTubeVideoInfo(
              videoId: videoInfo.videoId,
              title: videoInfo.title,
              description: videoInfo.description,
              thumbnailUrl: videoInfo.thumbnailUrl,
              channelName: videoInfo.channelName,
              transcript: transcript,
            );
            analysisContent = videoInfoWithTranscript.buildContentForAi();
          }
        }
        // 2. Try TikTok
        else if (_tiktokService.isTikTokUrl(sourceUrl)) {
          setState(() => _isAnalyzing = true);

          final tiktokInfo = await _tiktokService.getVideoInfo(sourceUrl);
          if (tiktokInfo != null) {
            analysisContent = tiktokInfo.buildContentForAi();
          }
        }
        // 3. Try general web page
        else if (_isWebUrl(sourceUrl)) {
          setState(() => _isAnalyzing = true);
          await _diag('Fetching web page: $sourceUrl');

          final webService = WebPageService();
          final pageInfo = await webService.fetchPageContent(sourceUrl);
          await _diag('WebPage fetch result: ${pageInfo != null ? "title=${pageInfo.title} textLen=${pageInfo.textContent.length}" : "null"}');
          if (pageInfo != null) {
            final pageTitle = pageInfo.title.isNotEmpty ? '[${pageInfo.title}]' : '';
            final pageDesc = pageInfo.description.isNotEmpty ? pageInfo.description : '';
            final pageBody = pageInfo.textContent.isNotEmpty ? '\n\n${pageInfo.textContent}' : '';
            final combined = '$pageTitle $pageDesc$pageBody'.trim();
            if (combined.isNotEmpty) {
              analysisContent = combined;
            }
          }
        }
      }

      await _diag('Calling AI analyze, content length=${analysisContent.length}');
      final result = await _aiService.analyzeContent(
        content: analysisContent,
        sourceUrl: sourceUrl.isNotEmpty ? sourceUrl : null,
        youtubeVideoId: videoId,
      );

      if (mounted) {
        // Save the memo
        final memo = Memo(
          title: result.title.isNotEmpty ? result.title : '제목 없음',
          content: result.content.isNotEmpty ? result.content : content,
          category: result.category.isNotEmpty ? result.category : '기타',
          sourceUrl: result.sourceUrl ?? (sourceUrl.isNotEmpty ? sourceUrl : null),
          youtubeVideoId: result.youtubeVideoId ?? videoId,
        );

        await _databaseService.insertMemo(memo);
        await _diag('Memo saved via AI, title="${result.title}" category="${result.category}" contentLen=${result.content.length}');

        setState(() => _isAnalyzing = false);
        _showSnackBar('✅ 메모가 저장되었습니다.');
        Navigator.pop(context, true);
      }
    } catch (e) {
      await _debug.log('MIS: AI analysis exception: $e');
      await _diag('AI exception: $e');

      // Fallback: save memo with what we have
      String fallbackTitle = '';
      String fallbackContent = content;
      String fallbackCategory = '기타';

      // Extract title from analysisContent if it was fetched from URL
      if (sourceUrl.isNotEmpty && analysisContent != content) {
        final titleMatch =
            RegExp(r'^\[(.+?)\]', caseSensitive: false).firstMatch(analysisContent);
        if (titleMatch != null) {
          fallbackTitle = titleMatch.group(1)!.trim();
        }
        // Truncate content
        if (analysisContent.length > 500) {
          fallbackContent =
              '${analysisContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.';
        } else {
          fallbackContent = analysisContent;
        }
        fallbackCategory = CategoryDetector.detect(analysisContent) ?? '기타';
      }

      if (mounted) {
        final memo = Memo(
          title: fallbackTitle.isNotEmpty ? fallbackTitle : (sourceUrl.isNotEmpty ? sourceUrl : '제목 없음'),
          content: fallbackContent,
          category: fallbackCategory,
          sourceUrl: sourceUrl.isNotEmpty ? sourceUrl : null,
          youtubeVideoId: videoId,
        );
        await _databaseService.insertMemo(memo);
        await _debug.log('MIS: Fallback memo saved (category=$fallbackCategory)');
        await _diag('Fallback memo saved, category=$fallbackCategory');
        setState(() => _isAnalyzing = false);
        _showSnackBar('✅ 메모가 저장되었습니다 (AI 요약 생략).');
        Navigator.pop(context, true);
      }
    }
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

    final memo = Memo(
      title: title,
      content: content,
      category: category.isNotEmpty ? category : '기타',
      sourceUrl: url.isNotEmpty ? url : null,
      youtubeVideoId: videoId,
    );

    await _databaseService.insertMemo(memo);
    _showSnackBar('✅ 메모가 저장되었습니다.');
    Navigator.pop(context, true);
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
        content: Text(message),
        backgroundColor: isError ? Colors.red[600] : Colors.green[600],
        behavior: SnackBarBehavior.floating,
      ),
    );
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
            onPressed: () {
              setState(() => _manualMode = !_manualMode);
            },
            child: Text(_manualMode ? 'AI 모드' : '직접 입력'),
          ),
        ],
      ),
      body: _isAnalyzing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('AI가 내용을 분석하고 있습니다...'),
                  SizedBox(height: 8),
                  Text(
                    '잠시만 기다려주세요',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _manualMode ? _buildManualForm() : _buildAiForm(),
            ),
    );
  }

  Widget _buildAiForm() {
    final hasUrl = widget.initialUrl != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasUrl) ...[
          Card(
            color: Colors.blue[50],
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                ? 'URL 내용을 분석 중입니다... (추가 입력 가능)'
                : '메모할 내용을 입력하세요.\n예: 순두부찌개 레시피 - 재료: 순두부 100g, 고춧가루 2숟가락...',
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
            onPressed: _isAiAvailable ? _analyzeWithAI : null,
            icon: const Icon(Icons.auto_awesome),
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

  Widget _buildManualForm() {
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
