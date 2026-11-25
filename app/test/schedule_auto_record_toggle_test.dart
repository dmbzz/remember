import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/auto_recording_schedule.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_auto_record_card.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_preferences.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/platform/course_reminder_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

class _FakeScheduleBridge extends StubRecordingBridge {
  bool grantPermissions = true;
  bool acceptAlarms = true;
  bool failOnClear = false;
  bool armed = false;
  final List<List<Map<String, dynamic>>> alarmHistory = [];

  @override
  Future<PermissionStatus> requestPermissions() async => PermissionStatus(
        recordAudio: grantPermissions,
        notifications: grantPermissions,
        foregroundService: grantPermissions,
        batteryUnrestricted: true,
        autoStartEnabled: false,
      );

  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> alarms) async {
    alarmHistory.add(alarms);
    if (alarms.isEmpty && failOnClear) {
      throw StateError('系统闹钟服务暂时无响应');
    }
    if (!acceptAlarms && alarms.isNotEmpty) {
      armed = false;
      return false;
    }
    armed = alarms.isNotEmpty;
    return true;
  }

  @override
  Future<RecordingStatus> getStatus() async => RecordingStatus(
        isRecording: false,
        isPaused: false,
        elapsedMs: 0,
        amplitude: 0,
        isArmed: armed,
      );
}

ScheduleSnapshot _sampleSnapshot({bool autoRecordCourse = true}) {
  final today = DateTime.now();
  final monday =
      DateTime(today.year, today.month, today.day - today.weekday + 1);
  return ScheduleSnapshot(
    entries: [
      {
        'id': 'e1',
        'course_id': 'mechanics',
        'course_name': '工程力学',
        'weekday': today.weekday,
        'start_time': '08:15',
        'end_time': '23:59',
        'location': '致知楼 201',
        'weeks': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        'auto_record': autoRecordCourse,
        'confirmed': true,
      },
      {
        'id': 'e2',
        'course_id': 'physics',
        'course_name': '普通物理1',
        'weekday': today.weekday == 7 ? 1 : today.weekday + 1,
        'start_time': '10:05',
        'end_time': '11:40',
        'location': '致理楼 305',
        'weeks': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        'auto_record': autoRecordCourse,
        'confirmed': true,
      },
    ],
    semesterStart: monday,
    updatedAt: today,
    termLabel: '2026 秋',
    configured: true,
    preferences: const SchedulePreferences(semesterWeeks: 16),
  );
}

ApiClient _offlineApi() {
  final api = ApiClient(baseUrl: 'http://offline-schedule.test');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    handler.reject(DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: '离线测试',
    ));
  }));
  return api;
}

Future<void> _exportBoundaryPng(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String outputDir,
  String fileName,
) async {
  await tester.runAsync(() async {
    Directory(outputDir).createSync(recursive: true);
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$outputDir/$fileName.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AutoRecordingSchedule.resetForTest(enabled: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      CourseReminderBridge.channel,
      (call) async => call.method == 'status' ? <String, dynamic>{} : null,
    );
  });

  testWidgets('课表页醒目快捷开关一键开/关并持久化与登记/撤销闹钟', (tester) async {
    final snapshot = _sampleSnapshot();
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
      AutoRecordingSchedule.enabledKey: false,
    });
    final api = _offlineApi();
    final bridge = _FakeScheduleBridge();
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: SchedulePage(
        apiClient: api,
        recordingBridge: bridge,
        showAutoRecordQuickToggle: true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-auto-record-card')), findsOneWidget);
    expect(find.text('已关闭'), findsOneWidget);
    expect(find.textContaining('当前手机不上课自动录'), findsOneWidget);

    // 点击卡片开启
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('已布防'), findsOneWidget);
    expect(find.textContaining('已排 '), findsOneWidget);
    expect(bridge.armed, isTrue);
    expect(bridge.alarmHistory.last, isNotEmpty);
    expect(
      (await SharedPreferences.getInstance())
          .getBool(AutoRecordingSchedule.enabledKey),
      isTrue,
    );

    // 换手机前一键关闭
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('已关闭'), findsOneWidget);
    expect(bridge.armed, isFalse);
    expect(bridge.alarmHistory.last, isEmpty);
    expect(
      (await SharedPreferences.getInstance())
          .getBool(AutoRecordingSchedule.enabledKey),
      isFalse,
    );
  });

  testWidgets('权限被拒、开启布防失败及关闭撤销闹钟失败均诚实提示不伪装', (tester) async {
    final snapshot = _sampleSnapshot();
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
      AutoRecordingSchedule.enabledKey: false,
    });
    final api = _offlineApi();
    final bridge = _FakeScheduleBridge()..grantPermissions = false;
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: SchedulePage(
        apiClient: api,
        recordingBridge: bridge,
        showAutoRecordQuickToggle: true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('已关闭'), findsOneWidget);
    expect(find.textContaining('请先允许麦克风和通知权限'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance())
          .getBool(AutoRecordingSchedule.enabledKey),
      isFalse,
    );

    // 权限放行但原生布防失败
    bridge
      ..grantPermissions = true
      ..acceptAlarms = false;
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('布防失败'), findsOneWidget);
    expect(find.textContaining('无法布防'), findsOneWidget);
    expect(find.text('已布防'), findsNothing);

    // 布防成功后，再关闭但撤销闹钟异常，卡片不得吞掉错误
    bridge
      ..acceptAlarms = true
      ..failOnClear = true;
    await AutoRecordingSchedule.sync(api, bridge, enabled: true, snapshot: snapshot);
    await tester.pumpAndSettle();
    expect(find.text('已布防'), findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('撤销失败'), findsOneWidget);
    expect(find.textContaining('撤销本机排期失败'), findsOneWidget);
  });

  testWidgets('跨页双向同步真实布防状态与排期节数，且无课程时如实标注未选课',
      (tester) async {
    final snapshot = _sampleSnapshot(autoRecordCourse: true);
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
      AutoRecordingSchedule.enabledKey: false,
    });
    final api = _offlineApi();
    final bridge = _FakeScheduleBridge();
    final queue = UploadQueue(apiClient: api);
    addTearDown(() {
      queue.dispose();
      api.dio.close();
    });

    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: Row(
        children: [
          Expanded(
            child: SchedulePage(
              apiClient: api,
              recordingBridge: bridge,
              showAutoRecordQuickToggle: true,
            ),
          ),
          Expanded(
            child: RecordingPage(
              apiClient: api,
              recordingBridge: bridge,
              uploadQueue: queue,
            ),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    // 在录音页开启，课表页应收到真实布防结果（已布防 + 已排节数），不能滞留在“尚未布防”
    final recordingSwitch =
        tester.widgetList<Switch>(find.byType(Switch)).last;
    recordingSwitch.onChanged!(true);
    await tester.pumpAndSettle();

    expect(find.text('已布防'), findsOneWidget);
    expect(find.textContaining('已排 '), findsOneWidget);
    expect(find.textContaining('自动录音服务：已布防'), findsOneWidget);

    // 在课表页关闭，录音页同步为关闭且未布防
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();

    expect(find.text('已关闭'), findsOneWidget);
    expect(find.textContaining('自动录音服务：尚未布防'), findsOneWidget);
    final switchesAfterOff =
        tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switchesAfterOff.every((s) => s.value == false), isTrue);

    // 切换为无自动录音课程的快照，在课表页开启，显示「未选课」而非「已布防」
    final emptyAutoSnapshot = _sampleSnapshot(autoRecordCourse: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        ScheduleStore.cacheKey, jsonEncode(emptyAutoSnapshot.toJson()));
    await tester.pumpWidget(const SizedBox.shrink());
    AutoRecordingSchedule.resetForTest(enabled: false);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: SchedulePage(
        apiClient: api,
        recordingBridge: bridge,
        showAutoRecordQuickToggle: true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pumpAndSettle();
    expect(find.text('未选课'), findsOneWidget);
    expect(find.textContaining('暂无开启自动录音的课程'), findsOneWidget);
  });

  testWidgets('紧凑模式真实展示非正常状态；卡片无障碍单次朗读且键盘单焦点',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      // 1. 紧凑模式：未选课、未布防、布防失败、同步中均清晰表达真实状态
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Column(
            children: [
              ScheduleAutoRecordCard(
                enabled: true,
                armed: false,
                syncing: false,
                scheduledCount: 0,
                compact: true,
                onChanged: (_) {},
              ),
              ScheduleAutoRecordCard(
                enabled: true,
                armed: false,
                syncing: false,
                scheduledCount: 3,
                compact: true,
                onChanged: (_) {},
              ),
              ScheduleAutoRecordCard(
                enabled: true,
                armed: false,
                syncing: false,
                errorText: '无法布防：缺精确闹钟权限',
                compact: true,
                onChanged: (_) {},
              ),
              ScheduleAutoRecordCard(
                enabled: true,
                armed: false,
                syncing: true,
                compact: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('未选课'), findsOneWidget);
      expect(find.text('暂无开启自动录音的课程'), findsOneWidget);
      expect(find.text('未布防'), findsOneWidget);
      expect(find.text('尚未布防，请检查权限'), findsOneWidget);
      expect(find.text('布防失败'), findsOneWidget);
      expect(find.text('无法布防：缺精确闹钟权限'), findsOneWidget);
      expect(find.text('同步中'), findsOneWidget);
      expect(find.text('正在更新排期…'), findsOneWidget);

      // 2. 无障碍单次朗读与键盘单焦点
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: ScheduleAutoRecordCard(
            enabled: true,
            armed: true,
            syncing: false,
            scheduledCount: 5,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final cardFinder = find.byType(ScheduleAutoRecordCard);
      final node = tester.getSemantics(cardFinder);
      expect(node.label, contains('本机到点自动录音，已布防'));
      expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
      expect(node.childrenCount, 0);

      // Switch 被 ExcludeFocus 包裹，键盘焦点不会停靠在 Switch 内部
      expect(
        find.ancestor(
          of: find.byKey(const Key('schedule-auto-record-switch')),
          matching: find.byType(ExcludeFocus),
        ),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('桌面端默认不显示手机自动录音快捷卡片', (tester) async {
    final snapshot = _sampleSnapshot();
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
    });
    final api = _offlineApi();
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: SchedulePage(apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-auto-record-card')), findsNothing);
  });

  testWidgets('OFF↔ON 过渡动效、快速反向切换与减动模式无异常并导出过渡帧', (tester) async {
    final output = Platform.environment['CNA_SCHEDULE_AUTO_UI_OUTPUT'];
    await tester.runAsync(loadFonts);

    final boundaryKey = GlobalKey();
    var enabled = false;
    var armed = false;
    var reduceMotion = false;
    late StateSetter setHostState;

    tester.view.physicalSize = const Size(390, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ScheduleAutoRecordCard(
                    enabled: enabled,
                    armed: armed,
                    syncing: false,
                    scheduledCount: armed ? 6 : null,
                    onChanged: (next) => setState(() {
                      enabled = next;
                      armed = next;
                    }),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 0ms 开始帧（触发 OFF -> ON）
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    if (output != null && output.isNotEmpty) {
      await _exportBoundaryPng(
          tester, boundaryKey, output, 'transition-off-to-on-0ms');
    }

    // 80ms 中间帧（160ms 的中点）
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);
    if (output != null && output.isNotEmpty) {
      await _exportBoundaryPng(
          tester, boundaryKey, output, 'transition-off-to-on-80ms');
    }

    // 160ms 终态帧
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('已布防'), findsOneWidget);
    if (output != null && output.isNotEmpty) {
      await _exportBoundaryPng(
          tester, boundaryKey, output, 'transition-off-to-on-160ms');
    }

    // 快速反向：60ms 后立刻反切回 OFF
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);
    if (output != null && output.isNotEmpty) {
      await _exportBoundaryPng(
          tester, boundaryKey, output, 'transition-reverse-to-off-80ms');
    }
    await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);

    // 减动模式：1 帧即时到位，无异常
    setHostState(() => reduceMotion = true);
    await tester.pump();
    await tester.tap(find.byKey(const Key('schedule-auto-record-card')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('已布防'), findsOneWidget);
  });

  testWidgets('多尺寸/深浅色/高对比/200%字号/横竖屏整周无溢出并支持导出评审截图',
      (tester) async {
    final output = Platform.environment['CNA_SCHEDULE_AUTO_UI_OUTPUT'];
    await tester.runAsync(loadFonts);

    final scenarios = [
      (
        name: 'portrait-390-1x-light-off',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        enabled: false,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'portrait-390-1x-light-on-armed',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        enabled: true,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'portrait-390-1x-light-on-nocourse',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        enabled: true,
        autoCourse: false,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'portrait-360-2x-dark-on',
        size: const Size(360, 900),
        scale: 2.0,
        dark: true,
        highContrast: false,
        reduceMotion: true,
        enabled: true,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'portrait-360-2x-highcontrast-off',
        size: const Size(360, 900),
        scale: 2.0,
        dark: false,
        highContrast: true,
        reduceMotion: true,
        enabled: false,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'portrait-360-2x-light-week-on',
        size: const Size(360, 900),
        scale: 2.0,
        dark: false,
        highContrast: false,
        reduceMotion: true,
        enabled: true,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: true,
      ),
      (
        name: 'landscape-844-1x-dark-on',
        size: const Size(844, 390),
        scale: 1.0,
        dark: true,
        highContrast: false,
        reduceMotion: false,
        enabled: true,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'landscape-844-1x-light-error',
        size: const Size(844, 390),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        enabled: true,
        autoCourse: true,
        acceptAlarms: false,
        switchToWeek: false,
      ),
      (
        name: 'landscape-844-2x-dark-on',
        size: const Size(844, 390),
        scale: 2.0,
        dark: true,
        highContrast: false,
        reduceMotion: true,
        enabled: true,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'landscape-960-1x-light-off',
        size: const Size(960, 390),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        enabled: false,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
      (
        name: 'landscape-960-2x-light-off',
        size: const Size(960, 390),
        scale: 2.0,
        dark: false,
        highContrast: false,
        reduceMotion: true,
        enabled: false,
        autoCourse: true,
        acceptAlarms: true,
        switchToWeek: false,
      ),
    ];

    for (final s in scenarios) {
      final snapshot = _sampleSnapshot(autoRecordCourse: s.autoCourse);
      AutoRecordingSchedule.resetForTest(enabled: s.enabled);
      SharedPreferences.setMockInitialValues({
        ScheduleStore.cacheKey: jsonEncode(snapshot.toJson()),
        AutoRecordingSchedule.enabledKey: s.enabled,
      });
      tester.view.physicalSize = s.size;
      tester.view.devicePixelRatio = 1;
      final api = _offlineApi();
      final bridge = _FakeScheduleBridge()
        ..acceptAlarms = s.acceptAlarms
        ..armed = s.enabled && s.autoCourse && s.acceptAlarms;
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: s.dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(s.scale),
              disableAnimations: s.reduceMotion,
              highContrast: s.highContrast,
            ),
            child: child!,
          ),
          home: SchedulePage(
            apiClient: api,
            recordingBridge: bridge,
            showAutoRecordQuickToggle: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      if (s.switchToWeek) {
        await tester.tap(find.text('整周'));
        await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull, reason: s.name);
      expect(find.byKey(const Key('schedule-auto-record-card')), findsOneWidget);

      if (s.name == 'landscape-844-1x-dark-on') {
        // 844×390 横屏当天首屏必须能直接看到当天课程，不被顶栏挤出视野
        expect(find.text('工程力学'), findsOneWidget);
        final courseRect = tester.getRect(find.text('工程力学'));
        expect(courseRect.top, lessThan(390),
            reason: '844×390 横屏首屏应可见当天课程');
      }
      if (s.name == 'landscape-844-1x-light-error') {
        expect(find.text('布防失败'), findsOneWidget);
        expect(find.textContaining('无法布防'), findsOneWidget);
      }
      if (s.name == 'landscape-960-1x-light-off') {
        // 960×390 紧凑横屏保留教学周、离线与网格外提示入口
        expect(find.textContaining('第 1 周'), findsOneWidget);
        expect(find.byKey(const Key('schedule-compact-offline-btn')),
            findsOneWidget);
        expect(find.byKey(const Key('schedule-compact-invalid-btn')),
            findsOneWidget);
      }

      if (output != null && output.isNotEmpty) {
        await _exportBoundaryPng(tester, boundaryKey, output, s.name);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
