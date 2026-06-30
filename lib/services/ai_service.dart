import 'llm_service.dart';
import 'llm_provider.dart';

// Re-export AiAnalysisResult for backward compatibility
export 'llm_provider.dart' show AiAnalysisResult;

/// Legacy wrapper around LlmService for backward compatibility.
/// New code should use LlmService directly.
class AiService {
  static final AiService _instance = AiService._internal();
  factory AiService() => _instance;
  AiService._internal();

  final _llmService = LlmService();

  /// Analyze content using the currently configured LLM provider
  Future<AiAnalysisResult> analyzeContent({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    return _llmService.analyze(
      content: content,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
    );
  }
}
