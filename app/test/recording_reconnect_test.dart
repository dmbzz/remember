import 'dart:io';
import 'dart:convert';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/recording_files_page.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedAutomaticRecording extends StubRecordingBridge {
  SavedAutomaticRecording(this.file);
  final File file;
  @override
  Future<List<Map<String, dynamic>>> listRecordingFiles() async =>
      file.existsSync()
          ? [
              {
                'filePath': file.path,
                'courseId': 'mechanics',
                'classDate': '2026-10-12'
              }
            ]
          : [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('恢复失败队列开始上传时清除上一轮错误和进度', () async {
    final dir = await Directory.systemTemp.createTemp('cna-restored-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/lesson.m4a').writeAsBytes([1]);
    SharedPreferences.setMockInitialValues({
      'class_notes_upload_queue': jsonEncode([
        UploadItem(
                id: 'old',
                filePath: file.path,
                courseId: 'mechanics',
                lesson: 1,
                classDate: '2026-10-12',
                status: UploadStatus.failed,
                progress: 84,
                error: '上一次连接超时')
            .toJson()
      ])
    });
    final api = ApiClient(baseUrl: 'http://computer.local');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.reject(DioException(
          requestOptions: request, type: DioExceptionType.connectionError));
    }));
    final queue = UploadQueue(apiClient: api);
    addTearDown(queue.dispose);
    final state = await queue.queueStream
        .map((items) => items.isNotEmpty
            ? [items.single.status, items.single.error, items.single.progress]
            : [])
        .firstWhere(
            (state) => state.isNotEmpty && state[0] == UploadStatus.uploading)
        .timeout(const Duration(seconds: 5));
    expect(state, [UploadStatus.uploading, null, 0]);
    // Let the mocked attempt finish before closing its Dio.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(file.existsSync(), true);
    api.dio.close();
  });
  for (final useTimer in [false, true]) {
    test('自动录音离线上传失败后，${useTimer ? '连接恢复定时重试' : '回到应用扫描重试'}直到电脑确认才删手机文件',
        () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('cna-reconnect-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(
          '${dir.path}/rec_rec_auto_mechanics_1791804600000_20261012_193000.m4a');
      await file.writeAsBytes([1, 2, 3, 4]);
      final api = ApiClient(baseUrl: 'http://computer.local');
      var online = false;
      var uploaded = false;
      var sends = 0;
      api.dio.interceptors
          .add(InterceptorsWrapper(onRequest: (request, handler) {
        if (!online) {
          handler.reject(DioException(
              requestOptions: request, type: DioExceptionType.connectionError));
          return;
        }
        Object data;
        if (request.path == '/api/pairing/check') {
          data = {'paired': true};
        } else if (request.path == '/api/recordings') {
          data = {'id': 'test-reconnected'};
        } else if (request.path.endsWith('/upload-file')) {
          sends++;
          uploaded = true;
          data = {
            'upload_status': 'uploaded',
            'size_bytes': 4,
            'file_path': 'D:/recordings/test.m4a'
          };
        } else {
          data = {
            'upload_status': uploaded ? 'uploaded' : 'pending',
            'size_bytes': uploaded ? 4 : 0,
            'file_path': uploaded ? 'D:/recordings/test.m4a' : null
          };
        }
        handler.resolve(Response(
            requestOptions: request,
            statusCode: 200,
            data: {'code': 0, 'data': data, 'message': 'ok'}));
      }));
      final queue = UploadQueue(
          apiClient: api, retryDelay: const Duration(milliseconds: 100));
      addTearDown(queue.dispose);
      final bridge = SavedAutomaticRecording(file);
      final failed = queue.queueStream.firstWhere((items) =>
          items.isNotEmpty && items.single.status == UploadStatus.failed);
      await queue.recoverLocalRecordings(bridge);
      await failed.timeout(const Duration(seconds: 5));
      expect(file.existsSync(), true);
      final completed = queue.queueStream
          .firstWhere((items) => items.single.status == UploadStatus.completed);
      online = true;
      if (!useTimer) await queue.reconnect(bridge);
      await completed.timeout(const Duration(seconds: 5));
      expect(sends, 1);
      expect(queue.items.length, 1);
      expect(queue.items.single.courseId, 'mechanics');
      expect(file.existsSync(), false);
      api.dio.close();
    });
  }
  testWidgets('电脑显示服务器收到的录音，不把本机空队列当成手机未同步', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(baseUrl: 'http://computer.local');
    api.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: {
              'code': 0,
              'data': request.path == '/api/recordings'
                  ? [
                      {
                        'id': 'received',
                        'course_id': 'mechanics',
                        'upload_status': 'uploaded',
                        'size_bytes': 4194304,
                        'file_path': 'D:/录音/received.m4a'
                      }
                    ]
                  : [
                      {'id': 'mechanics', 'name': '工程力学'}
                    ],
              'message': 'ok'
            }))));
    final queue = UploadQueue(apiClient: api);
    addTearDown(queue.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RecordingFilesPage(uploadQueue: queue, apiClient: api)));
    await tester.pumpAndSettle();
    expect(find.text('工程力学'), findsOneWidget);
    expect(find.textContaining('已保存到电脑 · 4.0 MB'), findsOneWidget);
    expect(queue.items, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.dio.close();
  });
}
