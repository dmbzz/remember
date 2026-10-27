import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'note_check_controller.dart';
import '../platform/local_notes_bridge.dart';

typedef NoteInstaller = Future<Map<String, dynamic>> Function(
    String, Uint8List, String, String?, String);

/// One daily file check, manual sync, and lightweight polling of explicit choices.
class NoteFileSynchronizer extends ChangeNotifier {
  NoteFileSynchronizer({
    required this.api,
    this.onUpdated,
    Future<Map<String, dynamic>?> Function()? folderInfo,
    Future<List<Map<String, dynamic>>> Function()? readLocal,
    NoteInstaller? install,
    NoteInstaller? installSelected,
    Future<Map<String, dynamic>> Function(String, String, String)? export,
    DateTime Function()? now,
  })  : folderInfo = folderInfo ?? LocalNotesBridge.folderInfo,
        readLocal = readLocal ?? LocalNotesBridge.list,
        install = install ?? LocalNotesBridge.install,
        installSelected = installSelected ?? LocalNotesBridge.installSelected,
        export = export ?? LocalNotesBridge.export,
        now = now ?? DateTime.now;
  final ApiClient api;
  final VoidCallback? onUpdated;
  final Future<Map<String, dynamic>?> Function() folderInfo;
  final Future<List<Map<String, dynamic>>> Function() readLocal;
  final NoteInstaller install, installSelected;
  final Future<Map<String, dynamic>> Function(String, String, String) export;
  final DateTime Function() now;
  bool syncing = false, needsFolder = false, needsWritePermission = false;
  String? error, activePath;
  DateTime? lastCompleted;
  int downloaded = 0, uploaded = 0, unchanged = 0, total = 0, processed = 0;
  List<String> phoneOnly = [];
  Map<String, String> conflicts = {};
  Map<String, Map<String, String?>> versions = {};
  List<Map<String, dynamic>> choices = [];
  // Kept for compatibility with old clients/views; explicit choices create no backups.
  List<Map<String, String>> backups = [];
  Timer? _timer;
  bool _disposed = false, _foreground = false;
  bool _pollFailed = false;
  int _generation = 0;
  Future<void>? _pending;
  Map<String, String>? _lastScope;
  String? _lastEndpoint, _lastToken;
  String get _today => now().toIso8601String().substring(0, 10);

  void setForeground(bool active) {
    _foreground = active;
    _timer?.cancel();
    _timer = null;
    if (!active) _generation++;
    if (active && !_disposed) {
      unawaited((_pending ?? Future<void>.value()).then((_) {
        if (!_disposed && _foreground) return sync(automatic: true);
      }));
      _timer =
          Timer.periodic(const Duration(seconds: 15), (_) => _pollChoices());
    }
  }

  Future<void> _pollChoices() async {
    final scope = _lastScope, generation = _generation;
    if (_disposed ||
        !_foreground ||
        _pending != null ||
        scope == null ||
        _lastEndpoint != api.baseUrl ||
        _lastToken != api.pairingToken) return;
    final response = await api.getNoteChoices(scope);
    if (_disposed || generation != _generation || !_foreground) return;
    if (!response.ok) {
      if (response.error?.contains('电脑笔记目录已变化') == true) {
        await sync(automatic: true);
        return;
      }
      error = response.error;
      _pollFailed = true;
      notifyListeners();
      return;
    }
    if (_pollFailed) {
      error = null;
      _pollFailed = false;
    }
    choices = response.data!;
    notifyListeners();
    if (choices.any((c) => c['status'] == 'pending')) await sync();
  }

  void invalidate() {
    _generation++;
    _lastScope = null;
    conflicts = {};
    versions = {};
    phoneOnly = [];
    choices = [];
    backups = [];
    lastCompleted = null;
    error = null;
    activePath = null;
    downloaded = uploaded = unchanged = total = processed = 0;
    if (!_disposed) notifyListeners();
    if (_foreground && !_disposed) {
      unawaited((_pending ?? Future<void>.value()).then((_) {
        if (!_disposed && _foreground) return sync(automatic: true);
      }));
    }
  }

  int get scopeRevision => _generation;
  bool hasPending(String path) =>
      choices.any((c) => c['path'] == path && c['status'] == 'pending');
  bool canChooseAll(String source) => versions.entries
      .any((e) => !hasPending(e.key) && e.value['${source}_hash'] != null);
  Future<void> chooseVersion(String path, String source,
          {required String? phoneHash,
          required String? computerHash,
          required int revision}) =>
      _request({
        'path': path,
        'source': source,
        'phone_hash': phoneHash,
        'computer_hash': computerHash
      }, revision, false);

  Future<void> chooseAll(String source) => _request({
        'batch': [
          for (final e in versions.entries)
            if (!hasPending(e.key) && e.value['${source}_hash'] != null)
              {
                'path': e.key,
                'source': source,
                'phone_hash': e.value['phone_hash'],
                'computer_hash': e.value['computer_hash']
              },
        ]
      }, _generation, false);

  Future<void> sync(
          {String? adoptPath,
          String? expectedConflictHash,
          int? expectedRevision,
          bool checkOnly = false,
          bool automatic = false}) =>
      _request(
          adoptPath == null
              ? null
              : {
                  'path': adoptPath,
                  'source': 'computer',
                  'phone_hash': expectedConflictHash,
                  'computer_hash': versions[adoptPath]?['computer_hash']
                },
          expectedRevision ?? _generation,
          automatic,
          checkOnly: checkOnly);

  Future<void> _request(
      Map<String, dynamic>? choice, int revision, bool automatic,
      {bool checkOnly = false}) {
    if (_disposed) return Future.value();
    if (choice != null && revision != _generation) {
      error = '连接或目录已变化，请重新查看差异后选择';
      notifyListeners();
      return Future.value();
    }
    if (_pending != null) {
      return choice == null
          ? _pending!
          : _pending!.then((_) => _request(choice, revision, false));
    }
    return _pending = _sync(choice, automatic, checkOnly: checkOnly)
        .whenComplete(() => _pending = null);
  }

  void _differences(Map<String, String> local, Map<String, String> remote) {
    phoneOnly = local.keys.where((p) => !remote.containsKey(p)).toList()
      ..sort();
    conflicts = {
      for (final p in local.keys)
        if (remote.containsKey(p) && remote[p] != local[p]) p: local[p]!
    };
    versions = {
      for (final p in {...local.keys, ...remote.keys})
        if (local[p] != remote[p])
          p: {'phone_hash': local[p], 'computer_hash': remote[p]}
    };
  }

  Future<void> _sync(Map<String, dynamic>? choice, bool automatic,
      {bool checkOnly = false}) async {
    final generation = _generation,
        endpoint = api.baseUrl,
        token = api.pairingToken;
    int accepted = 0;
    bool checkedFiles = false;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        endpoint == api.baseUrl &&
        token == api.pairingToken;
    syncing = true;
    error = null;
    downloaded = uploaded = unchanged = processed = total = 0;
    notifyListeners();
    try {
      final folder = await folderInfo();
      if (!current()) return;
      needsFolder = folder == null;
      needsWritePermission = folder != null && folder['writable'] != true;
      if (folder == null) return;
      if (needsWritePermission) throw StateError('请重新选择手机目录，授予笔记同步读写权限');
      final identity = folder['identity'];
      if (identity is! String || identity.isEmpty) {
        throw const FormatException('手机目录身份无效');
      }
      final scopeKey = await LocalNotesBridge.identityHash(
          '$endpoint|${token ?? ''}|$identity');
      final folderId = await LocalNotesBridge.identityHash(identity);
      final device = await NoteCheckController.deviceId();
      final prefs = await SharedPreferences.getInstance();
      final dayKey = 'cna_note_sync_day_$scopeKey',
          cachedScopeKey = 'cna_note_choice_scope_$scopeKey';
      if (!current()) return;
      if (automatic &&
          prefs.getString(dayKey) == _today &&
          prefs.getString(cachedScopeKey) != null) {
        final savedScope = (jsonDecode(prefs.getString(cachedScopeKey)!) as Map)
            .cast<String, String>();
        if (savedScope['folder_id'] == folderId &&
            savedScope['device_id'] == device) {
          final pending = await api.getNoteChoices(savedScope);
          if (!current()) return;
          if (pending.ok) {
            _lastScope = savedScope;
            _lastEndpoint = endpoint;
            _lastToken = token;
            choices = pending.data!;
            if (!choices.any((c) => c['status'] == 'pending')) return;
          }
        }
      }
      final manifest = await api.getNoteFileManifest();
      if (!manifest.ok) throw StateError(manifest.error ?? '请求未完成，请重试');
      if (!current()) return;
      final data = manifest.data!, vault = data['vault_id'];
      if (vault is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(vault) ||
          data['items'] is! List) throw const FormatException('电脑清单无效');
      final items = NoteCheckController.validatedItems((data['items'] as List)
          .map((i) =>
              {'relative_path': (i as Map)['path'], 'sha256': i['sha256']})
          .toList());
      if (items.length > 5000 ||
          data['total'] != items.length ||
          items.map((e) => e['path']!.toLowerCase()).toSet().length !=
              items.length) throw const FormatException('电脑清单不完整或有大小写重名路径');
      var local = {
        for (final i in NoteCheckController.validatedItems(await readLocal()))
          i['path']!: i['sha256']!
      };
      final remote = {for (final i in items) i['path']!: i['sha256']!};
      if (!current()) return;
      checkedFiles = true;
      final scope = {
        'device_id': device,
        'folder_id': folderId,
        'vault_id': vault
      };
      _lastScope = scope;
      _lastEndpoint = endpoint;
      _lastToken = token;
      _differences(local, remote);
      Future<void> report(Map<String, String> values) async {
        final result = await api.recordNoteCheck({
          'device_id': device,
          'folder_id': folderId,
          'folder_label': '${folder['label'] ?? '课堂笔记'}',
          'items': [
            for (final e in values.entries) {'path': e.key, 'sha256': e.value}
          ]
        });
        if (!result.ok) throw StateError(result.error ?? '请求未完成，请重试');
      }

      await report(local);
      if (!current()) return;
      if (choice != null) {
        final requested = choice['batch'] is List
            ? (choice['batch'] as List).cast<Map<String, dynamic>>()
            : [choice];
        for (final entry in requested) {
          final path = entry['path'] as String;
          activePath = path;
          if (local[path] != entry['phone_hash'] ||
              remote[path] != entry['computer_hash']) {
            throw StateError('选择后的笔记已变化，请重新核对后选择');
          }
          final selected = await api.chooseNoteVersion({...scope, ...entry});
          if (!selected.ok) throw StateError(selected.error ?? '请求未完成，请重试');
          if (!current()) return;
          choices = [
            ...choices.where((c) => c['path'] != path),
            selected.data!
          ];
          accepted++;
          notifyListeners();
        }
      }
      final pending = await api.getNoteChoices(scope);
      if (!pending.ok) throw StateError(pending.error ?? '请求未完成，请重试');
      if (!current()) return;
      choices = pending.data!;
      // Existing explicit decisions take precedence over the default direction.
      if (choice == null && !checkOnly) {
        for (final entry in versions.entries) {
          if (entry.value['computer_hash'] == null || hasPending(entry.key)) {
            continue;
          }
          activePath = entry.key;
          final selected = await api.chooseNoteVersion({
            ...scope,
            'path': entry.key,
            'source': 'computer',
            'phone_hash': entry.value['phone_hash'],
            'computer_hash': entry.value['computer_hash'],
          });
          if (!selected.ok) throw StateError(selected.error ?? '默认电脑版本选择失败');
          if (!current()) return;
          choices = [
            ...choices.where((c) => c['path'] != entry.key),
            selected.data!
          ];
        }
      }
      total =
          remote.length + choices.where((c) => c['status'] == 'pending').length;
      for (final selected
          in choices.where((c) => !checkOnly && c['status'] == 'pending')) {
        if (!current()) return;
        final path = selected['path'] as String;
        activePath = path;
        notifyListeners();
        final chosen = selected['source'] == 'phone'
            ? selected['phone_hash']
            : selected['computer_hash'];
        final phoneMatches = local[path] == selected['phone_hash'] ||
            (selected['source'] == 'computer' && local[path] == chosen);
        final pcMatches = remote[path] == selected['computer_hash'] ||
            (selected['source'] == 'phone' && remote[path] == chosen);
        if (!phoneMatches || !pcMatches) {
          await api.rejectNoteChoice('${selected['id']}', scope);
          throw StateError('选择后两端笔记发生变化，已停止覆盖，请重新选择');
        }
        Map<String, dynamic> payload = {...scope, 'phone_hash': chosen};
        if (selected['source'] == 'phone') {
          final exported = await export(path, chosen as String, identity);
          if (!current()) return;
          final bytes = exported['content'];
          if (bytes is! Uint8List ||
              bytes.length > 10 * 1024 * 1024 ||
              exported['sha256'] != chosen ||
              exported['bytes'] != bytes.length) {
            throw const FormatException('手机笔记导出不完整，电脑原文件未修改');
          }
          payload['content_base64'] = base64Encode(bytes);
        } else if (local[path] != chosen) {
          final bytes = await _download(path, chosen as String, vault);
          if (!current()) return;
          final receipt =
              await installSelected(path, bytes, chosen, local[path], identity);
          if (receipt['sha256'] != chosen ||
              receipt['bytes'] != bytes.length ||
              receipt['backup_path'] != null) {
            throw const FormatException('手机未确认完成覆盖和旧版清理');
          }
          if (!current()) return;
          local[path] = chosen;
          downloaded++;
        }
        final applied = await api.applyNoteChoice('${selected['id']}', payload);
        if (!applied.ok) throw StateError(applied.error ?? '请求未完成，请重试');
        if (!current()) return;
        if (applied.data?['status'] != 'completed' ||
            applied.data?['selected_hash'] != chosen) {
          throw const FormatException('电脑未确认同步成功');
        }
        if (selected['source'] == 'phone') {
          uploaded++;
          remote[path] = chosen as String;
        }
        processed++;
        notifyListeners();
      }
      // Phone-only notes remain local; absence on the computer is never deletion.
      total = remote.length + processed;
      for (final entry in remote.entries) {
        if (!current()) return;
        activePath = entry.key;
        if (local[entry.key] == entry.value) {
          unchanged++;
        }
        processed++;
        notifyListeners();
      }
      // Fresh inventories after writes; never claim equality from a pre-write scan.
      local = {
        for (final i in NoteCheckController.validatedItems(await readLocal()))
          i['path']!: i['sha256']!
      };
      if (!current()) return;
      final fresh = await api.getNoteFileManifest();
      if (!fresh.ok) throw StateError(fresh.error ?? '请求未完成，请重试');
      if (!current()) return;
      if (fresh.data?['vault_id'] != vault) throw StateError('电脑笔记库已变化，请重新核对');
      final verified = NoteCheckController.validatedItems(
          (fresh.data!['items'] as List)
              .map((i) =>
                  {'relative_path': (i as Map)['path'], 'sha256': i['sha256']})
              .toList());
      if (verified.length > 5000 ||
          fresh.data!['total'] != verified.length ||
          verified.map((i) => i['path']!.toLowerCase()).toSet().length !=
              verified.length) throw const FormatException('同步后的电脑清单不完整');
      final finalRemote = {for (final i in verified) i['path']!: i['sha256']!};
      _differences(local, finalRemote);
      await report(local);
      if (!current()) return;
      final finalChoices = await api.getNoteChoices(scope);
      if (!finalChoices.ok) throw StateError(finalChoices.error ?? '请求未完成，请重试');
      if (!current()) return;
      choices = finalChoices.data!;
      lastCompleted = now();
      if (!checkOnly) await prefs.setString(dayKey, _today);
      await prefs.setString(cachedScopeKey, jsonEncode(scope));
    } catch (e) {
      if (current()) {
        error =
            '${accepted > 0 && choice?['batch'] != null ? '已提交 $accepted 篇，其余尚未完成：' : ''}${activePath == null ? '' : '${activePath!}：'}${e.toString().replaceFirst('Bad state: ', '')}';
      }
    } finally {
      if (!_disposed) {
        syncing = false;
        activePath = null;
        notifyListeners();
        if (current() && checkedFiles) onUpdated?.call();
      }
    }
  }

  Future<Uint8List> _download(String path, String hash, String vault) async {
    final response = await api.getNoteFileContent(path, hash, vault);
    if (!response.ok) throw StateError(response.error ?? '请求未完成，请重试');
    final payload = response.data!, encoded = payload['content_base64'];
    if (payload['path'] != path ||
        payload['sha256'] != hash ||
        encoded is! String ||
        encoded.length > 14 * 1024 * 1024) {
      throw const FormatException('电脑笔记响应不完整，原文件未修改');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length > 10 * 1024 * 1024 || bytes.length != payload['bytes']) {
      throw const FormatException('笔记传输长度不匹配');
    }
    return bytes;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}

