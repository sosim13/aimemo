import 'dart:convert';
import 'package:http/http.dart' as http;
import 'llm_provider.dart';
import 'secure_storage_service.dart';

/// LLM Provider that uses NVIDIA's cloud API (Gemma 4 31B)
class NvidiaProvider implements LlmProvider {
  @override
  String get name => '클라우드 API (NVIDIA)';

  @override
  String get providerId => 'nvidia';

  final _secureStorage = SecureStorageService();

  String _apiEndpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';
  String _model = 'google/gemma-4-31b-it';
  String? _selectedModel;

  NvidiaProvider({String? endpoint, String? model}) {
    if (endpoint != null) _apiEndpoint = endpoint;
    if (model != null) _model = model;
  }

  @override
  List<LlmModelInfo> get supportedModels => const [
        LlmModelInfo(
          name: 'google/gemma-4-31b-it',
          displayName: 'Gemma 4 31B',
          description: 'NVIDIA 호스팅 Gemma 4 31B, 최고 품질',
          sizeLabel: '클라우드 API',
          isRecommended: true,
        ),
        LlmModelInfo(
          name: 'google/gemma-4-e2b-it',
          displayName: 'Gemma 4 E2B',
          description: 'NVIDIA 호스팅 Gemma 4 E2B, 경량',
          sizeLabel: '클라우드 API',
        ),
        LlmModelInfo(
          name: 'google/gemma-2-9b-it',
          displayName: 'Gemma 2 9B',
          description: 'NVIDIA 호스팅 Gemma 2 9B',
          sizeLabel: '클라우드 API',
        ),
      ];

  @override
  Future<bool> isAvailable() async {
    final apiKey = await _secureStorage.getApiKey();
    return apiKey != null && apiKey.isNotEmpty;
  }

  @override
  Future<List<ModelStatus>> getModels() async {
    // NVIDIA API doesn't support model listing, return supported models as "available"
    return supportedModels.map((m) => ModelStatus(
          name: m.name,
          isDownloaded: true,
          size: m.sizeLabel,
        )).toList();
  }

  @override
  Future<void> downloadModel(String modelName,
      {Function(double progress)? onProgress}) async {
    // NVIDIA models are cloud-hosted, no download needed
    onProgress?.call(1.0);
  }

  @override
  Future<void> deleteModel(String modelName) async {
    // Cloud models can't be deleted
  }

  @override
  String? get selectedModel => _selectedModel ?? _model;

  @override
  Future<void> selectModel(String modelName) async {
    _selectedModel = modelName;
  }

  void setApiEndpoint(String endpoint) {
    _apiEndpoint = endpoint;
  }

  @override
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    final apiKey = await _secureStorage.getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('API 키가 설정되지 않았습니다.');
    }

    final model = _selectedModel ?? _model;
    final prompt = _buildPrompt(content, sourceUrl: sourceUrl);

    final response = await http.post(
      Uri.parse(_apiEndpoint),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'messages': [
          {
            'role': 'system',
            'content':
                'You are a Korean memo analysis assistant. Always follow the exact output format. Do not add any introductory or closing remarks.',
          },
          {'role': 'user', 'content': prompt},
        ],
        'temperature': 0.2,
        'max_tokens': 1500,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final assistantMessage =
          data['choices']?[0]?['message']?['content'] as String?;

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
    } else {
      final errorBody = utf8.decode(response.bodyBytes);
      throw Exception('API 오류 (${response.statusCode}): $errorBody');
    }
  }

  String _buildPrompt(String content, {String? sourceUrl}) {
    return '''
You are a Korean memo analysis assistant. Always follow the exact output format. Do not add any introductory or closing remarks.

아래 내용을 분석해서 정해진 형식으로 정리해줘.

내용:
$content

출처 URL: ${sourceUrl ?? '(없음)'}

⚠️ 제공된 내용이 충분하지 않으면, 없는 내용을 지어내지 말고 "제공된 정보가 부족합니다"라고 표시해줘.

카테고리는 반드시 아래 목록 중 하나만 선택해:
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

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }
}
