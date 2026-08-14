import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show CancelToken;
import 'llm_provider.dart';
import 'llm_service.dart';

/// 전역 모델 다운로드 관리자.
///
/// 다운로드 상태(진행 중 모델, 진행률)를 위젯 수명과 분리해 보관한다.
/// 화면(ModelManagementScreen)을 벗어나거나 앱이 백그라운드로 전환되어도
/// 다운로드 Future는 계속 실행되며, 화면 재진입 시 현재 진행 상황을
/// 그대로 복원할 수 있다.
///
/// 실제 다운로드는 flutter_gemma → background_downloader가 처리하고,
/// Android에서는 포그라운드 서비스(UIDTJobService)로 실행되므로
/// 홈버튼으로 앱을 나가도 다운로드가 중단되지 않는다.
class ModelDownloadManager {
  ModelDownloadManager._();
  static final ModelDownloadManager instance = ModelDownloadManager._();

  final LlmService _llmService = LlmService();

  /// 현재 다운로드 중인 모델 이름 집합.
  final ValueNotifier<Set<String>> downloading = ValueNotifier(<String>{});

  /// 모델 이름 → 진행률(0.0~1.0).
  final ValueNotifier<Map<String, double>> progress = ValueNotifier(<String, double>{});

  /// 모델 이름 → 취소 토큰. 다운로드 중일 때만 존재.
  final Map<String, CancelToken> _cancelTokens = {};

  /// [modelName] 모델이 현재 다운로드 중인지 여부.
  bool isDownloading(String modelName) => downloading.value.contains(modelName);

  /// [modelName] 모델의 현재 진행률 (0.0~1.0). 다운로드 중이 아니면 0.
  double progressOf(String modelName) => progress.value[modelName] ?? 0.0;

  /// [modelName] 다운로드를 취소한다.
  ///
  /// flutter_gemma의 [CancelToken]을 통해 진행 중인 다운로드를 중단시키고,
  /// background_downloader의 native task까지 취소한다. 취소된 다운로드는
  /// [download]가 [DownloadCancelledException]을 던지며 종료된다.
  void cancel(String modelName) {
    final token = _cancelTokens[modelName];
    if (token == null) return;
    debugPrint('ModelDownloadManager: cancel 요청 $modelName');
    token.cancel('사용자가 다운로드를 취소했습니다');
  }

  /// [info] 모델을 다운로드한다. 완료 시 자동으로 해당 모델을 선택한다.
  ///
  /// 위젯이 dispose되어도 반환된 Future는 계속 실행되므로
  /// 화면 이탈/백그라운드 전환과 무관하게 다운로드가 완료된다.
  /// 실패 시 예외를 다시 던져 호출 측(화면)에서 스낵바를 띄울 수 있게 한다.
  /// 취소된 경우 [DownloadCancelledException]이 던져진다.
  Future<void> download(LlmModelInfo info) async {
    if (isDownloading(info.name)) return;

    final token = CancelToken();
    _cancelTokens[info.name] = token;
    downloading.value = {...downloading.value, info.name};
    progress.value = {...progress.value, info.name: 0.0};

    try {
      await _llmService.currentProvider.downloadModel(
        info.name,
        onProgress: (p) {
          progress.value = {...progress.value, info.name: p};
        },
        cancelToken: token,
      );
      // 기존 동작 유지: 다운로드 완료 후 자동 선택
      await _llmService.selectModel(info.name);
    } finally {
      _cancelTokens.remove(info.name);
      downloading.value = downloading.value.difference({info.name});
      progress.value = {...progress.value}..remove(info.name);
    }
  }
}