import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/content_processing_service.dart';
import '../services/llm_service.dart';
import '../widgets/category_chip.dart';
import '../services/category_detector.dart';
import '../services/geocoding_service.dart';
import '../services/naver_coord_service.dart';
import '../services/sync_service.dart';
import '../services/browser_service.dart';
import '../services/youtube_service.dart';
import 'memo_map_screen.dart';

class MemoDetailScreen extends StatefulWidget {
  final int memoId;

  const MemoDetailScreen({super.key, required this.memoId});

  @override
  State<MemoDetailScreen> createState() => _MemoDetailScreenState();
}

class _MemoDetailScreenState extends State<MemoDetailScreen> {
  final _databaseService = DatabaseService();
  final _syncService = SyncService();
  final _processingService = ContentProcessingService();
  Memo? _memo;
  bool _isLoading = true;
  bool _isEditing = false;

  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late TextEditingController _categoryController;
  late TextEditingController _addressController;

  /// 사용자가 ☆로 지정한 기본 브라우저. 지정돼 있으면 영상 카드도 이 브라우저로 연다.
  BrowserApp? _preferredBrowser;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _contentController = TextEditingController();
    _categoryController = TextEditingController();
    _addressController = TextEditingController();
    _loadMemo();
    _loadPreferredBrowser();
  }

  Future<void> _loadPreferredBrowser() async {
    final results = await Future.wait([
      BrowserService.getInstalledBrowsers(),
      BrowserService.getPreferredBrowser(),
    ]);
    if (!mounted) return;
    _applyPreferredBrowser(
        results[0] as List<BrowserApp>, results[1] as String?);
  }

  void _applyPreferredBrowser(List<BrowserApp> browsers, String? packageName) {
    BrowserApp? match;
    for (final b in browsers) {
      if (b.packageName == packageName) match = b;
    }
    setState(() => _preferredBrowser = match);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _categoryController.dispose();
    _addressController.dispose();
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
          _addressController.text = memo.address ?? '';
        }
      });
    }
  }

  void _enterEditMode() {
    if (_memo == null) return;
    _titleController.text = _memo!.title;
    _contentController.text = _memo!.content;
    _categoryController.text = _memo!.category;
    _addressController.text = _memo!.address ?? '';
    setState(() => _isEditing = true);
  }

  Future<void> _saveEdit() async {
    if (_memo == null) return;
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final category = _categoryController.text.trim();
    final address = _addressController.text.trim();

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

    // Clear old coordinates when address changes (they're invalid for the new address)
    final addressChanged = address != (_memo!.address ?? '');
    final updated = _memo!.copyWith(
      title: title,
      content: content,
      category: finalCategory,
      address: address.isNotEmpty ? address : null,
      kakaoLat: addressChanged ? null : _memo!.kakaoLat,
      kakaoLng: addressChanged ? null : _memo!.kakaoLng,
      naverX: addressChanged ? null : _memo!.naverX,
      naverY: addressChanged ? null : _memo!.naverY,
      updatedAt: DateTime.now(),
    );

    // copyWith cannot distinguish "set to null" from "not provided" (both are null),
    // so when address is cleared, rebuild with null explicitly.
    var savedMemo = updated;
    if (address.isEmpty) {
      savedMemo = Memo(
        id: updated.id,
        title: updated.title,
        content: updated.content,
        category: updated.category,
        sourceUrl: updated.sourceUrl,
        youtubeVideoId: updated.youtubeVideoId,
        thumbnailUrl: updated.thumbnailUrl,
        imagePath: updated.imagePath,
        address: null,
        searchKeyword: updated.searchKeyword,
        kakaoLat: updated.kakaoLat,
        kakaoLng: updated.kakaoLng,
        naverX: updated.naverX,
        naverY: updated.naverY,
        createdAt: updated.createdAt,
        updatedAt: updated.updatedAt,
      );
    }

    await _databaseService.updateMemo(savedMemo);

    // Trigger geocoding if address was provided
    if (address.isNotEmpty && addressChanged) {
      try {
        final geoResult = await GeocodingService().searchAddress(address);
        if (geoResult != null) {
          NaverCoordResult? naverResult;
          try {
            naverResult = await NaverCoordService().wgs84ToUtmk(
              geoResult.lat,
              geoResult.lng,
            );
          } catch (_) {}

          final geoUpdated = updated.copyWith(
            kakaoLat: geoResult.lat,
            kakaoLng: geoResult.lng,
            naverX: naverResult?.x ?? geoResult.lat,
            naverY: naverResult?.y ?? geoResult.lng,
            updatedAt: DateTime.now(),
          );
          await _databaseService.updateMemo(geoUpdated);
          savedMemo = geoUpdated;
          // Supabase 동기화 (좌표 포함 최종 버전)
          _syncService.debouncePushMemo(geoUpdated);
        }
      } catch (_) {
        // Geocoding failed silently — user can still edit the address again
      }
    } else {
      // 주소 변경 없음 — 일반 수정 분도 동기화
      _syncService.debouncePushMemo(savedMemo);
    }

    if (mounted) {
      setState(() {
        _memo = savedMemo;
        _isEditing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            addressChanged && address.isNotEmpty
                ? '✅ 메모가 수정되었습니다. 주소 좌표를 변환했습니다.'
                : '✅ 메모가 수정되었습니다.',
          ),
        ),
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
      // 소프트 삭제 — SyncService가 원격에도 반영 (비로그인 시 no-op).
      await _databaseService.softDeleteMemo(widget.memoId);
      if (_memo != null) {
        _syncService.pushMemoDelete(_memo!.memoId).catchError((e) {
          debugPrint('[MemoDetail] pushMemoDelete 오류: $e');
        });
      }
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _retryAnalysis() async {
    if (_memo == null) return;

    // Check AI availability
    final llm = LlmService();
    if (!await llm.isAvailable()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ AI 모델이 연결되지 않았습니다. 설정에서 모델을 선택해주세요.')),
        );
      }
      return;
    }

    // Fire retry in background without awaiting — the user can freely
    // navigate away (back / home) while retry completes.
    // HomeScreen will auto-refresh via onItemProcessed stream.
    _processingService.retryMemo(_memo!);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔄 AI 재요약이 백그라운드에서 실행됩니다. 완료 후 자동 반영됩니다.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // Return to home screen
      Navigator.pop(context, true);
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

  /// 기본 브라우저가 지정돼 있으면 그 브라우저로, 아니면 시스템 기본 동작으로 연다.
  /// [preferApp]이 true면 (예: YouTube) 기본 브라우저를 건너뛰고 해당 앱으로 연다.
  Future<void> _openUrl(String url, {bool preferApp = false}) async {
    if (!preferApp) {
      // 쇼츠는 /watch로 열면 브라우저에서 가로 플레이어에 작게 나오므로 /shorts/로 연다.
      url = await YouTubeService().resolveBrowserUrl(url);
      final preferred = await BrowserService.getPreferredBrowser();
      if (preferred != null && await BrowserService.openWith(url, preferred)) {
        return;
      }
    }
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

  Future<void> _openWithBrowser(String url, BrowserApp browser) async {
    url = await YouTubeService().resolveBrowserUrl(url);
    final ok = await BrowserService.openWith(url, browser.packageName);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${browser.name}(으)로 열 수 없습니다.')),
      );
    }
  }

  Future<void> _showLinkAction(String url) async {
    final results = await Future.wait([
      BrowserService.getInstalledBrowsers(),
      BrowserService.getPreferredBrowser(),
    ]);
    if (!mounted) return;
    final browsers = results[0] as List<BrowserApp>;
    String? preferred = results[1] as String?;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  // Handle bar
                  Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '링크 열기',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.copy),
                    title: const Text('클립보드에 복사'),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: url));
                      Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('링크가 클립보드에 복사되었습니다')),
                        );
                      }
                    },
                  ),
                  if (browsers.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.open_in_browser),
                      title: const Text('다른 브라우저에서 열기'),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openUrl(url);
                      },
                    )
                  else ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            '브라우저로 열기',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const Spacer(),
                          Text(
                            '☆ 눌러 기본 브라우저 지정',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    for (final browser in browsers)
                      ListTile(
                        leading: browser.icon != null
                            ? Image.memory(browser.icon!, width: 32, height: 32)
                            : const Icon(Icons.public, size: 32),
                        title: Text(browser.name),
                        subtitle: browser.packageName == preferred
                            ? const Text('기본 브라우저')
                            : null,
                        trailing: IconButton(
                          icon: Icon(
                            browser.packageName == preferred
                                ? Icons.star
                                : Icons.star_border,
                            color: browser.packageName == preferred
                                ? Colors.amber
                                : null,
                          ),
                          tooltip: browser.packageName == preferred
                              ? '기본 브라우저 해제'
                              : '기본 브라우저로 지정',
                          onPressed: () async {
                            final next = browser.packageName == preferred
                                ? null
                                : browser.packageName;
                            await BrowserService.setPreferredBrowser(next);
                            setSheetState(() => preferred = next);
                            if (mounted) _applyPreferredBrowser(browsers, next);
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _openWithBrowser(url, browser);
                        },
                      ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
              icon: const Icon(Icons.refresh),
              tooltip: 'AI 재요약',
              onPressed: _retryAnalysis,
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

            // YouTube / TikTok thumbnail
            if (memo.hasThumbnail) ...[
              _buildThumbnailSection(context, memo),
              const SizedBox(height: 16),
            ],

            // Local image from gallery share
            if (memo.hasImage) ...[
              _buildImageSection(context, memo),
              const SizedBox(height: 16),
            ],

            // Source URL (YouTube memos too — needed for '브라우저에서 열기')
            if (_linkUrlOf(memo) != null && !_isEditing) ...[
              Card(
                color: Colors.blue[50],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.link, color: Colors.blue[600], size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showLinkAction(_linkUrlOf(memo)!),
                          child: Text(
                            _linkUrlOf(memo)!,
                            style: TextStyle(
                              color: Colors.blue[700],
                              fontSize: 13,
                              decoration: TextDecoration.underline,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _openUrl(_linkUrlOf(memo)!),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.open_in_new,
                              color: Colors.blue[400], size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Address — editing mode
            if (_isEditing) ...[
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: '주소',
                  hintText: '예: 서울특별시 강남구 테헤란로 123',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_on_outlined),
                ),
                style: const TextStyle(fontSize: 14),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
            ] else if (memo.hasAddress && memo.hasCoordinates) ...[
              // Address (from AI analysis) — tappable → opens map
              Card(
                color: Colors.green[50],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MemoMapScreen(memoId: memo.id!),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.location_on,
                            color: Colors.green[700], size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                memo.address!,
                                style: TextStyle(
                                  color: Colors.green[800],
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  decoration: TextDecoration.underline,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '지도에서 보기',
                                style: TextStyle(
                                  color: Colors.green[500],
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            color: Colors.green[400], size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ] else if (memo.hasAddress && !memo.hasCoordinates) ...[
              Card(
                color: Colors.grey[50],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_outlined,
                          color: Colors.grey[500], size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          memo.address!,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(Icons.hourglass_empty,
                          color: Colors.grey[400], size: 16),
                    ],
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
              _buildLinkifiedContent(memo.content),
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

  Widget _buildLinkifiedContent(String text) {
    if (text.isEmpty) return const SizedBox.shrink();

    final urlRegex = RegExp(
      r'(https?://[^\s]+)',
      caseSensitive: false,
    );

    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in urlRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final url = match.group(1)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: Colors.blue[700],
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _openUrl(url),
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    if (spans.length == 1 && spans.first.recognizer == null) {
      return SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
      );
    }

    return SelectableText.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
        children: spans,
      ),
    );
  }

  /// Link shown in the source-URL card. Falls back to the YouTube watch URL
  /// for memos that only stored the video id.
  String? _linkUrlOf(Memo memo) {
    if (memo.sourceUrl != null && memo.sourceUrl!.isNotEmpty) {
      return memo.sourceUrl;
    }
    if (memo.youtubeVideoId != null) {
      return 'https://www.youtube.com/watch?v=${memo.youtubeVideoId}';
    }
    return null;
  }

  Widget _buildThumbnailSection(BuildContext context, Memo memo) {
    final isYoutube = memo.youtubeVideoId != null;
    final label = isYoutube ? 'YouTube' : '비디오';
    final sourceUrl = isYoutube
        ? 'https://www.youtube.com/watch?v=${memo.youtubeVideoId}'
        : memo.sourceUrl;
    // 기본 브라우저가 지정돼 있으면 YouTube 앱 대신 그 브라우저로 연다.
    final browser = _preferredBrowser;
    final openLabel = browser?.name ?? label;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: sourceUrl != null
            ? () => _openUrl(sourceUrl, preferApp: isYoutube && browser == null)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail image from network
            SizedBox(
              height: 200,
              width: double.infinity,
              child: Image.network(
                memo.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _mediaPlaceholder(
                  Icons.movie_creation_outlined,
                  label,
                ),
                loadingBuilder: (_, child, progress) {
                  if (progress == null) return child;
                  return _mediaPlaceholder(
                    Icons.movie_creation_outlined,
                    label,
                  );
                },
              ),
            ),
            // Bottom bar
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.play_circle_outline,
                      size: 18, color: Colors.red[400]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$openLabel에서 영상 보기',
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

  Widget _buildImageSection(BuildContext context, Memo memo) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Image.file(
              File(memo.imagePath!),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _mediaPlaceholder(
                Icons.broken_image,
                '이미지',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.image, size: 18, color: Colors.grey[600]),
                const SizedBox(width: 8),
                Text(
                  '공유된 이미지',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaPlaceholder(IconData icon, String label) {
    return Container(
      height: 200,
      width: double.infinity,
      color: Colors.grey[200],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
