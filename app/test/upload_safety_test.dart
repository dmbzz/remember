import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Fixture {
  late Directory dir;
  late File phone;
  late ApiClient api;
  late UploadQueue queue;
  String server = 'aaaaaaaaaaaaaaaa';
  bool audio = false,
      failUpload = false,
      oldServer = false,
      missingRecord = false;
  String? wrongReceipt;
  bool mutatePhone = false, switchOnConfirmation = false;
  int uploads = 0, receipts = 0, creates = 0;
  Map? registered;
  final requests = <String>[];
  final digest = sha256.convert([1, 2, 3, 4]).toString();

  Future<void> init({String? bound, String? record}) async {
    dir = await Directory.systemTemp.createTemp('remember-safe-upload-');
    phone = await File('${dir.path}/lesson.m4a').writeAsBytes([1, 2, 3, 4]);
    SharedPreferences.setMockInitialValues({
      'class_notes_upload_queue': jsonEncode([
        UploadItem(
                id: 'one',
                filePath: phone.path,
                courseId: 'course1',
                lesson: 1,
                classDate: '2026-10-31',
                durationMs: 90500,
                serverId: bound,
                recordingId: record)
            .toJson()
      ])
    });
    api = ApiClient(baseUrl: 'http://pc.invalid');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      requests.add(o.path);
      void reply(Map data) => h.resolve(Response(
          requestOptions: o, statusCode: 200, data: {'code': 0, 'data': data}));
      void fail(int code) => h.reject(DioException(
          requestOptions: o,
          response: Response(requestOptions: o, statusCode: code),
          type: DioExceptionType.badResponse));
      if (o.path == '/api/pairing/check') {
        reply({'server_id': server});
        return;
      }
      if (o.path.startsWith('/api/courses/')) {
        reply({'id': 'course1'});
        return;
      }
      if (o.path == '/api/recordings') {
        creates++;
        registered = o.data as Map;
        reply({'id': 'rec1'});
        return;
      }
      if (o.path.endsWith('/receipt')) {
        if (oldServer) {
          fail(404);
          return;
        }
        receipts++;
        if (receipts == 2 && mutatePhone)
          await phone.writeAsBytes([4, 3, 2, 1]);
        if (receipts == 2 && switchOnConfirmation)
          api.updateBaseUrl('http://different.invalid');
        reply({
          'recording_id': 'rec1',
          'server_id': server,
          'sha256': wrongReceipt ?? digest,
          'size_bytes': 4,
          'verified': audio
        });
        return;
      }
      if (o.path.endsWith('/upload-file')) {
        uploads++;
        if (failUpload) {
          fail(500);
          return;
        }
        audio = true;
        reply({
          'upload_status': 'uploaded',
          'size_bytes': 4,
          'file_path': 'pc/test.m4a'
        });
        return;
      }
      if (missingRecord) {
        fail(404);
        return;
      }
      // Historical receipt always looks successful, even when audio is missing.
      reply({
        'id': 'rec1',
        'upload_status': 'uploaded',
        'size_bytes': 4,
        'file_path': 'missing/file.m4a'
      });
    }));
    queue = UploadQueue(apiClient: api, retryDelay: const Duration(minutes: 1));
  }

  Future<UploadItem> settled() async => (await queue.queueStream
          .firstWhere((items) =>
              items.isNotEmpty &&
              (items.first.status == UploadStatus.failed ||
                  items.first.status == UploadStatus.completed))
          .timeout(const Duration(seconds: 5)))
      .first;
  Future<void> close() async {
    queue.dispose();
    api.dio.close(force: true);
    await dir.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('missing PC audio is reuploaded before phone cleanup', () async {
    final f = Fixture();
    await f.init(record: 'rec1');
    addTearDown(f.close);
    final item = await f.settled();
    expect(item.status, UploadStatus.completed);
    expect(f.uploads, 1);
    expect(await f.phone.exists(), false);
    expect(item.serverId, 'aaaaaaaaaaaaaaaa');
  });
  test('missing audio and failed reupload preserve phone', () async {
    final f = Fixture()..failUpload = true;
    await f.init(record: 'rec1');
    addTearDown(f.close);
    expect((await f.settled()).status, UploadStatus.failed);
    expect(await f.phone.exists(), true);
  });
  test('fresh registration includes duration and computer identity', () async {
    final f = Fixture();
    await f.init();
    addTearDown(f.close);
    expect((await f.settled()).status, UploadStatus.completed);
    expect(f.registered!['duration_ms'], 90500);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('class_notes_upload_queue'),
        contains('aaaaaaaaaaaaaaaa'));
  });
  for (final kind in [
    'hash',
    'old_server',
    'phone_changed',
    'connection_changed'
  ]) {
    test('$kind cannot authorize deletion', () async {
      final f = Fixture();
      if (kind == 'hash') f.wrongReceipt = '0' * 64;
      if (kind == 'old_server') f.oldServer = true;
      if (kind == 'phone_changed') f.mutatePhone = true;
      if (kind == 'connection_changed') f.switchOnConfirmation = true;
      await f.init(record: 'rec1');
      addTearDown(f.close);
      expect((await f.settled()).status, UploadStatus.failed);
      expect(await f.phone.exists(), true);
    });
  }
  test(
      'another PC is blocked until explicit course assignment resets scoped IDs',
      () async {
    final f = Fixture();
    await f.init(bound: 'bbbbbbbbbbbbbbbb', record: 'old_rec');
    addTearDown(f.close);
    final blocked = await f.settled();
    expect(blocked.status, UploadStatus.failed);
    expect(blocked.error, contains('另一台电脑'));
    expect(f.requests.any((p) => p.contains('old_rec')), false);
    expect(f.uploads, 0);
    final done = f.settled();
    f.queue.assignCourse(blocked.id, 'course1');
    expect((await done).status, UploadStatus.completed);
    expect(f.creates, 1);
    expect(f.queue.items.single.serverId, 'aaaaaaaaaaaaaaaa');
  });
  test('lost recording ID can be recovered through explicit course selection',
      () async {
    final f = Fixture()..missingRecord = true;
    await f.init(bound: 'aaaaaaaaaaaaaaaa', record: 'old_rec');
    addTearDown(f.close);
    final blocked = await f.settled();
    expect(blocked.error, contains('指定课程'));
    f.missingRecord = false;
    final done = f.settled();
    f.queue.assignCourse(blocked.id, 'course1');
    expect((await done).status, UploadStatus.completed);
    expect(f.creates, 1);
  });
  test('same computer address change does not discard recording identity',
      () async {
    final f = Fixture()..audio = true;
    await f.init(bound: 'aaaaaaaaaaaaaaaa', record: 'rec1');
    addTearDown(f.close);
    expect((await f.settled()).status, UploadStatus.completed);
    expect(f.creates, 0);
    expect(f.uploads, 0);
  });
}
