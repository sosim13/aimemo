import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Synchronous diagnostics logger for GemmaProvider.
///
/// Writes to `gemma_diag.txt` in the app documents directory using
/// synchronous file I/O so the log is flushed to the OS kernel buffer
/// BEFORE the native call that might crash the process.
///
/// Path is pre-resolved in [ensureInitialized] to avoid any async delay
/// during crash-prone operations.
class GemmaDiag {
  static String? _path;
  static bool _initialized = false;

  /// Pre-resolve the log file path. Call once at app startup.
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    _path = '${dir.path}/gemma_diag.txt';
    _initialized = true;
    logSync('=== GemmaDiag initialized ===');
  }

  /// Synchronous write — guaranteed to reach OS buffer before returning.
  static void logSync(String msg) {
    if (_path == null) return;
    try {
      final timestamp = DateTime.now().toIso8601String().substring(11, 23);
      final line = '[$timestamp] $msg\n';
      final f = File(_path!);
      // Append using synchronous write
      if (f.existsSync()) {
        f.writeAsStringSync(line, mode: FileMode.append);
      } else {
        f.writeAsStringSync(line);
      }
    } catch (_) {}
  }

  /// Async version for non-critical logging (before init).
  static Future<void> log(String msg) async {
    try {
      if (!_initialized) await ensureInitialized();
      logSync(msg);
    } catch (_) {}
  }

  static Future<String> read() async {
    try {
      if (_path == null) await ensureInitialized();
      final f = File(_path!);
      if (await f.exists()) {
        return await f.readAsString();
      }
    } catch (_) {}
    return '';
  }

  static Future<void> clear() async {
    try {
      if (_path == null) await ensureInitialized();
      final f = File(_path!);
      if (await f.exists()) {
        await f.writeAsString('');
      }
    } catch (_) {}
  }
}
