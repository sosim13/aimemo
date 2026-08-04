import 'dart:async';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'llm_provider.dart';
import 'gemma_diag.dart';

/// Thrown when the user explicitly cancels a running analysis/chat.
class UserCancelledException implements Exception {
  final String message = '사용자가 처리를 취소했습니다.';
  @override
  String toString() => message;
}

/// Model entry for flutter_gemma
class _GemmaModel {
  final String id;
  final String displayName;
  final String sizeLabel;
  final String description;
  final ModelType modelType;
  final String url;
  final String fileName;

  const _GemmaModel({
    required this.id,
    required this.displayName,
    required this.sizeLabel,
    required this.description,
    required this.modelType,
    required this.url,
    required this.fileName,
  });
}

/// All models available via flutter_gemma
const _kGemmaModels = <_GemmaModel>[
  _GemmaModel(
    id: 'gemma4-e2b',
    displayName: 'Gemma 4 E2B',
    sizeLabel: '~2.4GB',
    description: '온디바이스 최적화 Gemma 4, 멀티모달, GPU 가속 (권장)',
    modelType: ModelType.gemma4,
    url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
  ),
  _GemmaModel(
    id: 'gemma4-e4b',
    displayName: 'Gemma 4 E4B',
    sizeLabel: '~4.3GB',
    description: '고성능 Gemma 4, 더 깊이 있는 분석',
    modelType: ModelType.gemma4,
    url: 'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    fileName: 'gemma-4-E4B-it.litertlm',
  ),
  _GemmaModel(
    id: 'qwen3-06b',
    displayName: 'Qwen3 0.6B',
    sizeLabel: '~586MB',
    description: '초경량, 저메모리, S23에 최적',
    modelType: ModelType.qwen3,
    url: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    fileName: 'Qwen3-0.6B.litertlm',
  ),
  _GemmaModel(
    id: 'smollm-135m',
    displayName: 'SmolLM 135M',
    sizeLabel: '~167MB',
    description: '초초경량, 기본 텍스트 생성 (품질 낮음)',
    modelType: ModelType.general,
    url: 'https://huggingface.co/litert-community/SmolLM-135M-Instruct/resolve/main/SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task',
    fileName: 'SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task',
  ),
];

/// On-device LLM provider using flutter_gemma (LiteRT-LM backend).
///
/// Supports Gemma 4 E2B/E4B, Qwen3 0.6B, and SmolLM models
/// via flutter_gemma's managed native bridge.
class GemmaProvider implements LlmProvider {
  InferenceModel? _model;
  InferenceModelSession? _session;
  String? _selectedModel;
  bool _initialized = false;

  GemmaProvider() {
    // Eagerly init diag path so critical-path logSync() calls don't yield
    GemmaDiag.ensureInitialized();
  }

  @override
  String get name => '온디바이스 (Gemma)';

  @override
  String get providerId => 'gemma';

  @override
  List<LlmModelInfo> get supportedModels => _kGemmaModels
      .map((m) => LlmModelInfo(
            name: m.id,
            displayName: m.displayName,
            description: m.description,
            sizeLabel: m.sizeLabel,
            isRecommended: m.id == 'gemma4-e2b',
          ))
      .toList();

  @override
  Future<bool> isAvailable() async {
    return true;
  }

  @override
  Future<List<ModelStatus>> getModels() async {
    final results = <ModelStatus>[];
    for (final m in _kGemmaModels) {
      final installed = await FlutterGemma.isModelInstalled(m.fileName);
      GemmaDiag.logSync('isModelInstalled(${m.fileName}) = $installed');
      results.add(ModelStatus(
        name: m.id,
        isDownloaded: installed,
        size: m.sizeLabel,
      ));
    }
    return results;
  }

  @override
  Future<void> downloadModel(String modelName,
      {Function(double progress)? onProgress}) async {
    final info = _kGemmaModels.firstWhere((m) => m.id == modelName);
    GemmaDiag.logSync('downloadModel ENTER: $modelName (${info.fileName})');

    try {
      await FlutterGemma.installModel(
        modelType: info.modelType,
        fileType: ModelFileType.litertlm,
      )
          .fromNetwork(info.url)
          .withProgress((int percent) {
            onProgress?.call(percent / 100.0);
          })
          .install();
      GemmaDiag.logSync('downloadModel OK: $modelName');
    } catch (e) {
      GemmaDiag.logSync('downloadModel FAIL: $modelName — $e');
      rethrow;
    }
  }

  @override
  Future<void> deleteModel(String modelName) async {
    GemmaDiag.logSync('deleteModel ENTER: $modelName');
    final info = _kGemmaModels.firstWhere((m) => m.id == modelName);

    if (_selectedModel == modelName) {
      await _closeEngine();
    }

    await FlutterGemma.uninstallModel(info.fileName);
    GemmaDiag.logSync('deleteModel OK: $modelName');
  }

  @override
  String? get selectedModel => _selectedModel;

  @override
  Future<void> selectModel(String modelName) async {
    GemmaDiag.logSync('selectModel ENTER: $modelName');
    await _closeEngine();

    final info = _kGemmaModels.firstWhere((m) => m.id == modelName);

    // Only install if not already cached
    final isInstalled = await FlutterGemma.isModelInstalled(info.fileName);
    GemmaDiag.logSync('isModelInstalled(${info.fileName}) = $isInstalled');

    if (!isInstalled) {
      GemmaDiag.logSync('Downloading model: ${info.id} (${info.fileName})');
      try {
        await FlutterGemma.installModel(
          modelType: info.modelType,
          fileType: ModelFileType.litertlm,
        )
            .fromNetwork(info.url)
            .install();
        GemmaDiag.logSync('Install OK after network download');
      } catch (e) {
        GemmaDiag.logSync('Install FAILED: $e');
        rethrow;
      }
    } else {
      GemmaDiag.logSync('Model already installed, skipping download');
    }

    // Log installed model info before loading
    try {
      final installedList = await FlutterGemma.listInstalledModels();
      GemmaDiag.logSync('Installed models: $installedList');
    } catch (e) {
      GemmaDiag.logSync('listInstalledModels error: $e');
    }

    // CPU-only to avoid potential GPU driver crashes
    try {
      GemmaDiag.logSync('Calling getActiveModel(CPU) for ${info.id}...');
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.cpu,
      );
      GemmaDiag.logSync('getActiveModel OK');
    } catch (e) {
      GemmaDiag.logSync('getActiveModel FAILED: $e');
      rethrow;
    }

    _selectedModel = modelName;
    _initialized = true;
    GemmaDiag.logSync('selectModel OK: $modelName (initialized=true)');
  }

  /// Maximum characters of content to send to the model.
  /// Long videos/transcripts are truncated to this size before analysis to avoid
  /// "INVALID_ARGUMENT: Input token ids" errors when content exceeds the model's
  /// context window. On-device models typically have 2K~8K token limits; with
  /// Korean text (~2 chars per token) plus the prompt template (~500 tokens),
  /// 1500 chars leaves enough room for the response.
  static const int _maxContentChars = 1500;

  @override
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    GemmaDiag.logSync('analyze ENTER (initialized=$_initialized, model=${_model != null})');
    if (!_initialized || _model == null) {
      final msg = 'Gemma 엔진이 초기화되지 않았습니다. 모델을 먼저 선택해주세요.';
      GemmaDiag.logSync('analyze FAIL: $msg');
      throw Exception(msg);
    }

    // Keep the full content for the keyword-based category fallback
    // (the model itself only sees a truncated version).
    final fullContent = content;

    // Truncate content if too long for the model's context window
    if (content.length > _maxContentChars) {
      GemmaDiag.logSync('Content too long (${content.length} chars), truncating to $_maxContentChars');
      content = '${content.substring(0, _maxContentChars)}\n\n[...원본 내용이 너무 길어 앞부분 ${_maxContentChars}자만 분석했습니다. 뒷부분은 생략되었습니다.]';
    }

    final prompt = _buildPrompt(content, sourceUrl: sourceUrl);

    _session = await _model!.createSession(
      temperature: 0.2,
      randomSeed: 42,
      topK: 1,
    );

    try {
      await _session!.addQueryChunk(Message.text(text: prompt, isUser: true));
      final response = await _session!.getResponse();

      // Check if user cancelled during generation (session may have been
      // closed by cancel(), causing getResponse() to throw — but in case
      // it didn't throw, check the flag explicitly).
      if (_cancelled) {
        _cancelled = false;
        throw UserCancelledException();
      }

      if (response.trim().isEmpty) {
        throw Exception('AI가 응답을 생성하지 못했습니다 (빈 결과).');
      }

      return AiAnalysisResult.fromText(
        response,
        sourceUrl: sourceUrl,
        youtubeVideoId: youtubeVideoId,
        originalContent: fullContent,
      );
    } catch (e) {
      // If the session was closed by cancel(), convert to a clean error
      if (_cancelled) {
        _cancelled = false;
        throw UserCancelledException();
      }
      rethrow;
    } finally {
      if (_session != null) {
        await _session!.close();
        _session = null;
      }
    }
  }

  /// Tracks the active chat session so we can cancel mid-generation.
  InferenceModelSession? _chatSession;

  @override
  Future<String> ask({
    required String prompt,
    double temperature = 0.7,
    int topK = 40,
    int maxTokens = 2048,
  }) async {
    GemmaDiag.logSync(
      'ask ENTER (initialized=$_initialized, model=${_model != null})',
    );
    if (!_initialized || _model == null) {
      throw Exception(
        'Gemma 엔진이 초기화되지 않았습니다. 모델을 먼저 선택해주세요.',
      );
    }

    // Check if already cancelled before starting
    if (_cancelled) {
      _cancelled = false;
      throw Exception('AI 응답이 취소되었습니다.');
    }

    final session = await _model!.createSession(
      temperature: temperature,
      randomSeed: 42,
      topK: topK,
    );
    _chatSession = session;
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));

      // Poll for cancellation during generation
      final response = await _waitWithCancel(session);

      if (response.trim().isEmpty) {
        throw Exception('AI가 응답을 생성하지 못했습니다 (빈 결과).');
      }

      return response.trim();
    } finally {
      await session.close();
      _chatSession = null;
    }
  }

  /// Wraps [session.getResponse()] so we can abort on cancel.
  Future<String> _waitWithCancel(InferenceModelSession session) async {
    // Start the real response future
    final responseFuture = session.getResponse();

    // Poll every 200ms until either response arrives or cancel is signalled
    while (true) {
      try {
        final response = await responseFuture.timeout(
          const Duration(milliseconds: 200),
        );
        return response; // response arrived
      } on TimeoutException {
        // Still generating — check cancel flag
        if (_cancelled) {
          _cancelled = false;
          throw Exception('AI 응답이 취소되었습니다.');
        }
        // Continue polling
      }
    }
  }

  bool _cancelled = false;

  @override
  void cancel() {
    GemmaDiag.logSync('cancel() called');
    _cancelled = true;
    // Abort any running analyze session
    _session?.close();
    _session = null;
    // Abort any running chat session
    _chatSession?.close();
    _chatSession = null;
  }

  Future<void> _closeEngine() async {
    GemmaDiag.logSync('_closeEngine ENTER (initialized=$_initialized)');
    await _session?.close();
    _session = null;
    if (_model != null) {
      await _model!.close();
      _model = null;
    }
    _initialized = false;
    _selectedModel = null;
    GemmaDiag.logSync('_closeEngine OK');
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

카테고리 선택 기준 (중요):
- 맛집 & 카페: 특정 식당·카페를 소개하거나 방문 후기·추천·위치·가격·분위기를 다루는 영상 (먹으러 가는 곳)
- 요리 & 레시피: 음식을 직접 만드는 방법·조리 과정·재료·조리법을 다루는 영상 (직접 만드는 법)
- 식당에 대한 소개/후기/추천이면 '맛집 & 카페', 요리하는 과정이면 '요리 & 레시피'

반드시 아래 형식만 출력해줘 (다른 말 하지 마, 카테고리는 위 목록 중 하나만):

## 제목
영상 제목 30자 이내

## 카테고리
개발

## 키워드
키워드1, 키워드2, 키워드3, 키워드4, 키워드5

## 주소
(주소를 찾을 수 없으면 "없음"이라고 적어줘. 예: "서울특별시 강남구 테헤란로 123" 또는 "서울 강남구 역삼동 123-4" 또는 "경기도 성남시 분당구 정자동 45")

## 내용

📌 **핵심 내용 3줄 요약**
1. 첫 번째 요점
2. 두 번째 요점
3. 세 번째 요점

📝 **상세 내용**
- 상세 내용 1
- 상세 내용 2
- 상세 내용 3

아래는 카테고리 선택 예시다. 예시를 그대로 출력하지 말고, 반드시 위 형식만 출력해라.

예시 1:
내용: 성수동에서 유명한 파스타 맛집에 다녀왔어요. 웨이팅 30분, 시그니처 메뉴는 크림 파스타예요. 분위기 좋고 재방문 의사 있습니다.
## 카테고리
맛집 & 카페

예시 2:
내용: 오늘은 집에서 크림 파스타를 만들어볼게요. 먼저 재료를 준비하고, 중불에서 5분간 볶아주세요. 완성되면 접시에 담아 파슬리를 뿌립니다.
## 카테고리
요리 & 레시피
''';
  }
}
