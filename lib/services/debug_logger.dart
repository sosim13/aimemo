import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Simple file-based debug logger for diagnosing fetch issues on device.
/// Logs are written to a rotating buffer and can be shared.
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  final List<String> _buffer = [];
  String? _logPath;

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
