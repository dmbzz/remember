import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/recording/auto_recording_schedule.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/features/schedule/schedule_preferences.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CaptureRecordingBridge extends StubRecordingBridge {
  List<Map<String, dynamic>> alarms = [];
  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> value) async {
    alarms = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('共享学期总周数限制空周集课程的自动录音排期', () async {
    SharedPreferences.setMockInitialValues(
        {AutoRecordingSchedule.enabledKey: true});
    final api = ApiClient(baseUrl: 'http://unused.test');
    final bridge = CaptureRecordingBridge();
    final snapshot = ScheduleSnapshot(
        entries: [
          {
            'course_id': 'weekly',
            'course_name': '每周课',
            'weekday': 1,
            'start_time': '08:15',
            'end_time': '09:50',
            'weeks': <int>[],
            'auto_record': true,
            'confirmed': true,
          }
        ],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 8, 31),
        termLabel: '测试',
        preferences: const SchedulePreferences(semesterWeeks: 2),
        configured: true);
    expect(
        await AutoRecordingSchedule.sync(api, bridge,
            now: DateTime(2026, 8, 31, 6), snapshot: snapshot),
        2);
    expect(bridge.alarms.last['classDate'], '2026-09-07');
    expect(
        await AutoRecordingSchedule.sync(api, bridge,
            now: DateTime(2026, 9, 14, 6), snapshot: snapshot),
        0);
    expect(bridge.alarms, isEmpty);
    api.dio.close();
  });
  test('只为该教学周且已开启自动录音的课程布防，关闭时撤销', () async {
    SharedPreferences.setMockInitialValues({
      AutoRecordingSchedule.enabledKey: true,
      'cna_semester_start': '2026-08-31',
    });
    final api = ApiClient(baseUrl: 'http://test.local');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      final entries = [
        {
          'course_id': 'physics',
          'course_name': '物理',
          'weekday': 5,
          'start_time': '10:05',
          'end_time': '11:40',
          'weeks': [6],
          'location': '教学楼2-408',
          'confirmed': true
        },
        {
          'course_id': 'math',
          'course_name': '数学',
          'weekday': 5,
          'start_time': '14:15',
          'end_time': '15:50',
          'weeks': [6],
          'confirmed': true
        },
      ];
      final courses = [
        {'id': 'physics', 'name': '物理', 'auto_record': true},
        {'id': 'math', 'name': '数学', 'auto_record': false},
      ];
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
        'code': 0,
        'data': request.path == '/api/schedule' ? entries : courses,
        'message': 'ok'
      }));
    }));
    final bridge = CaptureRecordingBridge();
    final count = await AutoRecordingSchedule.sync(api, bridge,
        now: DateTime(2026, 10, 9, 9));
    expect(count, 1);
    expect(bridge.alarms.single['courseId'], 'physics');
    expect(bridge.alarms.single['durationMs'], 95 * 60 * 1000);
    expect(bridge.alarms.single['location'], '教学楼2-408');
    await AutoRecordingSchedule.sync(api, bridge, enabled: false);
    expect(bridge.alarms, isEmpty);
    api.dio.close();
  });
}
