import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'llm_provider.dart';

/// LLM Provider that connects to a local ollama server
class OllamaProvider implements LlmProvider {
  @override
  String get name => '로컬 서버 (Ollama)';

  @override
  String get providerId => 'ollama';

  String _baseUrl;
  String? _selectedModel;
  http.Client? _httpClient;

  OllamaProvider({String baseUrl = 'http://localhost:11434', String? model})
      : _baseUrl = baseUrl,
        _selectedModel = model;

  String get baseUrl => _baseUrl;

  void updateBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _httpClient = null; // Reset client to recreate with new URL
  }

  http.Client get _client {
    _httpClient ??= http.Client();
    return _httpClient!;
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final response = await _client
          .get(Uri.parse('$_baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ModelStatus>> getModels() async {
    try {
      final response = await _client
          .get(Uri.parse('$_baseUrl/api/tags'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final models = data['models'] as List? ?? [];

      return models.map((m) {
        final details = m['details'] as Map<String, dynamic>? ?? {};
        // Parse size from raw bytes
        final sizeBytes = (m['size'] as num?)?.toDouble() ?? 0;
        final sizeStr = _formatSize(sizeBytes);

        return ModelStatus(
          name: m['name'] as String? ?? '',
          isDownloaded: true,
          size: sizeStr,
          parameterSize: details['parameter_size'] as String?,
          quantizationLevel: details['quantization_level'] as String?,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  String _formatSize(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Future<void> downloadModel(String modelName,
      {Function(double progress)? onProgress}) async {
    // Use ollama pull API with streaming response
    final request =
        http.Request('POST', Uri.parse('$_baseUrl/api/pull'));
    request.body = jsonEncode({'name': modelName, 'stream': true});
    request.headers['Content-Type'] = 'application/json';

    final streamedResponse = await _client.send(request);

    if (streamedResponse.statusCode != 200) {
      throw Exception(
          '모델 다운로드 실패 (${streamedResponse.statusCode})');
    }

    // Parse streaming JSON lines for progress
    final completer = Completer<void>();
    final subscription = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim().isEmpty) return;
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          if (data['status'] == 'success') {
            if (!completer.isCompleted) completer.complete();
          } else if (data['completed'] != null && data['total'] != null) {
            final completed = (data['completed'] as num).toDouble();
            final total = (data['total'] as num).toDouble();
            if (total > 0 && onProgress != null) {
              onProgress(completed / total);
            }
          }
        } catch (_) {}
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: false,
    );

    // Wait for completion with timeout
    await completer.future.timeout(const Duration(minutes: 30));
    await subscription.cancel();
  }

  @override
  Future<void> deleteModel(String modelName) async {
    final request =
        http.Request('DELETE', Uri.parse('$_baseUrl/api/delete'));
    request.body = jsonEncode({'name': modelName});
    request.headers['Content-Type'] = 'application/json';

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('모델 삭제 실패 (${response.statusCode})');
    }
  }

  @override
  String? get selectedModel => _selectedModel;

  @override
  Future<void> selectModel(String modelName) async {
    _selectedModel = modelName;
  }

  @override
  List<LlmModelInfo> get supportedModels => kPredefinedModels;

  /// The prompt template used for summarization
  String _buildPrompt(String content, {String? sourceUrl}) {
    return '''
You are a Korean memo analysis assistant. Always follow the exact output format. Do not add any introductory or closing remarks.

아래 내용을 분석해서 정해진 형식으로 정리해줘.

내용:
$content

출처 URL: ${sourceUrl ?? '(없음)'}

⚠️ 제공된 내용이 충분하지 않으면, 없는 내용을 지어내지 말고 "제공된 정보가 부족합니다"라고 표시해줘.

카테고리는 반드시 아래 목록 중 하나만 선택해 (30개):
개발, AI & 데이터, 미술 & 디자인, 기획 & 비즈니스, 마케팅 & 브랜딩, 재테크 & 금융, 법률 & 계약, 이슈 & 뉴스, 요리 & 레시피, 맛집 & 카페, 쇼핑 & 위시리스트, 여행 & 휴가, 건강 & 운동, 인테리어 & 소품, 반려동물, 할 일 & To-Do, 일정 & 약속, 아이디어 & 영감, 명언 & 좋은 글귀, 인간관계 & 경조사, 독서 & 리뷰, 어학 & 외국어, 시험 & 자격증, 인문 & 교양, 과학 & 다큐, 영화 & 드라마, 음악 & 공연, 웹툰 & 소설, 게임, 육아 & 가족, 기타

반드시 아래 형식만 출력해줘 (다른 말 하지 마, 카테고리는 위 목록 중 하나만):

## 제목
영상 제목 30자 이내

## 카테고리
개발

## 키워드
키워드1, 키워드2, 키워드3, 키워드4, 키워드5

## 내용

📌 **핵심 내용 3줄 요약**
1. 첫 번째 요점
2. 두 번째 요점
3. 세 번째 요점

📝 **상세 내용**
- 상세 내용 1
- 상세 내용 2
- 상세 내용 3
''';
  }

  @override
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    final model = _selectedModel ?? 'gemma4:e2b';
    final prompt = _buildPrompt(content, sourceUrl: sourceUrl);

    final response = await _client.post(
      Uri.parse('$_baseUrl/api/generate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'prompt': prompt,
        'stream': false,
        'options': {
          'temperature': 0.2,
          'num_predict': 1500,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Ollama 오류 (${response.statusCode})');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final assistantMessage = data['response'] as String?;

    if (assistantMessage == null || assistantMessage.trim().isEmpty) {
      return AiAnalysisResult(
        title: _truncate(content, 30),
        category: '기타',
        content: content,
        keywords: [],
        sourceUrl: sourceUrl,
        youtubeVideoId: youtubeVideoId,
      );
    }

    return AiAnalysisResult.fromText(
      assistantMessage,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
      originalContent: content,
    );
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }

  void dispose() {
    _httpClient?.close();
    _httpClient = null;
  }
}
