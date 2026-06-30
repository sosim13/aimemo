import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../services/youtube_service.dart';
import '../services/tiktok_service.dart';
import '../services/web_page_service.dart';
import '../services/url_handler_service.dart';
import '../services/ai_service.dart';
import '../services/llm_service.dart';
import '../services/database_service.dart';
import '../services/debug_logger.dart';
import '../services/category_detector.dart';
import '../models/memo.dart';
import 'memo_input_screen.dart';

class UrlProcessingScreen extends StatefulWidget {
  final String sharedUrl;

  const UrlProcessingScreen({super.key, required this.sharedUrl});

  @override
  State<UrlProcessingScreen> createState() => _UrlProcessingScreenState();
}

class _UrlProcessingScreenState extends State<UrlProcessingScreen> {
  final _youtubeService = YouTubeService();
  final _tiktokService = TikTokService();
  final _webPageService = WebPageService();
  final _urlHandler = UrlHandlerService();
  final _aiService = AiService();
  final _llmService = LlmService();
  final _databaseService = DatabaseService();
  final _debug = DebugLogger();

  /// Direct file fallback logger — bypasses DebugLogger entirely.
  /// Auto-truncates to 300 lines to prevent unbounded growth.
  Future<void> _diag(String msg) async {
    // ignore: avoid_print
    print('[DIAG] $msg');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/up_diag.txt');
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

  String _status = '링크를 분석하고 있습니다...';
  bool _isProcessing = true;
  bool _hasError = false;
  String? _errorMessage;

  ParsedUrl? _parsedUrl;
  YouTubeVideoInfo? _videoInfo;
  TikTokVideoInfo? _tiktokInfo;
  WebPageInfo? _webPageInfo;
  String? _extractedContent;

  @override
  void initState() {
    super.initState();
    _processUrl();
  }

  Future<void> _processUrl() async {
    await _diag('processUrl ENTER');
    await _debug.log('UP: _processUrl started for ${widget.sharedUrl}');
    try {
      final isAvailable = await _llmService.isAvailable();
      await _diag('isAvailable=$isAvailable');
      if (!isAvailable) {
        await _debug.log('UP: AI not available, showing error');
        setState(() {
          _status = 'AI 모델을 사용할 수 없습니다.';
          _hasError = true;
          _errorMessage =
              '설정 메뉴에서 Gemma 모델을 다운로드하거나 엔진을 초기화해주세요.';
          _isProcessing = false;
        });
        return;
      }

      setState(() => _status = '링크를 확인하고 있습니다...');
      final parsed = _urlHandler.parseUrl(widget.sharedUrl);
      await _diag('parsed type=${parsed.isYouTube ? "yt" : parsed.isTikTok ? "tt" : "web"}');
      await _debug.log('UP: URL parsed: type=${parsed.isYouTube ? "youtube" : parsed.isTikTok ? "tiktok" : "web"}');

      if (parsed.isYouTube && parsed.youtubeVideoId != null) {
        await _processYouTube(parsed);
      } else if (parsed.isTikTok) {
        await _processTikTok(parsed);
      } else {
        await _diag('calling processWebPage');
        await _processWebPage(parsed);
        await _diag('processWebPage returned');
      }
      await _debug.log('UP: _processUrl completed successfully');
      await _diag('processUrl END OK');
    } catch (e, stack) {
      await _diag('processUrl EXCEPTION: $e');
      await _debug.log('UP: _processUrl EXCEPTION: $e');
      await _debug.log('UP: Stack: $stack');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = '처리 중 오류가 발생했습니다: $e';
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _processYouTube(ParsedUrl parsed) async {
    setState(() => _status = 'YouTube 영상 정보를 가져오고 있습니다...');
    final videoInfo = await _youtubeService.getVideoInfo(parsed.youtubeVideoId!);

    if (videoInfo == null) {
      setState(() {
        _hasError = true;
        _errorMessage = 'YouTube 영상 정보를 가져올 수 없습니다.';
        _isProcessing = false;
      });
      return;
    }

    setState(() {
      _parsedUrl = parsed;
      _videoInfo = videoInfo;
      _status = '영상 자막을 가져오고 있습니다...';
    });

    // Fetch transcript for real content
    final transcript = await _youtubeService.fetchTranscript(parsed.youtubeVideoId!);

    final videoInfoWithTranscript = YouTubeVideoInfo(
      videoId: videoInfo.videoId,
      title: videoInfo.title,
      description: videoInfo.description,
      thumbnailUrl: videoInfo.thumbnailUrl,
      channelName: videoInfo.channelName,
      transcript: transcript,
    );

    _extractedContent = videoInfoWithTranscript.buildContentForAi();

    setState(() => _status = 'AI가 영상 내용을 분석하고 있습니다...');

    try {
      final result = await _aiService.analyzeContent(
        content: _extractedContent!,
        sourceUrl: videoInfo.videoUrl,
        youtubeVideoId: parsed.youtubeVideoId,
      );

      final memo = Memo(
        title: result.title.isNotEmpty ? result.title : videoInfo.title,
        content: result.content.isNotEmpty ? result.content : _extractedContent!,
        category: result.category.isNotEmpty ? result.category : '기타',
        sourceUrl: videoInfo.videoUrl,
        youtubeVideoId: parsed.youtubeVideoId,
      );

      await _databaseService.insertMemo(memo);
      await _debug.log('UP: YouTube memo saved with AI result');
    } catch (e) {
      // AI 분석 실패 시 기본 정보라도 저장
      await _debug.log('UP: YouTube AI analysis failed ($e), saving fallback memo');
      final memo = Memo(
        title: videoInfo.title,
        content: _extractedContent!,
        category: '기타',
        sourceUrl: videoInfo.videoUrl,
        youtubeVideoId: parsed.youtubeVideoId,
      );
      await _databaseService.insertMemo(memo);
    }

    if (mounted) {
      setState(() {
        _status = '✅ 메모가 저장되었습니다!';
        _isProcessing = false;
      });
    }
  }

  Future<void> _processTikTok(ParsedUrl parsed) async {
    setState(() => _status = 'TikTok 영상 정보를 가져오고 있습니다...');
    final tiktokInfo =
        await _tiktokService.getVideoInfo(parsed.originalUrl);

    if (tiktokInfo == null) {
      setState(() {
        _hasError = true;
        _errorMessage = 'TikTok 영상 정보를 가져올 수 없습니다.';
        _isProcessing = false;
      });
      return;
    }

    setState(() {
      _parsedUrl = parsed;
      _tiktokInfo = tiktokInfo;
      _status = 'AI가 영상 내용을 분석하고 있습니다...';
    });

    _extractedContent = tiktokInfo.buildContentForAi();

    try {
      final result = await _aiService.analyzeContent(
        content: _extractedContent!,
        sourceUrl: tiktokInfo.videoUrl,
      );

      final memo = Memo(
        title: result.title.isNotEmpty ? result.title : tiktokInfo.title,
        content:
            result.content.isNotEmpty ? result.content : _extractedContent!,
        category: result.category.isNotEmpty ? result.category : '기타',
        sourceUrl: tiktokInfo.videoUrl,
      );

      await _databaseService.insertMemo(memo);
    } catch (e) {
      // AI 실패 시 기본 정보라도 저장
      final memo = Memo(
        title: tiktokInfo.title,
        content: _extractedContent!,
        category: '기타',
        sourceUrl: tiktokInfo.videoUrl,
      );
      await _databaseService.insertMemo(memo);
    }

    if (mounted) {
      setState(() {
        _status = '✅ 메모가 저장되었습니다!';
        _isProcessing = false;
      });
    }
  }

  Future<void> _processWebPage(ParsedUrl parsed) async {
    await _diag('processWebPage ENTER');
    await _debug.log('UP: _processWebPage entered');
    setState(() {
      _parsedUrl = parsed;
      _status = '웹페이지 내용을 가져오고 있습니다...';
    });

    await _debug.log('UP: _processWebPage calling fetchPageContent for ${widget.sharedUrl}');
    await _diag('calling fetchPageContent');

    // Try fetching with WebPageService first
    final pageInfo = await _webPageService.fetchPageContent(widget.sharedUrl);
    await _diag('fetchPageContent returned: ${pageInfo != null ? "title=${pageInfo.title} textLen=${pageInfo.textContent.length}" : "null"}');
    await _debug.log(
        'UP: fetchPageContent result: ${pageInfo != null ? "title=${pageInfo.title} descLen=${pageInfo.description.length} textLen=${pageInfo.textContent.length}" : "null"}');

    if (pageInfo != null && pageInfo.textContent.isNotEmpty) {
      await _debug.log('UP: Using pageInfo (textContent is ${pageInfo.textContent.length} chars)');
      setState(() {
        _webPageInfo = pageInfo;
        _extractedContent = '''웹페이지 제목: ${pageInfo.title}
설명: ${pageInfo.description}
본문 내용:
${pageInfo.textContent}''';
        _status = 'AI가 페이지 내용을 분석하고 있습니다...';
      });
    } else {
      // WebPageService failed or returned empty text — try direct fetch
      await _debug.log(
          'UP: pageInfo is ${pageInfo == null ? "null" : "non-null but textContent empty"}, trying fallback HTTP');
      String? fallbackContent;
      try {
        await _debug.log('UP: Fallback HTTP GET start');
        final response = await http
            .get(Uri.parse(widget.sharedUrl), headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'ko-KR,ko;q=0.9',
        })
            .timeout(const Duration(seconds: 15));

        await _debug.log(
            'UP: Fallback HTTP status=${response.statusCode} bodyLen=${response.bodyBytes.length}');

        if (response.statusCode == 200) {
          var html = utf8.decode(response.bodyBytes);
          await _debug.log('UP: Fallback HTML length=${html.length}');

          // Extract og:title
          String? title;
          final ogTitle = RegExp(
            r'''<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']''',
            caseSensitive: false,
          ).firstMatch(html);
          if (ogTitle != null) title = ogTitle.group(1)?.trim();

          // Extract og:description
          String? description;
          final ogDesc = RegExp(
            r'''<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']''',
            caseSensitive: false,
          ).firstMatch(html);
          if (ogDesc != null) description = ogDesc.group(1)?.trim();

          // Extract title tag
          if (title == null || title.isEmpty) {
            final tMatch = RegExp(r'<title[^>]*>([^<]*)</title>',
                    caseSensitive: false, dotAll: false)
                .firstMatch(html);
            if (tMatch != null) title = tMatch.group(1)?.trim();
          }

          // Build content from what we have
          final parts = <String>[];
          if (title != null && title.isNotEmpty) parts.add('[$title]');
          if (description != null && description.isNotEmpty) {
            parts.add(description);
          }

          await _debug.log(
              'UP: Fallback og:title="$title" og:desc="${description?.substring(0, description.length > 50 ? 50 : description.length)}"');

          if (parts.isNotEmpty) {
            fallbackContent = parts.join(' ');
            _webPageInfo = WebPageInfo(
              url: widget.sharedUrl,
              title: title ?? '',
              description: description ?? '',
              textContent: '',
            );
          }
        }
      } catch (e) {
        await _debug.log('UP: Fallback HTTP exception: $e');
      }

      if (fallbackContent != null && fallbackContent.isNotEmpty) {
        _extractedContent = fallbackContent;
        await _debug.log(
            'UP: Fallback content ready, len=${_extractedContent!.length}');
        setState(() => _status = 'AI가 페이지 내용을 분석하고 있습니다...');
      } else {
        await _debug.log('UP: Both fetch attempts failed, showing error');
        setState(() {
          _extractedContent = null;
          _status = '웹페이지 내용을 불러올 수 없습니다.';
          _hasError = true;
          _errorMessage =
              '이 페이지의 내용을 자동으로 가져올 수 없습니다. 직접 메모를 입력해주세요.';
          _isProcessing = false;
        });
        return; // Don't run AI, don't save
      }
    }

    final pageTitle = _webPageInfo?.title.isNotEmpty == true
        ? _webPageInfo!.title
        : widget.sharedUrl;
    final rawContent = _extractedContent ?? 'URL: ${widget.sharedUrl}';

    // Truncate raw content to 3000 chars before sending to AI
    // Full raw content is saved as backup, but AI only needs the essence
    final aiContent = rawContent.length > 3000
        ? '${rawContent.substring(0, 3000)}\n\n[...이하 생략...]'
        : rawContent;
    await _debug.log(
        'UP: Sending to AI, aiContent length=${aiContent.length} (raw was ${rawContent.length})');

    try {
      final result = await _aiService.analyzeContent(
        content: aiContent,
        sourceUrl: widget.sharedUrl,
      );
      await _debug.log(
          'UP: AI result: title="${result.title}" category="${result.category}" contentLen=${result.content.length}');

      // Check if AI actually summarized or just echoed the input
      var finalContent = result.content.isNotEmpty ? result.content : rawContent;
      var finalCategory = result.category.isNotEmpty ? result.category : '기타';

      // Fallback conditions: AI returned empty, or echoed the input, or content suspiciously long
      final aiEchoed = result.content.isEmpty ||
          result.content.length > aiContent.length * 0.8;
      if (aiEchoed) {
        await _debug.log(
            'UP: AI content too long (${result.content.length}), likely echo — falling back to first 500 chars');
        finalContent = rawContent.length > 500
            ? '${rawContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.'
            : rawContent;
        // Try to detect category from raw content
        if (finalCategory == '기타' || finalCategory.isEmpty) {
          final detected = CategoryDetector.detect(rawContent);
          if (detected != null) finalCategory = detected;
        }
      }

      final memo = Memo(
        title: result.title.isNotEmpty ? result.title : pageTitle,
        content: finalContent,
        category: finalCategory,
        sourceUrl: widget.sharedUrl,
      );
      await _databaseService.insertMemo(memo);
      await _debug.log('UP: Memo saved successfully');
    } catch (e) {
      await _debug.log(
          'UP: AI analysis exception: $e — saving with truncated content');
      // AI 분석 실패 시: 카테고리 추론 + 내용 단축
      final detected = CategoryDetector.detect(rawContent);
      final truncatedContent = rawContent.length > 500
          ? '${rawContent.substring(0, 500)}\n\n📌 AI 요약에 실패했습니다. 원본 내용 중 일부를 표시합니다.'
          : rawContent;

      final memo = Memo(
        title: pageTitle,
        content: truncatedContent,
        category: detected ?? '기타',
        sourceUrl: widget.sharedUrl,
      );
      await _databaseService.insertMemo(memo);
      await _debug.log('UP: Fallback memo saved (category=$detected)');
    }

    if (mounted) {
      setState(() {
        _status = '✅ 메모가 저장되었습니다!';
        _isProcessing = false;
      });
    }
  }

  Future<void> _openMemoInput() async {
    final result = await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MemoInputScreen(
          initialUrl: widget.sharedUrl,
          initialContent: _extractedContent,
          youtubeVideoId: _parsedUrl?.youtubeVideoId,
        ),
      ),
    );
    if (result == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _openSourceUrl() async {
    try {
      await launchUrl(
        Uri.parse(widget.sharedUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('링크 처리'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // YouTube thumbnail
              if (_videoInfo != null && !_isProcessing && !_hasError)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    _youtubeService.getThumbnailUrl(_videoInfo!.videoId),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 180,
                      color: Colors.grey[200],
                      child: const Center(
                        child: Icon(Icons.play_circle_fill,
                            size: 48, color: Colors.grey),
                      ),
                    ),
                  ),
                ),

              // TikTok info
              if (_tiktokInfo != null && !_isProcessing && !_hasError)
                Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.music_note, color: Colors.black, size: 40),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _tiktokInfo!.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '@${_tiktokInfo!.authorName}',
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Web page info
              if (_webPageInfo != null && !_isProcessing && !_hasError)
                Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.article, color: Colors.blue[600], size: 40),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _webPageInfo!.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_webPageInfo!.description.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    _webPageInfo!.description,
                                    style: TextStyle(
                                        color: Colors.grey[600], fontSize: 13),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 32),

              if (_isProcessing)
                const SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(strokeWidth: 4),
                )
              else if (_hasError)
                Icon(Icons.error_outline, size: 64, color: Colors.red[300])
              else
                Icon(Icons.check_circle_outline,
                    size: 64, color: Colors.green[400]),

              const SizedBox(height: 24),

              Text(
                _status,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                textAlign: TextAlign.center,
              ),

              if (_hasError && _errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 32),

              if (!_isProcessing) ...[
                if (!_hasError && _videoInfo != null)
                  _buildActionButton(
                    icon: Icons.play_circle_fill,
                    label: 'YouTube에서 보기',
                    onTap: _openSourceUrl,
                  ),
                if (!_hasError && _tiktokInfo != null)
                  _buildActionButton(
                    icon: Icons.music_note,
                    label: 'TikTok에서 보기',
                    onTap: _openSourceUrl,
                  ),
                if (!_hasError && _webPageInfo != null)
                  _buildActionButton(
                    icon: Icons.open_in_new,
                    label: '원문 보기',
                    onTap: _openSourceUrl,
                  ),
                if (!_hasError &&
                    _videoInfo == null &&
                    _tiktokInfo == null &&
                    _webPageInfo == null)
                  _buildActionButton(
                    icon: Icons.edit_note,
                    label: '직접 메모 입력',
                    onTap: _openMemoInput,
                  ),
                const SizedBox(height: 8),
                _buildActionButton(
                  icon: Icons.home,
                  label: '홈으로 돌아가기',
                  onTap: () => Navigator.pop(context, true),
                  isOutlined: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isOutlined = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: isOutlined
          ? OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(label),
            )
          : FilledButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}
