import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Simple file-based debug logger for diagnosing fetch issues on device.
/// Logs are written to a rotating buffer and can be shared.
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  final List<String> _buffer = [];
  String? _logPath;

  // --------------------------------------------------------------------
  // TEMP: Supabase 원격 로그 업로드 (인스타그램 요약 실패 원인 진단용).
  // 기기 밖에서도 로그를 볼 수 있도록 매 log() 호출마다 `debug_logs`
  // 테이블에 한 줄씩 fire-and-forget으로 적재한다. 네트워크 실패는 조용히
  // 무시(로컬 버퍼/파일 로그가 이미 있으므로).
  //
  // *** 문제 해결되면 이 블록 전체와
  // *** supabase/migrations/20260901000000_create_debug_logs_table_temp.sql
  // *** 을 함께 제거할 것.
  // --------------------------------------------------------------------
  SupabaseClient? _supabaseClient;

  SupabaseClient? get _supabaseOrNull {
    if (_supabaseClient != null) return _supabaseClient;
    try {
      _supabaseClient = Supabase.instance.client;
    } catch (_) {
      // Supabase 미초기화(백그라운드 isolate 등) — 업로드 생략
      _supabaseClient = null;
    }
    return _supabaseClient;
  }

  void _uploadToSupabaseFireAndForget(String line) {
    final client = _supabaseOrNull;
    if (client == null) return;
    unawaited(
      client.from('debug_logs').insert({
        'user_id': client.auth.currentUser?.id,
        'message': line,
      }).catchError((_) {
        // 네트워크/RLS 오류 등은 무시 — 로컬 로그로 대체 가능
      }),
    );
  }
  // --------------------------------------------------------------------
  // TEMP 블록 끝
  // --------------------------------------------------------------------

  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logPath = '${dir.path}/debug_log.txt';
      // Clear previous log
      await File(_logPath!).writeAsString('');
    } catch (_) {}
  }

  Future<void> log(String message) async {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message';
    _buffer.add(line);
    if (_buffer.length > 500) _buffer.removeAt(0);
    // Also write to console for debug builds
    // ignore: avoid_print
    print(line);
    // Write to file
    if (_logPath != null) {
      try {
        final file = File(_logPath!);
        await file.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {}
    }
    // TEMP: Supabase 원격 업로드 (위 블록 참고) — 제거 시 이 한 줄도 함께 삭제.
    _uploadToSupabaseFireAndForget(line);
  }

  Future<String> getLog() async {
    // Always return in-memory buffer first — guaranteed to have recent entries.
    // Fall back to file for cold-start scenarios (buffer empty, file has data).
    if (_buffer.isNotEmpty) {
      return _buffer.join('\n');
    }
    if (_logPath != null) {
      try {
        return await File(_logPath!).readAsString();
      } catch (_) {}
    }
    return '';
  }

  Future<void> clear() async {
    _buffer.clear();
    if (_logPath != null) {
      try {
        await File(_logPath!).writeAsString('');
      } catch (_) {}
    }
  }
}
