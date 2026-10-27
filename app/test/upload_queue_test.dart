import 'dart:io';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final uploadSucceeds in [true, false]) {
    test(
        '电脑${uploadSucceeds ? '确认完整保存后' : '上传失败时'}手机文件${uploadSucceeds ? '删除' : '保留'}',
        () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('cna_upload_test_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/lesson.m4a');
      await file.writeAsBytes([1, 2, 3, 4]);
      final api = ApiClient(baseUrl: 'http://test.local');
      var uploaded = false;
      api.dio.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) {
        final path = options.path;
        if (path == '/api/recordings') {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'code': 0,
            'data': {'id': 'rec_test'},
            'message': 'ok'
          }));
        } else if (path == '/api/recordings/rec_test/upload-file') {
          if (!uploadSucceeds) {
            handler.reject(DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 500),
                type: DioExceptionType.badResponse));
          } else {
            uploaded = true;
            handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: {
              'code': 0,
              'data': {
                'upload_status': 'uploaded',
                'size_bytes': 4,
                'file_path': 'C:/recordings/rec_test.m4a'
              },
              'message': 'ok'
            }));
          }
        } else if (path == '/api/recordings/rec_test') {
          handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
            'code': 0,
            'data': {
              'upload_status': uploaded ? 'uploaded' : 'pending',
              'size_bytes': uploaded ? 4 : 0,
              'file_path': uploaded ? 'C:/recordings/rec_test.m4a' : null
            },
            'message': 'ok'
          }));
        } else {
          handler.reject(DioException(
              requestOptions: options, type: DioExceptionType.badResponse));
        }
      }));
      final queue = UploadQueue(apiClient: api);
      addTearDown(queue.dispose);
      final completed = queue.queueStream.firstWhere((items) =>
          items.isNotEmpty &&
          (items.last.status == UploadStatus.completed ||
              items.last.status == UploadStatus.failed));
      queue.enqueue(
          filePath: file.path,
          courseId: 'course_test',
          lesson: 1,
          classDate: '2026-10-10');
      final items = await completed.timeout(const Duration(seconds: 5));
      expect(items.last.status,
          uploadSucceeds ? UploadStatus.completed : UploadStatus.failed);
      expect(await file.exists(), !uploadSucceeds);
      api.dio.close();
    });
  }
}
