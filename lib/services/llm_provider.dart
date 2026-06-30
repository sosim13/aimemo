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

  /// List models available on this provider
  Future<List<ModelStatus>> getModels();

  /// Download/pull a model
  Future<void> downloadModel(String modelName, {Function(double progress)? onProgress});

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
  final String? sourceUrl;
  final String? youtubeVideoId;

  AiAnalysisResult({
    required this.title,
    required this.category,
    required this.content,
    required this.keywords,
    this.sourceUrl,
    this.youtubeVideoId,
  });

  factory AiAnalysisResult.fromText(String text,
      {String? sourceUrl,
      String? youtubeVideoId,
      String? originalContent}) {
    String title = '';
    String category = '기타';
    String content = text;
    List<String> keywords = [];

    // PRIMARY: Use keyword-based detection on the original content (most reliable)
    // AI models often fail to follow structured output format for categories,
    // but keyword matching on the actual content is deterministic.
    if (originalContent != null && originalContent.isNotEmpty) {
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
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
    );
  }
}
