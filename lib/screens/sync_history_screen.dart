import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';

/// 동기화 이력 화면.
///
/// 표시 항목:
/// 1. 현재 로그인 상태 (provider, email, user_id)
/// 2. 오프라인 동기화 큐 (실패하여 재시도 대기 중인 항목)
/// 3. 수동 풀(pull) 버튼 — Supabase에서 최신 동기화
class SyncHistoryScreen extends StatefulWidget {
  const SyncHistoryScreen({super.key});

  @override
  State<SyncHistoryScreen> createState() => _SyncHistoryScreenState();
}

class _SyncHistoryScreenState extends State<SyncHistoryScreen> {
  final _db = DatabaseService();
  final _syncService = SyncService();
  List<Map<String, dynamic>> _queueItems = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadQueue();
  }

  Future<void> _loadQueue() async {
    setState(() => _isLoading = true);
    try {
      final items = await _db.getAllSyncQueue();
      if (mounted) {
        setState(() {
          _queueItems = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _message = '로드 실패: $e';
        });
      }
    }
  }

  /// 수동 pull: Supabase에서 최신 데이터 가져오기.
  /// 비로그인이면 SyncService 내부에서 no-op 처리.
  Future<void> _manualPull() async {
    setState(() {
      _isSyncing = true;
      _message = null;
    });
    try {
      await _syncService.pullFromSupabase();
      await _syncService.processSyncQueue();
      await _loadQueue();
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _message = '✅ 동기화 완료';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _message = '❌ 동기화 실패: $e';
        });
      }
    }
  }

  Future<void> _clearQueue() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('대기열 초기화'),
        content: const Text('실패한 동기화 대기열을 모두 삭제하시겠습니까?\n\n'
            '로컬 데이터는 유지되며, 원격에 반영되지 않은 변경사항이 사라집니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _db.clearSyncQueue();
    await _loadQueue();
    if (mounted) {
      setState(() => _message = '대기열을 초기화했습니다.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('동기화 이력'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // --- 로그인 상태 카드 ---
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.cloud_outlined,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              '동기화 상태',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildInfoRow('로그인 여부',
                            auth.isLoggedIn ? '로그인됨' : '비로그인 (게스트)'),
                        if (auth.isLoggedIn) ...[
                          _buildInfoRow('이메일', auth.email ?? '-'),
                          _buildInfoRow(
                              'provider',
                              _providerLabel(auth.currentUser)),
                          _buildInfoRow(
                              'user_id', auth.currentUser?.id ?? '-'),
                        ],
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (auth.isLoggedIn
                                    ? Colors.green
                                    : Colors.orange)
                                .withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                auth.isLoggedIn
                                    ? Icons.check_circle
                                    : Icons.info_outline,
                                color: auth.isLoggedIn
                                    ? Colors.green
                                    : Colors.orange,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  auth.isLoggedIn
                                      ? '구글 계정으로 동기화가 활성화되었습니다.\n'
                                          '데이터는 자동으로 백업됩니다.'
                                      : '로그인하면 기기 간 데이터 동기화가 가능합니다.\n'
                                          '비로그인 상태에서는 로컬에만 저장됩니다.',
                                  style: TextStyle(
                                    color: auth.isLoggedIn
                                        ? Colors.green[700]
                                        : Colors.orange[700],
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // --- 수동 동기화 버튼 ---
                FilledButton.icon(
                  onPressed: auth.isLoggedIn && !_isSyncing ? _manualPull : null,
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_download, size: 18),
                  label: Text(_isSyncing ? '동기화 중...' : '수동 동기화 (Pull)'),
                ),
                const SizedBox(height: 16),

                if (_message != null) ...[
                  Text(
                    _message!,
                    style: TextStyle(
                      color: _message!.contains('❌')
                          ? Colors.red
                          : _message!.contains('✅')
                              ? Colors.green
                              : Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // --- 오프라인 동기화 대기열 ---
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.pending_actions,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              '동기화 대기열 (${_queueItems.length})',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            if (_queueItems.isNotEmpty)
                              TextButton.icon(
                                onPressed: _clearQueue,
                                icon: const Icon(Icons.delete_sweep, size: 18),
                                label: const Text('전체 삭제'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '네트워크 오류 등으로 원격에 반영되지 못한 항목들입니다.\n'
                          '수동 동기화를 누르거나 자동으로 재시도됩니다.',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_queueItems.isEmpty)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              child: Text(
                                '대기 중인 항목이 없습니다',
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          )
                        else
                          ..._queueItems.map((item) {
                            final id = item['id'] as int;
                            final entityType =
                                item['entityType'] as String? ?? '-';
                            final entityId = item['entityId'] as String? ??
                                item['bookId'] as String? ??
                                '-';
                            final op = item['operation'] as String? ?? '-';
                            final createdAt =
                                item['createdAt'] as String? ?? '-';
                            return ListTile(
                              leading: Icon(
                                op == 'delete'
                                    ? Icons.delete_outline
                                    : Icons.sync_problem,
                                color: Colors.orange,
                                size: 28,
                              ),
                              title: Text('$entityType: ${_truncate(entityId, 20)}'),
                              subtitle: Text(
                                  '작업: $op  |  시간: ${_truncate(createdAt, 20)}'),
                              trailing: Text('#$id'),
                              dense: true,
                            );
                          }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// 사용자의 인증 provider 라벨을 반환.
  /// appMetadata에서 provider를 읽어 표시용 문자열로 변환.
  String _providerLabel(user) {
    if (user == null) return '-';
    final metadata = user.appMetadata;
    final provider = metadata['provider'] ?? metadata['providers'];
    if (provider is List && provider.isNotEmpty) {
      return provider.first.toString();
    }
    return provider?.toString() ?? '-';
  }

  String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}…';
  }
}
