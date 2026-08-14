import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show DownloadCancelledException;
import '../services/llm_service.dart';
import '../services/llm_provider.dart';
import '../services/model_download_manager.dart';

class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({super.key});

  @override
  State<ModelManagementScreen> createState() => _ModelManagementScreenState();
}

class _ModelManagementScreenState extends State<ModelManagementScreen> {
  final _llmService = LlmService();
  final _downloadManager = ModelDownloadManager.instance;
  List<ModelStatus> _downloadedModels = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // 다운로드 상태는 전역 매니저가 보관 — 화면 이탈/재진입 시에도
    // 진행 상황이 유지되도록 매니저의 변경 알림을 구독한다.
    _downloadManager.downloading.addListener(_onDownloadStateChanged);
    _downloadManager.progress.addListener(_onDownloadStateChanged);
    _loadModels();
  }

  @override
  void dispose() {
    _downloadManager.downloading.removeListener(_onDownloadStateChanged);
    _downloadManager.progress.removeListener(_onDownloadStateChanged);
    super.dispose();
  }

  void _onDownloadStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final models = await _llmService.currentProvider.getModels();
      if (mounted) {
        setState(() {
          _downloadedModels = models;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '서버에 연결할 수 없습니다: $e';
        });
      }
    }
  }

  bool _isModelDownloaded(String modelName) {
    return _downloadedModels.any((m) => m.name == modelName && m.isDownloaded);
  }

  bool _isModelSelected(String modelName) {
    return _llmService.selectedModel == modelName;
  }

  Future<void> _pullModel(LlmModelInfo info) async {
    if (_downloadManager.isDownloading(info.name)) return;

    try {
      // 전역 매니저가 다운로드를 실행 — 위젯 dispose와 무관하게 계속 진행.
      // 화면을 나가도 다운로드가 유지되고, 재진입 시 매니저 상태로 복원된다.
      await _downloadManager.download(info);
      // Refresh model list after download
      if (mounted) await _loadModels();
      // Auto-select the downloaded model (manager가 완료 후 선택까지 처리)
      if (mounted) setState(() {});
    } catch (e) {
      // 사용자가 직접 취소한 경우는 오류 스낵바 대신 조용히 처리한다.
      if (e is DownloadCancelledException) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('다운로드 실패: $e'),
            backgroundColor: Colors.red[600],
          ),
        );
      }
    }
  }

  void _cancelDownload(LlmModelInfo info) {
    _downloadManager.cancel(info.name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('다운로드를 취소했습니다.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _deleteModel(ModelStatus model) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('모델 삭제'),
        content: Text('"${model.name}" 모델을 삭제하시겠습니까?\n다시 사용하려면 재다운로드가 필요합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _llmService.currentProvider.deleteModel(model.name);
        await _loadModels();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('삭제 실패: $e'),
              backgroundColor: Colors.red[600],
            ),
          );
        }
      }
    }
  }

  Future<void> _selectModel(String modelName) async {
    try {
      await _llmService.selectModel(modelName);
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$modelName" 모델이 선택되었습니다.'),
            backgroundColor: Colors.green[600],
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('모델 선택 실패: $e'),
            backgroundColor: Colors.red[600],
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = _llmService.currentProvider;
    final predefined = provider.supportedModels;

    return Scaffold(
      appBar: AppBar(
        title: const Text('모델 관리'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadModels,
            tooltip: '새로고침',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadModels,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Provider info
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(Icons.dns,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '연결된 제공자',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer),
                                ),
                                Text(
                                  provider.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.check_circle,
                            color: Colors.green[600],
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Currently selected model
                  if (_llmService.selectedModel != null) ...[
                    Text(
                      '현재 선택된 모델',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      color: Colors.green[50],
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.green[300]!),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.model_training, color: Colors.green[700]),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _llmService.selectedModel!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green[100],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '사용 중',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green[800],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Downloaded models section
                  Text(
                    '다운로드된 모델',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  if (_downloadedModels.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(Icons.cloud_download_outlined,
                                  size: 48, color: Colors.grey[400]),
                              const SizedBox(height: 8),
                              Text(
                                '다운로드된 모델이 없습니다',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                              Text(
                                '아래 목록에서 모델을 선택하여 다운로드하세요',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    ..._downloadedModels.where((m) => m.isDownloaded).map((model) => _buildDownloadedModelCard(model)),

                  const SizedBox(height: 24),

                  // Available models section
                  Text(
                    '다운로드 가능한 모델',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ...predefined.map((info) => _buildAvailableModelCard(info)),
                ],
              ),
            ),
    );
  }

  Widget _buildDownloadedModelCard(ModelStatus model) {
    final isSelected = _isModelSelected(model.name);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(
          Icons.check_circle,
          color: Colors.green[600],
        ),
        title: Text(
          model.name,
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${model.parameterSize ?? ''} ${model.quantizationLevel != null ? '· ${model.quantizationLevel}' : ''}${model.size != null ? ' · ${model.size}' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '선택됨',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              TextButton(
                onPressed: () => _selectModel(model.name),
                child: const Text('선택'),
              ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[400], size: 20),
              onPressed: () => _deleteModel(model),
              tooltip: '삭제',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvailableModelCard(LlmModelInfo info) {
    final isDownloaded = _isModelDownloaded(info.name);
    // 전역 매니저에서 진행 상태를 읽는다 — 화면 재진입 시에도 유지됨
    final isDownloading = _downloadManager.isDownloading(info.name);
    final progress = _downloadManager.progressOf(info.name);

    if (isDownloaded) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            info.displayName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                          if (info.isRecommended)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.amber[100],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '추천',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.amber[900],
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${info.name} · ${info.sizeLabel}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                if (isDownloading)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: () => _cancelDownload(info),
                        icon: Icon(Icons.close, color: Colors.red[400]),
                        tooltip: '다운로드 취소',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  )
                else
                  IconButton(
                    onPressed: () => _pullModel(info),
                    icon: Icon(Icons.cloud_download_outlined,
                        color: Theme.of(context).colorScheme.primary),
                    tooltip: '다운로드',
                  ),
              ],
            ),
            if (info.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                info.description,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
            if (isDownloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress > 0 ? progress : null),
              const SizedBox(height: 4),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
