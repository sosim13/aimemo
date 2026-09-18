import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'llm_provider.dart';
import 'gemma_provider.dart';
import 'secure_storage_service.dart';

/// Central LLM service that manages the Gemma provider
class LlmService {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal();

  final _secureStorage = SecureStorageService();

  // 즉시 생성 — init() 완료 전(백그라운드 초기화 진행 중)에도 currentProvider /
  // isAvailable() 등을 안전하게 호출할 수 있도록 late final 대신 즉시 초기화한다.
  final GemmaProvider gemmaProvider = GemmaProvider();

  LlmProvider? _currentProvider;

  /// 마지막으로 저장된(선택된) 모델 이름. 실제 로딩은 여기서 하지 않고
  /// AI 기능을 처음 사용하는 시점까지 지연시킨다 — selectModel()은 온디바이스
  /// 모델을 엔진에 올리는 무거운 작업이라, 앱 시작 직후(메인 아이솔레이트)에서
  /// 실행하면 UI가 응답 없음(ANR) 상태에 빠질 수 있기 때문이다.
  String? _pendingModel;

  /// 지연 로딩 중복 실행 방지용. 완료/실패 여부와 관계없이 1회만 트리거한다.
  Future<void>? _modelLoadFuture;

  /// Initialize all providers.
  /// 가벼운 설정 복원만 수행하고, 실제 모델 로딩은 하지 않는다.
  Future<void> init() async {
    // Restore saved settings (가벼운 로컬 저장소 읽기 — 즉시 완료됨)
    _pendingModel = await _secureStorage.getSelectedModel();
    _currentProvider = gemmaProvider;
  }

  /// 저장된 모델이 아직 로드되지 않았다면 지금 로드한다.
  /// analyze()/ask() 등 실제 AI 기능을 사용하는 시점에만 호출되므로,
  /// 앱 시작 직후의 무거운 초기화로 인한 ANR을 피할 수 있다.
  Future<void> _ensureModelLoaded() {
    if (_modelLoadFuture != null) return _modelLoadFuture!;

    final pending = _pendingModel;
    if (pending == null) return Future.value();

    // 이미 다른 경로(설정 화면 등)에서 같은 모델이 로드되어 있으면 재로딩하지 않음.
    if (gemmaProvider.selectedModel == pending) {
      return _modelLoadFuture = Future.value();
    }

    return _modelLoadFuture = gemmaProvider.selectModel(pending).catchError((
      e,
    ) {
      // 실패 시 다음 시도 때 재시도할 수 있도록 캐시를 비운다.
      _modelLoadFuture = null;
      // ignore: avoid_print
      print('LlmService: 저장된 모델 "$pending" 복원 실패: $e');
    });
  }

  /// Get the current active provider
  LlmProvider get currentProvider {
    if (_currentProvider == null) {
      _currentProvider = gemmaProvider;
    }
    return _currentProvider!;
  }

  /// List all available providers (only gemma)
  List<LlmProvider> get providers => [gemmaProvider];

  /// Get currently selected model name
  String? get selectedModel => currentProvider.selectedModel;

  /// Select model for current provider (사용자가 명시적으로 모델을 바꿀 때)
  Future<void> selectModel(String modelName) async {
    await currentProvider.selectModel(modelName);
    await _secureStorage.saveSelectedModel(modelName);
    _pendingModel = modelName;
    _modelLoadFuture = Future.value(); // 이미 로드 완료 상태로 표시
  }

  /// Analyze content with current provider
  Future<AiAnalysisResult> analyze({
    required String content,
    String? sourceUrl,
    String? youtubeVideoId,
  }) async {
    await _ensureModelLoaded();
    return currentProvider.analyze(
      content: content,
      sourceUrl: sourceUrl,
      youtubeVideoId: youtubeVideoId,
    );
  }

  /// 사진(썸네일 등)을 온디바이스 비전 모델로 분석해 텍스트 설명을 만든다.
  /// 캡션 등 텍스트 정보가 전혀 없는 콘텐츠(예: 캡션 없는 인스타그램 게시물)를
  /// 요약 파이프라인에 태울 수 있도록 하기 위한 용도.
  ///
  /// 비전 분석을 사용할 수 없거나 실패하면 null을 반환한다 — 예외를 던지지
  /// 않으므로 호출자는 항상 null 케이스를 폴백으로 처리해야 한다.
  Future<String?> describeImage(Uint8List imageBytes) async {
    await _ensureModelLoaded();
    try {
      return await gemmaProvider.describeImage(imageBytes);
    } catch (e) {
      // ignore: avoid_print
      print('LlmService: describeImage 실패: $e');
      return null;
    }
  }

  /// Free-form Q&A with current provider
  Future<String> ask({
    required String prompt,
    double temperature = 0.7,
    int topK = 40,
    int maxTokens = 2048,
  }) async {
    await _ensureModelLoaded();
    return currentProvider.ask(
      prompt: prompt,
      temperature: temperature,
      topK: topK,
      maxTokens: maxTokens,
    );
  }

  /// Cancel the currently running ask/analyze operation.
  void cancel() {
    currentProvider.cancel();
  }

  /// Check if provider is available
  Future<bool> isAvailable() async {
    return await currentProvider.isAvailable();
  }

  /// Get the best available provider for the current settings
  Future<LlmProvider?> getAvailableProvider() async {
    if (await currentProvider.isAvailable()) {
      return currentProvider;
    }
    return null;
  }
}
