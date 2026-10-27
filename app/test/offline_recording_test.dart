import 'dart:convert';
import 'dart:io';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/course_store.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/auto_recording_schedule.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/platform/recording_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> snapshot() => {
      'version': 1,
      'semester_start': '2026-08-31',
      'updated_at': 1791540000000,
      'term_label': '大二上',
      'entries': [
        {
          'course_id': 'mechanics',
          'course_name': '工程力学',
          'weekday': 1,
          'start_time': '08:15',
          'end_time': '09:50',
          'weeks': [7, 12, 19],
          'auto_record': true,
          'location': '教学楼4-402',
          'confirmed': true
        },
        {
          'course_id': 'math',
          'course_name': '线性代数',
          'weekday': 3,
          'start_time': '10:05',
          'end_time': '11:40',
          'weeks': [7],
          'auto_record': false,
          'confirmed': true
        },
      ],
    };

ApiClient disconnected() {
  final api = ApiClient(baseUrl: 'http://computer-offline.local');
  api.dio.interceptors.add(InterceptorsWrapper(
      onRequest: (request, handler) => handler.reject(DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
          error: '电脑不在同一网络'))));
  return api;
}

class OfflineBridge extends StubRecordingBridge {
  OfflineBridge(this.file);
  final File file;
  String? startedCourse;
  List<Map<String, dynamic>> alarms = [];
  @override
  Future<RecordingStartResult> startRecording(
      {required String courseId,
      required String scheduleEntryId,
      String codec = 'aac'}) async {
    startedCourse = courseId;
    return RecordingStartResult(
        sessionId: 'test', filePath: file.path, startedAtMs: 1, codec: codec);
  }

  @override
  Future<RecordingResult> stopRecording() async => RecordingResult(
      sessionId: 'test',
      filePath: file.path,
      durationMs: 60000,
      sizeBytes: file.lengthSync(),
      success: true,
      courseId: startedCourse,
      classDate: '2026-10-12');
  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> value) async {
    alarms = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(
      {ScheduleStore.cacheKey: jsonEncode(snapshot())}));

  test('旧版只有课表缓存，也能恢复课程名及原课程 ID', () async {
    final courses = await CourseStore.cached();
    expect(courses.map((course) => course['id']), ['mechanics', 'math']);
    expect(courses.first['name'], '工程力学');
  });

  test('断网仍布防至学期末；手机关闭某门课程后不会被电脑设置覆盖', () async {
    final api = disconnected();
    final bridge = OfflineBridge(File('unused'));
    var requests = 0;
    api.dio.interceptors.insert(0, InterceptorsWrapper(onRequest: (_, handler) {
      requests++;
      handler.next(_);
    }));
    final count = await AutoRecordingSchedule.sync(api, bridge,
        now: DateTime(2026, 10, 12, 6), enabled: true);
    expect(count, 3);
    expect(bridge.alarms.last['classDate'], '2027-01-04');
    expect(requests, 0);
    await CourseStore.setPhoneAutoRecord('mechanics', false);
    expect(
        await AutoRecordingSchedule.sync(api, bridge,
            now: DateTime(2026, 10, 12, 6), enabled: true),
        0);
    expect(bridge.alarms, isEmpty);
    api.dio.close();
  });

  testWidgets('手机冷启动且电脑离线，能选课程、开始和停止；音频入队保留', (tester) async {
    final dir = Directory.systemTemp.createTempSync('cna-offline-test-');
    final audio = File('${dir.path}/offline.m4a')
      ..writeAsBytesSync(List.filled(128, 1));
    addTearDown(() => dir.deleteSync(recursive: true));
    final api = disconnected();
    final queue = UploadQueue(apiClient: api);
    addTearDown(queue.dispose);
    final bridge = OfflineBridge(audio);
    await tester.pumpWidget(MaterialApp(
        home: RecordingPage(
            recordingBridge: bridge, apiClient: api, uploadQueue: queue)));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>));
    expect(dropdown.initialValue, '工程力学');
    await tester.tap(find.text('工程力学'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线性代数').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始上课录音'));
    await tester.pumpAndSettle();
    expect(bridge.startedCourse, 'math');
    await tester.tap(find.text('停止并同步'));
    await tester.pumpAndSettle();
    expect(queue.items.single.courseId, 'math');
    expect(queue.items.single.status, isNot(UploadStatus.completed));
    expect(audio.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.dio.close();
  });

  test('电脑连接失败时上传队列保留音频和课程信息', () async {
    final dir = await Directory.systemTemp.createTemp('cna-offline-upload-');
    addTearDown(() => dir.delete(recursive: true));
    final audio = File('${dir.path}/offline.m4a');
    await audio.writeAsBytes(List.filled(128, 1));
    final api = disconnected();
    final queue = UploadQueue(apiClient: api);
    addTearDown(queue.dispose);
    final stopped = queue.queueStream.firstWhere((items) =>
        items.isNotEmpty && items.single.status == UploadStatus.failed);
    queue.enqueue(
        filePath: audio.path,
        courseId: 'mechanics',
        lesson: 1,
        classDate: '2026-10-12');
    final items = await stopped.timeout(const Duration(seconds: 5));
    expect(items.single.courseId, 'mechanics');
    expect(await audio.exists(), isTrue);
    expect(
        (await SharedPreferences.getInstance())
            .getString('class_notes_upload_queue'),
        contains('mechanics'));
    api.dio.close();
  });
}
