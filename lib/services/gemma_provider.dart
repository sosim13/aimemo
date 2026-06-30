import 'package:flutter_gemma/flutter_gemma.dart';
import 'llm_provider.dart';
import 'gemma_diag.dart';

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

    final prompt = _buildPrompt(content, sourceUrl: sourceUrl);

    _session = await _model!.createSession(
      temperature: 0.2,
      randomSeed: 42,
      topK: 1,
    );

    try {
      await _session!.addQueryChunk(Message.text(text: prompt, isUser: true));
      final response = await _session!.getResponse();

      if (response.trim().isEmpty) {
        throw Exception('AI가 응답을 생성하지 못했습니다 (빈 결과).');
      }

      return AiAnalysisResult.fromText(
        response,
        sourceUrl: sourceUrl,
        youtubeVideoId: youtubeVideoId,
        originalContent: content,
      );
    } finally {
      await _session?.close();
      _session = null;
    }
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
}
