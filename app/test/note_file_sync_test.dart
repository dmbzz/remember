import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/api_result.dart';
import 'package:class_notes_assistant/data/note_file_synchronizer.dart';

// Protocol tests use stable test-only digests. Native/server tests verify real SHA256.
final digests = <String, String>{};
String hash(List<int> data) => digests.putIfAbsent(base64Encode(data),
    () => (digests.length + 1).toRadixString(16).padLeft(64, '0'));
Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

class Peer extends ApiClient {
  Peer() : super(baseUrl: 'http://computer.test', pairingToken: 'paired');
  final remote = <String, Uint8List>{};
  final records = <String, Map<String, dynamic>>{};
  Map<String, String> phone = {};
  bool offline = false, loseAck = false;
  String vault = 'a' * 64;
  String? failPath, failChoice;
  int downloads = 0, manifests = 0, applies = 0, submitted = 0;
  Completer<ApiResult<Map<String, dynamic>>>? pending;
  @override
  Future<ApiResult<Map<String, dynamic>>> getNoteFileManifest() async {
    manifests++;
    return offline
        ? const ApiResult.failed('无法连接电脑')
        : ApiResult.ok({
            'vault_id': vault,
            'items': [
              for (final e in remote.entries)
                {'path': e.key, 'sha256': hash(e.value)}
            ],
            'total': remote.length
          });
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> recordNoteCheck(
      Map<String, dynamic> snapshot) async {
    phone = {
      for (final e in snapshot['items'] as List)
        '${e['path']}': '${e['sha256']}'
    };
    return const ApiResult.ok({});
  }

  @override
  Future<ApiResult<List<Map<String, dynamic>>>> getNoteChoices(
          Map<String, String> scope) async =>
      ApiResult.ok([
        for (final r in records.values)
          if (r['vault_id'] == scope['vault_id'] &&
              r['folder_id'] == scope['folder_id'])
            Map<String, dynamic>.from(r)
      ]);
  @override
  Future<ApiResult<Map<String, dynamic>>> chooseNoteVersion(
      Map<String, dynamic> value) async {
    if (value['path'] == failChoice) return const ApiResult.failed('选择提交失败');
    final path = value['path'] as String;
    if (value['phone_hash'] != phone[path] ||
        value['computer_hash'] !=
            (remote[path] == null ? null : hash(remote[path]!)))
      return const ApiResult.failed('版本已变化');
    final old = records[path];
    if (old?['status'] == 'pending')
      return old!['source'] == value['source']
          ? ApiResult.ok(Map.from(old))
          : const ApiResult.failed('已有待执行选择');
    submitted++;
    final record = {...value, 'id': 'choice-$submitted', 'status': 'pending'};
    records[path] = record;
    return ApiResult.ok(Map.from(record));
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> getNoteFileContent(
      String path, String digest, String id) async {
    downloads++;
    if (pending != null) return await pending!.future;
    if (path == failPath) return const ApiResult.failed('传输断网');
    final data = remote[path]!;
    return ApiResult.ok({
      'path': path,
      'sha256': hash(data),
      'bytes': data.length,
      'content_base64': base64Encode(data)
    });
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> applyNoteChoice(
      String id, Map<String, dynamic> payload) async {
    final r = records.values.firstWhere((r) => r['id'] == id);
    final path = r['path'] as String;
    if (r['source'] == 'phone') {
      final data = base64Decode('${payload['content_base64']}');
      expect(hash(data), r['phone_hash']);
      remote[path] = data;
    } else {
      expect(payload['phone_hash'], r['computer_hash']);
    }
    applies++;
    r['status'] = 'completed';
    r['selected_hash'] = r['${r['source']}_hash'];
    if (loseAck) return const ApiResult.failed('确认回执丢失');
    return ApiResult.ok(Map.from(r));
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> rejectNoteChoice(
      String id, Map<String, String> scope) async {
    final r = records.values.firstWhere((r) => r['id'] == id);
    r['status'] = 'stale';
    return ApiResult.ok(Map.from(r));
  }
}

class Phone {
  final local = <String, Uint8List>{};
  int writes = 0, reads = 0, exports = 0;
  bool writable = true, refuseCleanup = false;
  String identity = 'tree:phone';
  NoteFileSynchronizer controller(Peer api, {DateTime Function()? now}) =>
      NoteFileSynchronizer(
          api: api,
          now: now,
          folderInfo: () async =>
              {'identity': identity, 'label': '课堂笔记', 'writable': writable},
          readLocal: () async {
            reads++;
            return [
              for (final e in local.entries)
                {'relative_path': e.key, 'sha256': hash(e.value)}
            ];
          },
          installSelected: (path, data, digest, expected, scope) async {
            expect(scope, identity);
            expect(expected, local[path] == null ? null : hash(local[path]!));
            expect(hash(data), digest);
            writes++;
            local[path] = data;
            if (refuseCleanup) throw StateError('旧版清理失败');
            return {'sha256': digest, 'bytes': data.length};
          },
          export: (path, digest, scope) async {
            expect(scope, identity);
            expect(hash(local[path]!), digest);
            exports++;
            return {
              'sha256': digest,
              'bytes': local[path]!.length,
              'content': local[path]!
            };
          });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('class_notes/local_notes'),
            (call) async => call.method == 'identityHash'
                ? hash(bytes((call.arguments as Map)['value'] as String))
                : null);
  });
  test('默认电脑版逐字节覆盖手机和新增笔记，不留旧版且保留手机独有', () async {
    final api = Peer()
      ..remote['a.md'] = bytes('PC')
      ..remote['new.md'] = bytes('NEW PC');
    final phone = Phone()
      ..local['a.md'] = bytes('PHONE')
      ..local['phone.md'] = bytes('ONLY PHONE');
    final sync = phone.controller(api);
    await sync.sync();
    expect(sync.error, isNull);
    expect(phone.local['a.md'], orderedEquals(api.remote['a.md']!));
    expect(phone.local['new.md'], orderedEquals(api.remote['new.md']!));
    expect(phone.local['phone.md'], orderedEquals(bytes('ONLY PHONE')));
    expect(api.remote.containsKey('phone.md'), false);
    expect(sync.backups, isEmpty);
    expect(phone.writes, 2);
    await sync.sync();
    expect(phone.writes, 2);
    api.remote['a.md'] = bytes('NEW PC VERSION');
    await sync.sync();
    expect(phone.writes, 3);
    expect(phone.local['a.md'], orderedEquals(bytes('NEW PC VERSION')));
    sync.dispose();
  });
  test('手机版选中后回传电脑，手机原字节不改，选择未保留另一版', () async {
    final api = Peer()..remote['a.md'] = bytes('电脑');
    final phone = Phone()..local['a.md'] = bytes('\uFEFF手机版\r\n公式');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    await c.chooseAll('phone');
    expect(c.error, isNull);
    expect(api.remote['a.md'], orderedEquals(phone.local['a.md']!));
    expect(c.uploaded, 1);
    expect(phone.writes, 0);
    expect(c.versions, isEmpty);
    expect(c.backups, isEmpty);
    c.dispose();
  });
  for (final source in ['phone', 'computer']) {
    test('电脑端排队选择$source可由手机执行并确认', () async {
      final api = Peer()..remote['a.md'] = bytes('PC');
      final phone = Phone()..local['a.md'] = bytes('PHONE');
      final c = phone.controller(api);
      await c.sync(checkOnly: true);
      await api.chooseNoteVersion({
        'device_id': await _device(),
        'folder_id': hash(bytes(phone.identity)),
        'vault_id': api.vault,
        'path': 'a.md',
        'source': source,
        'phone_hash': hash(phone.local['a.md']!),
        'computer_hash': hash(api.remote['a.md']!)
      });
      await c.sync();
      expect(c.error, isNull);
      expect(c.versions, isEmpty);
      expect(api.remote['a.md'], orderedEquals(phone.local['a.md']!));
      expect(api.records['a.md']!['status'], 'completed');
      c.dispose();
    });
  }
  test('任意一端在选择后改动时停止，旧确认不能覆盖新编辑', () async {
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone()..local['a.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    final previous = c.conflicts['a.md'];
    phone.local['a.md'] = bytes('PHONE NEW EDIT');
    await c.sync(adoptPath: 'a.md', expectedConflictHash: previous);
    expect(phone.writes, 0);
    expect(api.applies, 0);
    expect(c.error, contains('已变化'));
    c.dispose();
  });
  test('待执行选择遇到手机新编辑失效，不覆盖任何一端', () async {
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone()..local['a.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    await api.chooseNoteVersion({
      'folder_id': hash(bytes(phone.identity)),
      'vault_id': api.vault,
      'path': 'a.md',
      'source': 'computer',
      'phone_hash': hash(phone.local['a.md']!),
      'computer_hash': hash(api.remote['a.md']!)
    });
    phone.local['a.md'] = bytes('NEW EDIT');
    await c.sync();
    expect(api.records['a.md']!['status'], 'stale');
    expect(phone.writes, 0);
    expect(c.error, contains('停止覆盖'));
    c.dispose();
  });
  test('仅核对不写文件，批量明确选择只处理有效来源', () async {
    final api = Peer()..remote['pc.md'] = bytes('PC');
    final phone = Phone()..local['phone.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    expect(phone.local.length, 1);
    expect(api.remote.length, 1);
    await c.chooseAll('phone');
    expect(api.remote.length, 2);
    expect(phone.local.length, 1);
    await c.chooseAll('computer');
    expect(phone.local.length, 2);
    expect(c.versions, isEmpty);
    c.dispose();
  });
  test('传输失败不删除原件，恢复后完成且重复检查不重传', () async {
    final api = Peer()
      ..remote['a.md'] = bytes('PC')
      ..failPath = 'a.md';
    final phone = Phone()..local['a.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    await c.chooseAll('computer');
    expect(c.error, contains('断网'));
    expect(phone.local['a.md'], orderedEquals(bytes('PHONE')));
    expect(api.applies, 0);
    api.failPath = null;
    await c.sync();
    expect(c.error, isNull);
    expect(phone.writes, 1);
    final count = api.downloads;
    await c.sync();
    expect(api.downloads, count);
    c.dispose();
  });
  test('批量部分提交后失败保留待执行状态，下一次不重复提交已选项', () async {
    final api = Peer()
      ..remote['a.md'] = bytes('A')
      ..remote['b.md'] = bytes('B')
      ..failChoice = 'b.md';
    final phone = Phone(), c = phone.controller(api);
    await c.sync(checkOnly: true);
    await c.chooseAll('computer');
    expect(c.error, contains('已提交 1 篇'));
    expect(c.hasPending('a.md'), true);
    expect(phone.writes, 0);
    api.failChoice = null;
    await c.chooseAll('computer');
    expect(api.submitted, 2);
    expect(phone.writes, 2);
    expect(c.error, isNull);
    c.dispose();
  });
  test('确认回执丢失后不重复覆盖，旧版清理失败不能标记完成', () async {
    final api = Peer()
      ..remote['a.md'] = bytes('PC')
      ..loseAck = true;
    final phone = Phone()..local['a.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    await c.chooseAll('computer');
    expect(c.error, contains('回执丢失'));
    api.loseAck = false;
    await c.sync();
    expect(c.error, isNull);
    expect(phone.writes, 1);
    api.remote['a.md'] = bytes('SECOND PC');
    phone.refuseCleanup = true;
    await c.sync(checkOnly: true);
    await c.chooseAll('computer');
    expect(c.error, contains('旧版清理失败'));
    expect(api.records['a.md']!['status'], 'pending');
    c.dispose();
  });
  test('权限不足不传，选择执行中的并发核对合并，失效响应不能写新目录', () async {
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone()..writable = false;
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    expect(c.needsWritePermission, true);
    expect(api.downloads, 0);
    phone.writable = true;
    await c.sync(checkOnly: true);
    api.pending = Completer();
    final operation = c.chooseAll('computer');
    final merged = c.sync();
    expect(identical(operation, merged), true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    phone.identity = 'tree:new';
    c.invalidate();
    api.pending!.complete(ApiResult.ok({
      'path': 'a.md',
      'sha256': hash(bytes('PC')),
      'bytes': 2,
      'content_base64': base64Encode(bytes('PC'))
    }));
    await operation;
    expect(phone.writes, 0);
    expect(c.versions, isEmpty);
    c.dispose();
  });
  test('后台停止后网络返回不能写入，旧目录选择不套新目录', () async {
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone()..local['a.md'] = bytes('PHONE');
    final c = phone.controller(api);
    await c.sync(checkOnly: true);
    final revision = c.scopeRevision;
    api.pending = Completer();
    final operation = c.chooseAll('computer');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    c.setForeground(false);
    api.pending!.complete(ApiResult.ok({
      'path': 'a.md',
      'sha256': hash(bytes('PC')),
      'bytes': 2,
      'content_base64': base64Encode(bytes('PC'))
    }));
    await operation;
    expect(phone.writes, 0);
    await c.chooseVersion('a.md', 'computer',
        phoneHash: hash(bytes('PHONE')),
        computerHash: hash(bytes('PC')),
        revision: revision);
    expect(c.error, contains('连接或目录已变化'));
    c.dispose();
  });
  test('身份等待期间换目录不恢复旧差异或进度', () async {
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone();
    final c = phone.controller(api);
    final pending = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('class_notes/local_notes'),
            (_) async => pending.future);
    final operation = c.sync();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    phone.identity = 'new';
    c.invalidate();
    pending.complete('f' * 64);
    await operation;
    expect(c.total, 0);
    expect(c.versions, isEmpty);
    expect(phone.writes, 0);
    c.dispose();
  });
  test('每天仅自动核对一次，保留手动核对及跨日检查', () async {
    var today = DateTime(2026, 10, 19, 9);
    final api = Peer()..remote['a.md'] = bytes('PC');
    final phone = Phone();
    final c = phone.controller(api, now: () => today);
    await c.sync(automatic: true);
    final reads = phone.reads, manifests = api.manifests;
    await c.sync(automatic: true);
    expect(phone.reads, reads);
    expect(api.manifests, manifests);
    await c.sync();
    expect(phone.reads, greaterThan(reads));
    final current = phone.reads;
    today = today.add(const Duration(days: 1));
    await c.sync(automatic: true);
    expect(phone.reads, greaterThan(current));
    c.dispose();
  });
}

Future<String> _device() async =>
    (await SharedPreferences.getInstance()).getString('cna_note_check_device')!;
