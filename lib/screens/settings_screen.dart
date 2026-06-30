import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../services/gemma_diag.dart';
import '../services/llm_service.dart';
import '../services/debug_logger.dart';
import 'model_management_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _llmService = LlmService();

  bool _isLoading = true;
  bool _isSaving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _initGemmaEngine() async {
    try {
      // Check if any model is downloaded
      final models = await _llmService.gemmaProvider.getModels();
      final downloaded = models.where((m) => m.isDownloaded).toList();
      if (downloaded.isEmpty) {
        setState(() => _message =
            '❌ 다운로드된 Gemma 모델이 없습니다. "모델 관리"에서 모델을 먼저 다운로드해주세요.');
        return;
      }

      // Auto-select first downloaded model if none selected
      if (_llmService.gemmaProvider.selectedModel == null) {
        await _llmService.gemmaProvider.selectModel(downloaded.first.name);
      }

      setState(() => _message = '✅ Gemma 엔진 준비 완료!');
    } catch (e) {
      setState(() => _message = '❌ Gemma 엔진 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('설정'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- AI Model Provider (Gemma only) ---
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Gemma 온디바이스 AI',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'flutter_gemma 엔진으로 Gemma 4 E2B/Qwen3 등을 기기에서 직접 실행합니다.\n'
                    '"모델 관리"에서 모델을 다운로드 후 사용하세요.',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _initGemmaEngine,
                        icon: const Icon(Icons.power_settings_new, size: 16),
                        label: const Text('엔진 초기화'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const ModelManagementScreen()),
                          );
                        },
                        icon: const Icon(Icons.model_training, size: 16),
                        label: const Text('모델 관리'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '권장 모델: Gemma 4 E2B (2.4GB) 또는 Qwen3 0.6B (586MB)\n'
                    '저메모리 기기(S23 등)에서는 Qwen3 0.6B를 권장합니다.',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                    ),
                  ),

                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      style: TextStyle(
                        color: _message!.contains('❌')
                            ? Colors.red
                            : Colors.green,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- Debug Log Section ---
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bug_report,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '디버그 로그',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '웹페이지 URL 공유 시 내용이 안 불러와지는 문제를 진단하기 위한 로그입니다.',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _showDebugLog,
                    icon: const Icon(Icons.visibility, size: 18),
                    label: const Text('로그 보기 & 복사'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _showDiagLog,
                    icon: const Icon(Icons.bug_report_outlined, size: 18),
                    label: const Text('진단 로그 보기'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _clearDiagLogs,
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: const Text('로그 초기화'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- Info Section ---
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '앱 사용 방법',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildInfoItem(
                    Icons.edit_note,
                    '메모 입력',
                    '텍스트를 입력하거나 URL을 공유하면 AI가 내용을 분석하여 자동으로 정리합니다.',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoItem(
                    Icons.smart_toy,
                    '온디바이스 AI',
                    'Gemma 엔진으로 기기에서 직접 AI가 동작합니다. 인터넷이 필요 없습니다.',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoItem(
                    Icons.category,
                    '카테고리 분류',
                    'AI가 내용에 맞게 개발, 디자인, 요리 등 다양한 카테고리로 자동 분류합니다.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey[500]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Text(
                description,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showDiagLog() async {
    String content;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file1 = File('${dir.path}/up_diag.txt');
      final file2 = File('${dir.path}/mis_diag.txt');
      final parts = <String>[];

      if (await file1.exists()) {
        parts.add('=== URL Processing (up_diag.txt) ===');
        parts.add(await file1.readAsString());
      }
      if (await file2.exists()) {
        parts.add('=== Memo Input (mis_diag.txt) ===');
        parts.add(await file2.readAsString());
      }

      // Gemma engine diagnostics
      try {
        final gemmaLog = await GemmaDiag.read();
        if (gemmaLog.isNotEmpty) {
          parts.add('=== Gemma Engine (gemma_diag.txt) ===');
          parts.add(gemmaLog);
        }
      } catch (_) {}

      if (parts.isNotEmpty) {
        content = parts.join('\n\n');
      } else {
        content = '(진단 로그 파일이 없습니다.\n'
            'URL을 공유하거나 MemoInputScreen에서 URL을 입력한 후 확인해주세요.)';
      }
    } catch (e) {
      content = '오류: $e';
    }
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _DebugLogScreen(logContent: content),
      ),
    );
  }

  Future<void> _clearDiagLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('진단 로그 초기화'),
        content: const Text('모든 진단 로그(URL 처리, 메모 입력)를 삭제하시겠습니까?\n\n'
            '이전 로그가 사라지므로 새로 테스트한 기록만 확인할 수 있습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final f1 = File('${dir.path}/up_diag.txt');
      final f2 = File('${dir.path}/mis_diag.txt');
      if (await f1.exists()) await f1.writeAsString('');
      if (await f2.exists()) await f2.writeAsString('');
      await GemmaDiag.clear();
      if (mounted) {
        setState(() => _message = '🗑️ 진단 로그가 초기화되었습니다.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '❌ 초기화 중 오류: $e');
      }
    }
  }

  Future<void> _showDebugLog() async {
    final logContent = await DebugLogger().getLog();
    if (!mounted) return;

    if (logContent.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그가 없습니다. URL을 공유한 후 다시 확인해주세요.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _DebugLogScreen(logContent: logContent),
      ),
    );
  }
}

/// Full-screen debug log viewer
class _DebugLogScreen extends StatelessWidget {
  final String logContent;

  const _DebugLogScreen({required this.logContent});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('디버그 로그'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '전체 복사',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logContent));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('로그가 복사되었습니다.')),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          logContent,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ),
    );
  }
}
