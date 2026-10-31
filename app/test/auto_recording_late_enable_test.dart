import 'dart:async';
import 'dart:convert';

import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/course_store.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/auto_recording_schedule.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_preferences.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/platform/course_reminder_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControlledBridge extends StubRecordingBridge {
  final calls = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>> applied = [];
  Completer<bool>? blockFirst;

  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> alarms) async {
    calls.add(alarms);
    if (calls.length == 1 && blockFirst != null) {
      final accepted = await blockFirst!.future;
      if (!accepted) return false;
    }
    applied = alarms;
    return true;
  }
}

ScheduleSnapshot _sample(DateTime day) => ScheduleSnapshot(
      entries: [
        {
          'course_id': 'synthetic',
          'course_name': 'Test course',
          'weekday': day.weekday,
          'start_time': '10:05',
          'end_time': '11:40',
          'weeks': <int>[],
          'auto_record': true,
          'confirmed': true,
        }
      ],
      semesterStart: DateTime(day.year, day.month, day.day - day.weekday + 1),
      updatedAt: day,
      termLabel: 'test',
      configured: true,
      preferences: const SchedulePreferences(semesterWeeks: 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            CourseReminderBridge.channel,
            (call) async =>
                call.method == 'status' ? <String, dynamic>{} : null);
  });

  test('准点和晚开当堂仍保留原课始、课末；下课即不补录', () async {
    final api = ApiClient(baseUrl: 'http://unused.test');
    addTearDown(api.dio.close);
    final bridge = _ControlledBridge();
    final snapshot = _sample(DateTime(2026, 10, 31));
    final start = DateTime(2026, 10, 31, 10, 5).millisecondsSinceEpoch;
    final end = DateTime(2026, 10, 31, 11, 40).millisecondsSinceEpoch;
    for (final now in [
      DateTime(2026, 10, 31, 10, 4, 59, 999),
      DateTime(2026, 10, 31, 10, 5),
      DateTime(2026, 10, 31, 10, 5, 0, 1),
      DateTime(2026, 10, 31, 11, 39, 59, 999),
    ]) {
      expect(
          await AutoRecordingSchedule.sync(api, bridge,
              enabled: true, now: now, snapshot: snapshot),
          1);
      final alarm = bridge.applied.single;
      expect(alarm['triggerEpochMs'], start);
      expect(alarm['endEpochMs'], end);
      expect(alarm['endTime'], '11:40');
      expect(alarm['durationMs'], 95 * 60 * 1000);
    }
    for (final now in [
      DateTime(2026, 10, 31, 11, 40),
      DateTime(2026, 10, 31, 11, 40, 0, 1),
    ]) {
      expect(
          await AutoRecordingSchedule.sync(api, bridge,
              enabled: true, now: now, snapshot: snapshot),
          0);
      expect(bridge.applied, isEmpty);
    }
  });

  testWidgets('旧撤销未完成时开启，最终重跑并写入有效排期', (tester) async {
    final snapshot = _sample(DateTime.now());
    snapshot.entries.single
        .addAll({'start_time': '00:00', 'end_time': '23:59'});
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
      AutoRecordingSchedule.enabledKey: false,
    });
    final api = ApiClient(baseUrl: 'http://unused.test');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: {'code': 0, 'data': <dynamic>[], 'message': 'ok'}));
    }));
    final queue = UploadQueue(apiClient: api);
    final pendingCancel = Completer<bool>();
    final bridge = _ControlledBridge()..blockFirst = pendingCancel;
    await tester.pumpWidget(MaterialApp(
        home: RecordingPage(
            recordingBridge: bridge, apiClient: api, uploadQueue: queue)));
    await tester.pump();
    await tester.pump();
    expect(bridge.calls.length, 1);
    expect(bridge.calls.single, isEmpty);
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(AutoRecordingSchedule.enabledKey),
        true);
    pendingCancel.complete(true);
    await tester.pumpAndSettle();
    expect(bridge.calls.length, 2);
    expect(bridge.applied.single['courseId'], 'synthetic');
    await tester.pumpWidget(const SizedBox.shrink());
    queue.dispose();
    api.dio.close();
  });

  testWidgets('不同入口同时刷新时原生写入串行，最后关闭不会被旧开启覆盖', (tester) async {
    final api = ApiClient(baseUrl: 'http://unused.test');
    addTearDown(api.dio.close);
    final gate = Completer<bool>();
    final bridge = _ControlledBridge()..blockFirst = gate;
    final first = AutoRecordingSchedule.sync(api, bridge,
        enabled: true,
        now: DateTime(2026, 10, 31, 10),
        snapshot: _sample(DateTime(2026, 10, 31)));
    await tester.pump();
    expect(bridge.calls.length, 1);
    final last = AutoRecordingSchedule.sync(api, bridge, enabled: false);
    await tester.pump();
    expect(bridge.calls.length, 1);
    gate.complete(true);
    await tester.pump();
    expect(await first, 1);
    expect(await last, 0);
    expect(bridge.applied, isEmpty);
  });

  testWidgets('排队请求执行时重读手机课程开关，失败的前次请求不堵塞后续', (tester) async {
    final api = ApiClient(baseUrl: 'http://unused.test');
    addTearDown(api.dio.close);
    final gate = Completer<bool>();
    final bridge = _ControlledBridge()..blockFirst = gate;
    final first = AutoRecordingSchedule.sync(api, bridge,
        enabled: true,
        now: DateTime(2026, 10, 31, 10),
        snapshot: _sample(DateTime(2026, 10, 31)));
    // Install the error handler before releasing the failed native write.
    final failed = expectLater(first, throwsStateError);
    await tester.pump();
    final last = AutoRecordingSchedule.sync(api, bridge,
        enabled: true,
        now: DateTime(2026, 10, 31, 10),
        snapshot: _sample(DateTime(2026, 10, 31)));
    await CourseStore.setPhoneAutoRecord('synthetic', false);
    gate.complete(false);
    await tester.pump();
    await failed;
    expect(await last, 0);
    expect(bridge.applied, isEmpty);
  });
}
