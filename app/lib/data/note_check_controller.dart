import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'note_file_synchronizer.dart';
import '../platform/local_notes_bridge.dart';

/// Daily metadata audit and the app-owned foreground file synchronizer.
class NoteCheckController extends ChangeNotifier {
  NoteCheckController(
      {required this.api,
      bool? android,
      bool enableFileSync = false,
      Future<Map<String, dynamic>?> Function()? folderInfo,
      Future<List<Map<String, dynamic>>> Function()? readLocal,
      DateTime Function()? now})
      : android = android ?? Platform.isAndroid,
        _now = now ?? DateTime.now,
        _folderInfo = folderInfo ?? LocalNotesBridge.folderInfo,
        _readLocal = readLocal ?? LocalNotesBridge.list {
    if (enableFileSync && this.android) {
      fileSync = NoteFileSynchronizer(api: api, onUpdated: _syncFinished);
      fileSync!.addListener(_syncChanged);
    }
  }
  NoteFileSynchronizer? fileSync;
  void _syncFinished() {
    _autoDay = null;
    final pending = _pending;
    if (pending != null) {
      unawaited(pending.then((_) {
        if (!_disposed && _foreground) return check();
      }));
    } else if (!_disposed && _foreground) {
      unawaited(check());
    }
  }

  void _syncChanged() {
    if (!_disposed) notifyListeners();
  }

  final ApiClient api;
  final bool android;
  final DateTime Function() _now;
  final Future<Map<String, dynamic>?> Function() _folderInfo;
  final Future<List<Map<String, dynamic>>> Function() _readLocal;
  final localRevision = ValueNotifier<int>(0);
  List<Map<String, dynamic>>? localNotes;
  List<Map<String, dynamic>> reports = [];
  bool checking = false;
  bool choosing = false;
  String? choiceMessage;
  bool needsFolder = false;
  String? error;
  String? folderLabel;
  Timer? _timer;
  Timer? _choiceTimer;
  bool _choiceRefreshDue = false;
  Future<void>? _pending;
  bool _pendingAutomatic = false;
  bool _disposed = false;
  bool _foreground = false;
  bool _listening = false;
  int _generation = 0;
  String? _localSignature;
  String? _scope;
  String? _autoDay;
  static const _cacheKey = 'cna_note_check_last';

  void start() {
    if (!_listening) {
      LocalNotesBridge.changed.addListener(scopeChanged);
      _listening = true;
    }
    setForeground(true);
  }

  void setForeground(bool value) {
    _foreground = value;
    _choiceTimer?.cancel();
    fileSync?.setForeground(value);
    _timer?.cancel();
    _timer = null;
    if (value && !_disposed) {
      unawaited(checkIfDue());
      final now = _now();
      final next = DateTime(now.year, now.month, now.day + 1);
      _timer = Timer(next.difference(now) + const Duration(seconds: 2), () {
        if (_foreground && !_disposed) setForeground(true);
      });
    }
  }

  void _watchChoices() {
    _choiceTimer?.cancel();
    if (android ||
        !_foreground ||
        _disposed ||
        (!_choiceRefreshDue &&
            !reports.any((r) => (r['choices'] as List? ?? [])
                .any((c) => c['status'] == 'pending')))) return;
    _choiceTimer = Timer(const Duration(seconds: 15), _refreshChoices);
  }

  Future<void> _refreshChoices() async {
    if (checking || choosing) {
      _watchChoices();
      return;
    }
    final generation = _generation,
        endpoint = api.baseUrl,
        token = api.pairingToken;
    bool current() =>
        !_disposed &&
        _foreground &&
        generation == _generation &&
        endpoint == api.baseUrl &&
        token == api.pairingToken;
    try {
      for (final report in reports) {
        if (!current()) return;
        final previous = report['choices'] as List? ?? [];
        if (report['folder_id'] == null ||
            !previous.any((c) => c['status'] == 'pending')) continue;
        final response = await api.getNoteChoices({
          'device_id': '${report['device_id']}',
          'folder_id': '${report['folder_id']}',
          'vault_id': '${report['vault_id']}'
        });
        if (!response.ok) throw StateError(response.error ?? '无法读取待执行选择');
        if (!current() || checking || choosing) return;
        for (final old in previous.where((c) => c['status'] == 'pending')) {
          if (response.data!
              .any((c) => c['id'] == old['id'] && c['status'] != 'pending')) {
            _choiceRefreshDue = true;
          }
        }
        report['choices'] = response.data!;
      }
      if (current() && _choiceRefreshDue) {
        await check();
      }
    } catch (e) {
      if (current()) error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      if (current()) {
        notifyListeners();
        _watchChoices();
      }
    }
  }

  void scopeChanged() {
    fileSync?.invalidate();
    _generation++;
    _scope = null;
    _autoDay = null;
    reports = [];
    localNotes = null;
    _localSignature = null;
    error = null;
    choiceMessage = null;
    _choiceRefreshDue = false;
    _choiceTimer?.cancel();
    if (!_disposed) notifyListeners();
    if (_foreground) {
      // A scope change while scanning must schedule a fresh check after it.
      final pending = _pending;
      if (pending != null) {
        unawaited(pending.then((_) {
          if (!_disposed && _foreground) return check();
        }));
      } else {
        unawaited(check());
      }
    }
  }

  void reconnected() {
    fileSync?.invalidate();
    _generation++;
    _scope = null;
    _autoDay = null;
    reports = [];
    choiceMessage = null;
    _choiceRefreshDue = false;
    _choiceTimer?.cancel();
    if (!_disposed) notifyListeners();
    if (_foreground) {
      final pending = _pending;
      if (pending != null) {
        unawaited(pending.then((_) {
          if (!_disposed && _foreground) return checkIfDue();
        }));
      } else {
        unawaited(checkIfDue());
      }
    }
  }

  Future<void> check() {
    if (_disposed) return Future.value();
    if (_pending != null && _pendingAutomatic) {
      return _pending!.then((_) => check());
    }
    return _pending ??= _check(force: true).whenComplete(() => _pending = null);
  }

  Future<void> checkIfDue() {
    if (_disposed) return Future.value();
    if (_pending != null) return _pending!;
    _pendingAutomatic = true;
    return _pending = _check(force: false).whenComplete(() {
      _pending = null;
      _pendingAutomatic = false;
    });
  }

  String get _today => _now().toIso8601String().substring(0, 10);

  Future<void> _check({required bool force}) async {
    final generation = _generation;
    final endpoint = api.baseUrl;
    final token = api.pairingToken;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        endpoint == api.baseUrl &&
        token == api.pairingToken;
    checking = true;
    notifyListeners();
    try {
      if (!android) {
        final prefs = await SharedPreferences.getInstance();
        if (!current()) return;
        final cached = prefs.getString('cna_note_check_windows');
        if (_scope != endpoint) {
          _scope = endpoint;
          reports = [];
          _autoDay = null;
          if (cached != null) {
            try {
              final value = jsonDecode(cached) as Map;
              if (value['scope'] == endpoint) {
                final previous = (value['reports'] as List)
                    .map((r) => (r as Map).cast<String, dynamic>())
                    .toList();
                for (final report in previous) {
                  validateReport(report);
                }
                reports = previous;
                _autoDay = value['day'] as String?;
              }
            } on Object {/* Invalid cache cannot suppress a daily check. */}
          }
        }
        if (!force && _autoDay == _today && !_choiceRefreshDue) return;
        error = null;
        final response = await api.getNoteChecks();
        if (!response.ok) throw StateError(response.error ?? '电脑检查失败');
        final values = response.data ?? [];
        for (final value in values) {
          validateReport(value);
        }
        if (current()) {
          reports = values;
          if (_choiceRefreshDue) {
            _choiceRefreshDue = false;
            localRevision.value++;
          }
          _autoDay = _today;
          await prefs.setString(
              'cna_note_check_windows',
              jsonEncode(
                  {'scope': endpoint, 'day': _autoDay, 'reports': reports}));
        }
        return;
      }
      final folder = await _folderInfo();
      if (!current()) return;
      needsFolder = folder == null;
      if (folder == null) {
        reports = [];
        error = null;
        return;
      }
      final identity = folder['identity'] as String;
      folderLabel = folder['label'] as String;
      // A new paired computer can reuse the same LAN IP. Persist only a digest.
      final credential = await LocalNotesBridge.identityHash(token ?? '');
      if (!current()) return;
      final scope = '$endpoint|$credential|$identity';
      if (_scope != scope) {
        reports = [];
        _autoDay = null;
        _scope = scope;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!current()) return;
      if (reports.isEmpty) {
        final cached = prefs.getString(_cacheKey);
        if (cached != null) {
          try {
            final value = jsonDecode(cached) as Map;
            if (value['scope'] == scope) {
              final report = (value['report'] as Map).cast<String, dynamic>();
              validateReport(report);
              reports = [report];
              _autoDay = value['day'] as String?;
            }
          } on Object {
            /* Invalid cache is never treated as a successful check. */
          }
        }
      }
      if (!force && _autoDay == _today) return;
      error = null;
      final local = await _readLocal();
      if (!current()) return;
      final items = validatedItems(local);
      final signature = jsonEncode(items);
      localNotes = local;
      if (_localSignature != signature) {
        _localSignature = signature;
        localRevision.value++;
      }
      final id = await deviceId();
      if (!current()) return;
      final response = await api.recordNoteCheck({
        'device_id': id,
        'folder_label': folderLabel,
        'folder_id': await LocalNotesBridge.identityHash(identity),
        'items': items,
      });
      if (!response.ok) throw StateError(response.error ?? '电脑暂时无法连接');
      final report = response.data!;
      validateReport(report);
      if (!current()) return;
      reports = [report];
      _autoDay = _today;
      await prefs.setString(_cacheKey,
          jsonEncode({'scope': scope, 'day': _autoDay, 'report': report}));
    } catch (exception) {
      if (current()) {
        error = exception.toString().replaceFirst('Bad state: ', '');
      }
    } finally {
      if (!_disposed) {
        checking = false;
        notifyListeners();
        _watchChoices();
      }
    }
  }

  static List<Map<String, String>> validatedItems(
      List<Map<String, dynamic>> local) {
    final paths = <String>{};
    final items = <Map<String, String>>[];
    for (final item in local) {
      final path = item['relative_path'];
      final hash = item['sha256'];
      if (path is! String ||
          path.isEmpty ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('手机笔记摘要不完整，请重新检查');
      }
      final normalized = path.replaceAll('\\', '/');
      if (normalized.contains(':') ||
          normalized.contains('\u0000') ||
          normalized
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..') ||
          !normalized.toLowerCase().endsWith('.md') ||
          !paths.add(normalized)) {
        throw const FormatException('手机笔记路径异常或重复，请检查所选目录');
      }
      items.add({'path': normalized, 'sha256': hash});
    }
    items.sort((a, b) => a['path']!.compareTo(b['path']!));
    return items;
  }

  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString('cna_note_check_device');
    if (previous != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(previous)) {
      return previous;
    }
    final random = Random.secure();
    final id = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    if (!await prefs.setString('cna_note_check_device', id)) {
      throw StateError('无法保存手机身份');
    }
    return id;
  }

  Future<void> chooseVersion(
          Map<String, dynamic> report, String path, String source) =>
      _choose(report, [path], source);

  Future<void> chooseAll(Map<String, dynamic> report, String source) => _choose(
      report,
      [
        for (final e in (report['versions'] as Map).entries)
          if ((e.value as Map)['${source}_hash'] != null &&
              !(report['choices'] as List? ?? [])
                  .any((c) => c['path'] == e.key && c['status'] == 'pending'))
            '${e.key}'
      ],
      source);

  Future<void> _choose(
      Map<String, dynamic> report, List<String> paths, String source) async {
    if (choosing || checking || _disposed || paths.isEmpty) return;
    final generation = _generation,
        endpoint = api.baseUrl,
        token = api.pairingToken;
    int accepted = 0;
    choosing = true;
    choiceMessage = null;
    error = null;
    notifyListeners();
    try {
      if (report['folder_id'] == null) throw StateError('请先更新手机 APP 并重新核对笔记');
      for (final path in paths) {
        final version = (report['versions'] as Map?)?[path] as Map?;
        if (version == null) throw StateError('差异已变化，请重新核对');
        final response = await api.chooseNoteVersion({
          'device_id': report['device_id'],
          'folder_id': report['folder_id'],
          'vault_id': report['vault_id'],
          'path': path,
          'source': source,
          'phone_hash': version['phone_hash'],
          'computer_hash': version['computer_hash'],
        });
        if (!response.ok) throw StateError(response.error ?? '请求未完成，请重试');
        if (_disposed ||
            generation != _generation ||
            endpoint != api.baseUrl ||
            token != api.pairingToken) return;
        report['choices'] = [
          ...(report['choices'] as List? ?? []).where((c) => c['path'] != path),
          response.data!
        ];
        accepted++;
        notifyListeners();
      }
      choiceMessage =
          '已选择${source == 'phone' ? '手机版' : '电脑版'}，等待手机连接并打开 APP 执行；成功后不保留被替换版本。';
      await check();
    } catch (e) {
      if (!_disposed &&
          generation == _generation &&
          endpoint == api.baseUrl &&
          token == api.pairingToken) {
        final failure =
            '${accepted > 0 ? '已提交 $accepted 篇，其余尚未完成：' : ''}${'$e'.replaceFirst('Bad state: ', '')}';
        if (accepted > 0) await check();
        if (!_disposed && generation == _generation) error = failure;
      }
    } finally {
      if (!_disposed) {
        choosing = false;
        notifyListeners();
        _watchChoices();
      }
    }
  }

  static void validateReport(Map<String, dynamic> value) {
    for (final name in ['only_on_phone', 'only_on_computer', 'different']) {
      if (value[name] is! List ||
          (value[name] as List).any((p) => p is! String)) {
        throw const FormatException('电脑返回了无效的笔记核对结果');
      }
    }
    if (value['same'] is! int ||
        (value['same'] as int) < 0 ||
        value['vault_id'] is! String ||
        DateTime.tryParse('${value['phone_checked_at']}') == null ||
        DateTime.tryParse('${value['computer_checked_at']}') == null) {
      throw const FormatException('笔记核对结果缺少可靠的范围或时间');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _choiceTimer?.cancel();
    fileSync?.removeListener(_syncChanged);
    fileSync?.dispose();
    if (_listening) LocalNotesBridge.changed.removeListener(scopeChanged);
    localRevision.dispose();
    super.dispose();
  }
}
