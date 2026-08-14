import 'package:flutter_gemma/flutter_gemma.dart' show CancelToken;
import '../models/memo.dart';
import 'category_detector.dart';

/// Information about a downloadable model
class LlmModelInfo {
  final String name; // e.g. "gemma-4-E2B-it"
  final String displayName; // e.g. "Gemma 4 E2B"
  final String description;
  final String sizeLabel; // e.g. "~2.5GB"
  final bool isRecommended;

  /// Direct download URL. If set, this is used instead of HuggingFace repo/file.
  /// Example: "https://example.com/models/my-model.litertlm"
  final String? downloadUrl;

  /// HuggingFace repo name (model ID), e.g. "litert-community/gemma-4-E2B-it-litert-lm"
  /// If null, constructed as "litert-community/{name}-litert-lm"
  final String? huggingFaceRepo;

  /// File name to download from the repo, e.g. "gemma-4-E2B-it.litertlm"
  /// If null, constructed as "{name}.litertlm"
  final String? huggingFaceFile;

  const LlmModelInfo({
    required this.name,
    required this.displayName,
    required this.description,
    required this.sizeLabel,
    this.isRecommended = false,
    this.downloadUrl,
    this.huggingFaceRepo,
    this.huggingFaceFile,
  });
}



/// Status of a model on the server
class ModelStatus {
  final String name;
  final bool isDownloaded;
  final String? size;
  final String? parameterSize;
  final String? quantizationLevel;

  const ModelStatus({
    required this.name,
    required this.isDownloaded,
    this.size,
    this.parameterSize,
    this.quantizationLevel,
  });
}

/// Abstract interface for LLM providers
abstract class LlmProvider {
  /// Human-readable provider name
  String get name;

  /// Unique provider ID used for storage
  String get providerId;

  /// Check if this provider is configured and available
  Future<bool> isAvailable();

  /// Analyze content with the currently selected model
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  });

  /// Free-form Q&A with the currently selected model.
  /// Returns the raw text response without structured parsing.
  /// [prompt] is the full prompt sent to the model (system + user).
  Future<String> ask({
    required String prompt,
    double temperature = 0.7,
    int topK = 40,
    int maxTokens = 2048,
  });

  /// Cancel the currently running [ask] or [analyze] operation, if supported.
  /// This is a no-op if nothing is running or cancellation is not supported.
  void cancel();

  /// List models available on this provider
  Future<List<ModelStatus>> getModels();

  /// Download/pull a model
  /// [cancelToken] — 취소 토큰. [CancelToken.cancel] 호출 시 다운로드가 중단된다.
  Future<void> downloadModel(
    String modelName, {
    Function(double progress)? onProgress,
    CancelToken? cancelToken,
  });

  /// Delete a model
  Future<void> deleteModel(String modelName);

  /// Get currently selected model name
  String? get selectedModel;

  /// Select a model to use
  Future<void> selectModel(String modelName);

  /// Get list of predefined models this provider supports
  List<LlmModelInfo> get supportedModels;
}

/// Result from AI analysis
class AiAnalysisResult {
  final String title;
  final String category;
  final String content;
  final List<String> keywords;

  /// Extracted address from AI analysis (e.g. "인천 남동구 백범로 109").
  /// Empty string means the AI didn't find an address.
  final String address;

  final String? sourceUrl;
  final String? youtubeVideoId;

  AiAnalysisResult({
    required this.title,
    required this.category,
    required this.content,
    required this.keywords,
    this.address = '',
    this.sourceUrl,
    this.youtubeVideoId,
  });

  /// Normalize an AI-generated category string to a canonical [AppCategories]
  /// name. Returns null if the raw value isn't a recognizable category.
  static String? _normalizeCategory(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('없음') || trimmed.contains('없습니다')) return null;

    final canonical = AppCategories.normalize(trimmed);
    if (canonical != null) return canonical;

    // Alias mapping for common variants produced by small local models
    const aliases = {
      '요리 레시피': '요리 & 레시피',
      '요리/레시피': '요리 & 레시피',
      '요리&레시피': '요리 & 레시피',
      '레시피': '요리 & 레시피',
      '맛집': '맛집 & 카페',
      '카페': '맛집 & 카페',
      '맛집/카페': '맛집 & 카페',
      '맛집 카페': '맛집 & 카페',
      '식당': '맛집 & 카페',
    };
    final alias = aliases[trimmed];
    if (alias != null) return alias;

    // Last resort: substring match against each canonical category name
    for (final cat in AppCategories.all) {
      if (cat == '기타') continue;
      if (trimmed.contains(cat) ||
          trimmed.contains(cat.replaceAll(' & ', ' '))) {
        return cat;
      }
    }
    return null;
  }

  factory AiAnalysisResult.fromText(String text,
      {String? sourceUrl,
      String? youtubeVideoId,
      String? originalContent}) {
    String title = '';
    String category = '기타';
    String content = text;
    List<String> keywords = [];
    String address = '';

    // PRIMARY: Trust the AI's category answer (normalized to a canonical name).
    // The model sees the content and its functional judgment — "place review /
    // where to eat" vs "cooking instructions / how to make" — is more reliable
    // than keyword counting for the 맛집 & 카페 / 요리 & 레시피 pair, whose
    // keyword lists overlap heavily.
    final catMatch = RegExp(r'##\s*카테고리\s*\n(.+?)(?:\n##|\n$|$)',
            caseSensitive: false, dotAll: true)
        .firstMatch(text);
    final aiCategory = _normalizeCategory(catMatch?.group(1));
    if (aiCategory != null && aiCategory != '기타') {
      category = aiCategory;
    }

    // FALLBACK 1: keyword-based detection on the original content (deterministic,
    // used only when the AI didn't produce a valid category).
    if (category == '기타' &&
        originalContent != null &&
        originalContent.isNotEmpty) {
      final detected = CategoryDetector.detect(originalContent);
      if (detected != null && detected != '기타') {
        category = detected;
      }
    }

    // SECONDARY: Try AI title
    final titleMatch =
        RegExp(r'##\s*제목\s*\n(.+?)(?:\n|$)', caseSensitive: false)
            .firstMatch(text);
    if (titleMatch != null) {
      title = titleMatch.group(1)!.trim();
    }

    // SECONDARY: Use AI + title + text as fallback for category if still 기타
    if (category == '기타') {
      // Try first from AI response text
      for (final cat in AppCategories.all) {
        if (cat == '기타') continue;
        if (text.contains(cat) || text.contains(cat.replaceAll(' & ', ' '))) {
          category = cat;
          break;
        }
      }
    }
    // Last fallback: keyword detect on combined AI text
    if (category == '기타') {
      final detected = CategoryDetector.detect('$title $text');
      if (detected != null) category = detected;
    }

    final kwMatch = RegExp(r'##\s*키워드\s*\n(.+?)(?:\n##|\n$|$)',
            caseSensitive: false, dotAll: true)
        .firstMatch(text);
    if (kwMatch != null) {
      final kwText = kwMatch.group(1)!.trim();
      keywords = kwText
          .split(RegExp(r'[,;#\s•\-]+'))
          .map((e) => e.trim().replaceAll('#', ''))
          .where((e) => e.isNotEmpty && e.length < 30)
          .toList();
      if (keywords.length > 10) keywords = keywords.take(10).toList();
    }

    // Parse ## 주소 section
    final addrMatch = RegExp(r'##\s*주소\s*\n(.+?)(?:\n##|\n$|$)',
            caseSensitive: false, dotAll: true)
        .firstMatch(text);
    if (addrMatch != null) {
      final raw = addrMatch.group(1)!.trim();
      // Only set if it's not a "없음" / "없습니다" / empty response
      if (raw.isNotEmpty &&
          !raw.contains('없음') &&
          !raw.contains('없습니다') &&
          !raw.contains('정보가 부족')) {
        address = raw;
      }
    }

    final contentMatch = RegExp(r'##\s*내용\s*\n(.+?)$',
            caseSensitive: false, dotAll: true)
        .firstMatch(text);
    if (contentMatch != null) {
      content = contentMatch.group(1)!.trim();
    }

    if (title.isEmpty) {
      title = text.split('\n').first.trim();
      if (title.length > 30) title = '${title.substring(0, 30)}...';
    }

    return AiAnalysisResult(
      title: title.isNotEmpty ? title : '제목 없음',
      category: category.isNotEmpty ? category : '기타',
      content: content.isNotEmpty ? content : text,
      keywords: keywords,
      address: address,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
    );
  }
}
