import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'llm_provider.dart';
import 'litert_bridge.dart';

/// On-device LLM provider using LiteRT-LM (Gemma 4 E2B/E4B)
class LiteRtProvider implements LlmProvider {
  @override
  String get name => '온디바이스 (LiteRT)';

  @override
  String get providerId => 'litert';

  String? _modelPath;
  String? _selectedModel;
  bool _engineInitialized = false;

  /// Directory where downloaded models are stored
  String? _modelsDir;

  /// Public read-only access for LlmService
  String? get modelsDir => _modelsDir;

  LiteRtProvider({String? modelsDir, String? model}) {
    _modelsDir = modelsDir;
    _selectedModel = model;
  }

  void setModelsDir(String dir) {
    _modelsDir = dir;
  }

  @override
  Future<bool> isAvailable() async {
    // Check if LiteRT-LM plugin is available on this platform
    return await LiteRtBridge.isAvailable();
  }

  @override
  Future<List<ModelStatus>> getModels() async {
    if (_modelsDir == null) return [];

    final dir = Directory(_modelsDir!);
    if (!await dir.exists()) return [];

    final models = <ModelStatus>[];
    try {
      final files = await dir.list().toList();
      for (final file in files) {
        if (file is File && file.path.endsWith('.litertlm')) {
          final stat = await file.stat();
          models.add(ModelStatus(
            name: p.basenameWithoutExtension(file.path),
            isDownloaded: true,
            size: _formatSize(stat.size),
          ));
        }
      }
    } catch (_) {}

    return models;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Future<void> downloadModel(String modelName,
      {Function(double progress)? onProgress}) async {
    if (_modelsDir == null) {
      throw Exception('모델 저장 경로가 설정되지 않았습니다.');
    }

    // Find model info
    final modelInfo = supportedModels.where((m) => m.name == modelName).firstOrNull;

    // Resolve download URL: direct URL > HuggingFace > fallback
    final downloadUrl = modelInfo?.downloadUrl ??
        _buildHuggingFaceUrl(modelInfo, modelName);

    // Resolve file name for saving
    final fileName = modelInfo?.huggingFaceFile ?? '$modelName.litertlm';
    final savePath = p.join(_modelsDir!, fileName);

    // Download with progress tracking
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception(
            '다운로드 실패 (${response.statusCode}): $downloadUrl');
      }

      final totalBytes = response.contentLength ?? -1;
      var receivedBytes = 0;
      final fileStream = response.stream;

      final sink = File(savePath).openWrite();
      await for (final chunk in fileStream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }

    onProgress?.call(1.0);
  }

  @override
  Future<void> deleteModel(String modelName) async {
    if (_modelsDir == null) return;
    final filePath = _resolveModelPath(modelName);
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Build HuggingFace download URL from model info.
  String _buildHuggingFaceUrl(LlmModelInfo? info, String modelName) {
    final repoName = info?.huggingFaceRepo ??
        'litert-community/${modelName.replaceAll(':', '-').replaceAll('.', '-')}-litert-lm';
    final fileName = info?.huggingFaceFile ?? '$modelName.litertlm';
    return 'https://huggingface.co/$repoName/resolve/main/$fileName';
  }

  /// Resolve the actual file path on disk for a model name.
  /// Checks the huggingFaceFile first, falls back to $modelName.litertlm.
  String _resolveModelPath(String modelName) {
    if (_modelsDir == null) return '$modelName.litertlm';
    final info = supportedModels.where((m) => m.name == modelName).firstOrNull;
    final fileName = info?.huggingFaceFile ?? '$modelName.litertlm';
    return p.join(_modelsDir!, fileName);
  }

  @override
  String? get selectedModel => _selectedModel;

  @override
  Future<void> selectModel(String modelName) async {
    _selectedModel = modelName;
    _engineInitialized = false;

    // Initialize the engine with the selected model
    if (_modelsDir != null) {
      _modelPath = _resolveModelPath(modelName);
      if (await File(_modelPath!).exists()) {
        _engineInitialized = await LiteRtBridge.initEngine(_modelPath!)
            .timeout(const Duration(seconds: 120), onTimeout: () {
          return false;
        });
      }
    }
  }

  @override
  List<LlmModelInfo> get supportedModels => const [
        LlmModelInfo(
          name: 'gemma-4-E2B-it',
          displayName: 'Gemma 4 E2B (LiteRT)',
          description: '온디바이스 최적화 Gemma 4, ~2.5GB (권장)',
          sizeLabel: '~2.5GB',
          isRecommended: true,
        ),
        LlmModelInfo(
          name: 'gemma-4-E2B-it-web',
          displayName: 'Gemma 4 E2B Web (LiteRT)',
          description: '웹 최적화, ~2.0GB, 낮은 메모리',
          sizeLabel: '~2.0GB',
          huggingFaceRepo: 'litert-community/gemma-4-E2B-it-litert-lm',
          huggingFaceFile: 'gemma-4-E2B-it-web.litertlm',
        ),
        LlmModelInfo(
          name: 'gemma-4-E4B-it',
          displayName: 'Gemma 4 E4B (LiteRT)',
          description: '고성능 온디바이스, ~3.6GB',
          sizeLabel: '~3.6GB',
        ),
        LlmModelInfo(
          name: 'Qwen3-0.6B-mixed-int4',
          displayName: 'Qwen 3 0.6B INT4 (LiteRT)',
          description: '초경량 int4 양자화, ~400MB, 최저 메모리',
          sizeLabel: '~400MB',
          downloadUrl: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/qwen3_0_6b_mixed_int4.litertlm',
          huggingFaceFile: 'qwen3_0_6b_mixed_int4.litertlm',
        ),
        LlmModelInfo(
          name: 'Qwen3-0.6B',
          displayName: 'Qwen 3 0.6B (LiteRT)',
          description: '초경량, ~600MB, 비gated, S23에 최적',
          sizeLabel: '~600MB',
          isRecommended: true,
          downloadUrl: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
          huggingFaceFile: 'Qwen3-0.6B.litertlm',
        ),
      ];

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

  @override
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    if (!_engineInitialized && _selectedModel != null) {
      // Try to init engine
      if (_modelsDir != null && _selectedModel != null) {
        _modelPath = _resolveModelPath(_selectedModel!);
        if (await File(_modelPath!).exists()) {
          _engineInitialized = await LiteRtBridge.initEngine(_modelPath!)
              .timeout(const Duration(seconds: 120), onTimeout: () => false);
        }
      }
    }

    if (!_engineInitialized) {
      throw Exception('LiteRT 엔진이 초기화되지 않았습니다. 모델을 먼저 선택해주세요.');
    }

    final prompt = _buildPrompt(content, sourceUrl: sourceUrl);

    final result = await LiteRtBridge.generate(
      prompt,
      maxTokens: 1500,
      temperature: 0.2,
    ).timeout(const Duration(seconds: 90), onTimeout: () {
      throw Exception('AI 분석 시간이 초과되었습니다 (90초).');
    });

    if (result == null || result.trim().isEmpty) {
      throw Exception('AI가 응답을 생성하지 못했습니다 (빈 결과).');
    }

    return AiAnalysisResult.fromText(
      result,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
      originalContent: content,
    );
  }
}
