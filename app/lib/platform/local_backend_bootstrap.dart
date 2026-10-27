import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows 客户端直接打开时，按需启动同机 Python 服务。
class LocalBackendBootstrap {
  static String? lastError;
  static Process? _serverProcess;
  static Future<void>? _starting;

  static void _trace(String message) {
    try {
      final base = Platform.environment['LOCALAPPDATA'];
      if (base == null || base.isEmpty) return;
      final log = File('$base${Platform.pathSeparator}ClassNotesAssistant'
          '${Platform.pathSeparator}bootstrap.log');
      log.parent.createSync(recursive: true);
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> ensureRunning() {
    if (!Platform.isWindows) return Future<void>.value();
    final pending = _starting;
    if (pending != null) return pending;
    final attempt = _ensureRunning();
    _starting = attempt;
    return attempt.whenComplete(() {
      if (identical(_starting, attempt)) _starting = null;
    });
  }

  static Future<void> _ensureRunning() async {
    if (!Platform.isWindows) return;
    if (_serverProcess != null) return;
    _trace('begin executable=${Platform.resolvedExecutable}');
    if (await _isOurServerReady()) {
      lastError = null;
      _trace('already ready');
      return;
    }

    final root = _findBackendRoot();
    if (root == null) {
      lastError = '找不到随程序提供的后端文件。请从完整项目或完整安装包启动。';
      _trace(lastError!);
      return;
    }
    _trace('root=${root.path}');
    final script = File('${root.path}${Platform.pathSeparator}scripts'
        '${Platform.pathSeparator}run_server_hidden.ps1');
    try {
      final process = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
        ],
        workingDirectory: root.path,
        mode: ProcessStartMode.normal,
      );
      _serverProcess = process;
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      unawaited(process.exitCode.then((code) {
        _trace('launcher exited code=$code');
        if (identical(_serverProcess, process)) _serverProcess = null;
        if (code != 0) {
          lastError = '本机服务启动失败，请查看项目 logs/server.stderr.log';
        }
      }));
      lastError = null;
      _trace('launched ${script.path} pid=${process.pid}');
    } on ProcessException catch (error) {
      lastError = '无法启动本机后端：${error.message}';
      _trace(lastError!);
    }
  }

  static Directory? _findBackendRoot() {
    var current = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 9; i++) {
      for (final candidate in [
        current,
        Directory('${current.path}${Platform.pathSeparator}backend'),
      ]) {
        final script = File('${candidate.path}${Platform.pathSeparator}scripts'
            '${Platform.pathSeparator}run_server_hidden.ps1');
        final server = File('${candidate.path}${Platform.pathSeparator}server'
            '${Platform.pathSeparator}app${Platform.pathSeparator}main.py');
        if (script.existsSync() && server.existsSync()) return candidate;
      }
      if (current.parent.path == current.path) break;
      current = current.parent;
    }
    return null;
  }

  static Future<bool> _isOurServerReady() async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(milliseconds: 800);
    try {
      final request = await client
          .getUrl(
            Uri.parse('http://127.0.0.1:8000/api/health'),
          )
          .timeout(const Duration(milliseconds: 800));
      final response =
          await request.close().timeout(const Duration(milliseconds: 800));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(milliseconds: 800));
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(body);
      return decoded is Map &&
          decoded['code'] == 0 &&
          decoded['data'] is Map &&
          decoded['data']['app'] == 'class_notes_assistant';
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
