import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/course_store.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/features/recording/recording_timer.dart';
import 'package:class_notes_assistant/platform/recording_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

class _SpyRecordingBridge extends StubRecordingBridge {
  final StreamController<RecordingEvent> spyEvents =
      StreamController<RecordingEvent>.broadcast();

  String? lastCourseId;
  int? lastDurationLimitMs;
  String? lastLimitAction;
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  Completer<void>? startGate;
  RecordingStatus currentStatus = const RecordingStatus(
    isRecording: false,
    isPaused: false,
    elapsedMs: 0,
    amplitude: 0,
  );

  @override
  Future<RecordingStartResult> startRecording({
    required String courseId,
    required String scheduleEntryId,
    String codec = 'aac',
    int? durationLimitMs,
    String? limitAction,
  }) async {
    startCalls += 1;
    if (startGate != null) {
      await startGate!.future;
    }
    lastCourseId = courseId;
    lastDurationLimitMs = durationLimitMs;
    lastLimitAction = limitAction;
    currentStatus = RecordingStatus(
      isRecording: true,
      isPaused: false,
      sessionId: 'spy_session',
      elapsedMs: 0,
      amplitude: 1600,
      courseId: courseId,
      durationLimitMs: durationLimitMs,
      remainingMs: durationLimitMs,
      limitAction: durationLimitMs != null ? (limitAction ?? 'stop') : null,
      limitTriggered: false,
    );
    return RecordingStartResult(
      sessionId: 'spy_session',
      filePath: '/tmp/spy.m4a',
      startedAtMs: 1700000000000,
      codec: codec,
    );
  }

  @override
  Future<void> pauseRecording() async {
    pauseCalls += 1;
    currentStatus = RecordingStatus(
      isRecording: currentStatus.isRecording,
      isPaused: true,
      sessionId: currentStatus.sessionId,
      elapsedMs: currentStatus.elapsedMs,
      amplitude: 0,
      courseId: currentStatus.courseId,
      durationLimitMs: currentStatus.durationLimitMs,
      remainingMs: currentStatus.remainingMs,
      limitAction: currentStatus.limitAction,
      limitTriggered: currentStatus.limitTriggered,
    );
    emitStatus(currentStatus);
  }

  @override
  Future<void> resumeRecording() async {
    resumeCalls += 1;
    currentStatus = RecordingStatus(
      isRecording: currentStatus.isRecording,
      isPaused: false,
      sessionId: currentStatus.sessionId,
      elapsedMs: currentStatus.elapsedMs,
      amplitude: 1200,
      courseId: currentStatus.courseId,
      durationLimitMs: currentStatus.durationLimitMs,
      remainingMs: currentStatus.remainingMs,
      limitAction: currentStatus.limitAction,
      limitTriggered: currentStatus.limitTriggered,
    );
    emitStatus(currentStatus);
  }

  void emitStatus(RecordingStatus status) {
    currentStatus = status;
    spyEvents.add(RecordingEvent(type: 'status', payload: status));
  }

  void emitEvent(String type, dynamic payload) {
    spyEvents.add(RecordingEvent(type: type, payload: payload));
  }

  @override
  Future<RecordingStatus> getStatus() async => currentStatus;

  @override
  Stream<RecordingStatus> statusStream() => spyEvents.stream
      .where((e) => e.type == 'status')
      .map((e) => e.payload as RecordingStatus);

  @override
  Stream<RecordingEvent> eventStream() => spyEvents.stream;

  void close() => spyEvents.close();
}

void main() {
  group('RecordingTimerConfig 解析与格式化', () {
    test('支持小时加分钟、纯分钟、全角数字与边界校验', () {
      expect(RecordingTimerConfig.parseCustomInput('1', '40').minutes, 100);
      expect(RecordingTimerConfig.parseCustomInput('', '100').minutes, 100);
      expect(RecordingTimerConfig.parseCustomInput('１', '４０').minutes, 100);
      expect(RecordingTimerConfig.parseCustomInput('6', '0').minutes, 360);
      expect(RecordingTimerConfig.parseCustomInput('0', '1').minutes, 1);

      expect(RecordingTimerConfig.parseCustomInput('', '').minutes, isNull);
      expect(RecordingTimerConfig.parseCustomInput('0', '0').minutes, isNull);
      expect(RecordingTimerConfig.parseCustomInput('6', '1').minutes, isNull);
      expect(RecordingTimerConfig.parseCustomInput('-1', '20').minutes, isNull);
      expect(RecordingTimerConfig.parseCustomInput('1.5', '0').minutes, isNull);

      expect(RecordingTimerConfig.formatMinutes(45), '45 分钟');
      expect(RecordingTimerConfig.formatMinutes(60), '1 小时');
      expect(RecordingTimerConfig.formatMinutes(100), '1 小时 40 分');
      expect(RecordingTimerConfig.presetLabel(90), '90 分钟');
      expect(RecordingTimerConfig.presetLabel(100), '1 小时 40 分');
    });
  });

  group('RecordingPage 课堂定时录音交互', () {
    Future<void> seedCourses([Map<String, Object> extra = const {}]) async {
      SharedPreferences.setMockInitialValues({
        CourseStore.cacheKey: jsonEncode([
          {'id': 'mechanics', 'name': '工程力学', 'auto_record': false},
          {'id': 'physics', 'name': '普通物理1', 'auto_record': false},
        ]),
        ...extra,
      });
    }

    testWidgets('选择 1 小时 40 分与仅暂停后，启动录音传递正确参数并在到点后自动暂停与续录',
        (tester) async {
      await seedCourses();
      final bridge = _SpyRecordingBridge();
      final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
      addTearDown(() {
        bridge.close();
        api.dio.close();
      });

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: RecordingPage(
          recordingBridge: bridge,
          uploadQueue: UploadQueue(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      // 默认不限时，隐藏到点后动作区
      expect(find.byKey(const Key('recording-timer-section')), findsOneWidget);
      expect(find.byKey(const Key('recording-timer-action-row')), findsNothing);

      // 选中 1 小时 40 分
      await tester.tap(find.byKey(const Key('timer-preset-100')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('recording-timer-action-row')), findsOneWidget);

      // 切换为到点仅暂停
      await tester.tap(find.byKey(const Key('timer-action-pause')));
      await tester.pumpAndSettle();

      // 持久化已写入
      final saved = await RecordingTimerConfig.load();
      expect(saved.durationMinutes, 100);
      expect(saved.action, RecordingTimerAction.pause);

      // 点击开始上课录音
      await tester.tap(find.text('开始上课录音'));
      await tester.pumpAndSettle();

      expect(bridge.lastCourseId, 'mechanics');
      expect(bridge.lastDurationLimitMs, 100 * 60 * 1000);
      expect(bridge.lastLimitAction, 'pause');
      expect(find.byKey(const Key('recording-countdown-badge')), findsOneWidget);
      expect(find.textContaining('剩余 01:40:00 · 到点自动暂停'), findsOneWidget);

      // 模拟原生倒计时到达并自动暂停
      const pausedSnap = RecordingStatus(
        isRecording: true,
        isPaused: true,
        sessionId: 'spy_session',
        elapsedMs: 100 * 60 * 1000,
        amplitude: 0,
        courseId: 'mechanics',
        durationLimitMs: 100 * 60 * 1000,
        remainingMs: 0,
        limitAction: 'pause',
        limitTriggered: true,
      );
      bridge.emitStatus(pausedSnap);
      bridge.emitEvent('countdownPaused', pausedSnap);
      await tester.pumpAndSettle();

      expect(find.text('定时已到 · 已自动暂停'), findsOneWidget);
      expect(find.text('已达到定时时长，录音已自动暂停'), findsOneWidget);
      expect(find.byTooltip('继续录音'), findsOneWidget);

      // 点击继续录音后显示已超原定时长
      await tester.tap(find.byTooltip('继续录音'));
      await tester.pumpAndSettle();
      expect(bridge.resumeCalls, 1);
      expect(find.text('已超原定时长 · 手动停止结束'), findsOneWidget);
    });

    testWidgets('到点自动停止并保存时退出录制态并给出明确提示', (tester) async {
      await seedCourses({
        RecordingTimerConfig.prefMinutesKey: 45,
        RecordingTimerConfig.prefActionKey: 'stop',
      });
      final bridge = _SpyRecordingBridge();
      final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
      addTearDown(() {
        bridge.close();
        api.dio.close();
      });

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: RecordingPage(
          recordingBridge: bridge,
          uploadQueue: UploadQueue(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      // 已恢复保存的 45 分钟 + 停止并保存
      expect(find.text('45 分钟 · 停止并保存'), findsOneWidget);

      await tester.tap(find.text('开始上课录音'));
      await tester.pumpAndSettle();
      expect(bridge.lastDurationLimitMs, 45 * 60 * 1000);
      expect(bridge.lastLimitAction, 'stop');

      // 模拟原生倒计时到达并自动停止
      bridge.emitEvent('autoStopped', {
        'filePath': '/tmp/spy.m4a',
        'courseId': 'mechanics',
        'durationMs': 45 * 60 * 1000,
        'classDate': '2026-11-20',
        'reason': 'countdown',
      });
      bridge.emitStatus(const RecordingStatus(
        isRecording: false,
        isPaused: false,
        elapsedMs: 45 * 60 * 1000,
        amplitude: 0,
      ));
      await tester.pumpAndSettle();

      expect(find.text('开始上课录音'), findsOneWidget);
      expect(find.text('定时录音已到点自动停止，请查看下方同步状态'), findsOneWidget);
      expect(find.textContaining('定时录音已到点自动停止（45:00）'), findsOneWidget);
    });

    testWidgets('切回前台重拉原生状态，且快速连点开始录音防重入', (tester) async {
      await seedCourses({
        RecordingTimerConfig.prefMinutesKey: 45,
        RecordingTimerConfig.prefActionKey: 'pause',
      });
      final bridge = _SpyRecordingBridge()..startGate = Completer<void>();
      final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
      addTearDown(() {
        if (!(bridge.startGate?.isCompleted ?? true)) {
          bridge.startGate!.complete();
        }
        bridge.close();
        api.dio.close();
      });

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: RecordingPage(
          recordingBridge: bridge,
          uploadQueue: UploadQueue(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      // 快速连点两次开始按钮，仅发起一次 startRecording
      await tester.tap(find.text('开始上课录音'));
      await tester.pump();
      await tester.tap(find.text('开始上课录音'), warnIfMissed: false);
      await tester.pump();
      expect(bridge.startCalls, 1);

      bridge.startGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('停止并同步'), findsOneWidget);

      // 模拟后台期间原生已自动暂停（未收到 EventSink 推送），切回前台后应立刻同步状态
      bridge.currentStatus = const RecordingStatus(
        isRecording: true,
        isPaused: true,
        sessionId: 'spy_session',
        elapsedMs: 45 * 60 * 1000,
        amplitude: 0,
        courseId: 'mechanics',
        durationLimitMs: 45 * 60 * 1000,
        remainingMs: 0,
        limitAction: 'pause',
        limitTriggered: true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('定时已到 · 已自动暂停'), findsOneWidget);
      expect(find.byTooltip('继续录音'), findsOneWidget);
    });

    testWidgets('自定义弹窗校验非法值并支持输入 1 小时 15 分', (tester) async {
      await seedCourses();
      final bridge = _SpyRecordingBridge();
      final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
      addTearDown(() {
        bridge.close();
        api.dio.close();
      });

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: RecordingPage(
          recordingBridge: bridge,
          uploadQueue: UploadQueue(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('timer-preset-custom')));
      await tester.pumpAndSettle();
      expect(find.text('自定义录音时长'), findsOneWidget);

      // 非法输入：7 小时超限
      await tester.enterText(
          find.byKey(const Key('custom-timer-hours-field')), '7');
      await tester.enterText(
          find.byKey(const Key('custom-timer-minutes-field')), '0');
      await tester.tap(find.byKey(const Key('custom-timer-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('custom-timer-error')), findsOneWidget);

      // 合法输入：1 小时 15 分
      await tester.enterText(
          find.byKey(const Key('custom-timer-hours-field')), '1');
      await tester.enterText(
          find.byKey(const Key('custom-timer-minutes-field')), '15');
      await tester.pumpAndSettle();
      expect(find.text('将定时录音 1 小时 15 分（共 75 分钟）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('custom-timer-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('自定义 · 1 小时 15 分'), findsOneWidget);
      expect(find.text('1 小时 15 分 · 停止并保存'), findsOneWidget);
    });

    testWidgets('多尺寸/深浅色/高对比/200%字号/横屏主按钮可达与过渡帧导出', (tester) async {
      final scenarios = [
        (
          name: 'portrait-390-1x-light-timed',
          size: const Size(390, 900),
          scale: 1.0,
          dark: false,
          highContrast: false,
          reduceMotion: false,
          status: null as RecordingStatus?,
          openDialog: false,
          checkActionsInViewport: false,
        ),
        (
          name: 'portrait-360-2x-dark-timed',
          size: const Size(360, 900),
          scale: 2.0,
          dark: true,
          highContrast: false,
          reduceMotion: true,
          status: null as RecordingStatus?,
          openDialog: false,
          checkActionsInViewport: false,
        ),
        (
          name: 'portrait-360-2x-dark-dialog',
          size: const Size(360, 900),
          scale: 2.0,
          dark: true,
          highContrast: false,
          reduceMotion: true,
          status: null as RecordingStatus?,
          openDialog: true,
          checkActionsInViewport: false,
        ),
        (
          name: 'portrait-390-1x-light-active',
          size: const Size(390, 900),
          scale: 1.0,
          dark: false,
          highContrast: false,
          reduceMotion: false,
          status: const RecordingStatus(
            isRecording: true,
            isPaused: false,
            sessionId: 'spy_session',
            elapsedMs: 125000,
            amplitude: 9000,
            courseId: 'mechanics',
            durationLimitMs: 100 * 60 * 1000,
            remainingMs: (100 * 60 - 125) * 1000,
            limitAction: 'pause',
            limitTriggered: false,
          ),
          openDialog: false,
          checkActionsInViewport: true,
        ),
        (
          name: 'portrait-390-1x-light-autopaused',
          size: const Size(390, 900),
          scale: 1.0,
          dark: false,
          highContrast: true,
          reduceMotion: false,
          status: const RecordingStatus(
            isRecording: true,
            isPaused: true,
            sessionId: 'spy_session',
            elapsedMs: 100 * 60 * 1000,
            amplitude: 0,
            courseId: 'mechanics',
            durationLimitMs: 100 * 60 * 1000,
            remainingMs: 0,
            limitAction: 'pause',
            limitTriggered: true,
          ),
          openDialog: false,
          checkActionsInViewport: true,
        ),
        (
          name: 'portrait-390-1x-light-overlimit',
          size: const Size(390, 900),
          scale: 1.0,
          dark: false,
          highContrast: false,
          reduceMotion: false,
          status: const RecordingStatus(
            isRecording: true,
            isPaused: false,
            sessionId: 'spy_session',
            elapsedMs: 105 * 60 * 1000,
            amplitude: 6000,
            courseId: 'mechanics',
            durationLimitMs: 100 * 60 * 1000,
            remainingMs: 0,
            limitAction: 'pause',
            limitTriggered: true,
          ),
          openDialog: false,
          checkActionsInViewport: true,
        ),
        (
          name: 'landscape-844-1x-dark-active',
          size: const Size(844, 390),
          scale: 1.0,
          dark: true,
          highContrast: false,
          reduceMotion: false,
          status: const RecordingStatus(
            isRecording: true,
            isPaused: false,
            sessionId: 'spy_session',
            elapsedMs: 125000,
            amplitude: 9000,
            courseId: 'mechanics',
            durationLimitMs: 100 * 60 * 1000,
            remainingMs: (100 * 60 - 125) * 1000,
            limitAction: 'pause',
            limitTriggered: false,
          ),
          openDialog: false,
          checkActionsInViewport: true,
        ),
        (
          name: 'landscape-960-1x-light-active',
          size: const Size(960, 390),
          scale: 1.0,
          dark: false,
          highContrast: false,
          reduceMotion: false,
          status: const RecordingStatus(
            isRecording: true,
            isPaused: false,
            sessionId: 'spy_session',
            elapsedMs: 125000,
            amplitude: 9000,
            courseId: 'mechanics',
            durationLimitMs: 100 * 60 * 1000,
            remainingMs: (100 * 60 - 125) * 1000,
            limitAction: 'stop',
            limitTriggered: false,
          ),
          openDialog: false,
          checkActionsInViewport: true,
        ),
      ];

      final output = Platform.environment['CNA_COUNTDOWN_UI_OUTPUT'];
      await tester.runAsync(loadFonts);

      Future<void> saveFrame(GlobalKey key, String name) async {
        if (output == null || output.isEmpty) return;
        await tester.runAsync(() async {
          Directory(output).createSync(recursive: true);
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$output/$name.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final s in scenarios) {
        await seedCourses({
          RecordingTimerConfig.prefMinutesKey: 100,
          RecordingTimerConfig.prefActionKey: 'pause',
        });
        tester.view.physicalSize = s.size;
        tester.view.devicePixelRatio = 1;
        final bridge = _SpyRecordingBridge();
        if (s.status != null) {
          bridge.currentStatus = s.status!;
        }
        final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
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
            home: RecordingPage(
              recordingBridge: bridge,
              uploadQueue: UploadQueue(apiClient: api),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        if (s.openDialog) {
          await tester.tap(find.byKey(const Key('timer-preset-custom')));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull, reason: s.name);

        if (s.checkActionsInViewport) {
          final stopRect = tester.getRect(find.text('停止并同步'));
          expect(stopRect.bottom, lessThanOrEqualTo(s.size.height),
              reason: '${s.name}: 停止并同步按钮需在首屏完整可见');
        }

        await saveFrame(boundaryKey, s.name);
        await tester.pumpWidget(const SizedBox.shrink());
        bridge.close();
        api.dio.close();
      }

      // 动画过渡中段帧与快速反向切换检查（不限时 ↔ 1小时40分 ↔ 开始录音）
      await seedCourses();
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      final animBridge = _SpyRecordingBridge();
      final animApi = ApiClient(baseUrl: 'http://127.0.0.1:8000');
      final animKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: animKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: RecordingPage(
            recordingBridge: animBridge,
            uploadQueue: UploadQueue(apiClient: animApi),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('timer-preset-100')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull);
      await saveFrame(animKey, 'transition-mid-expand');

      // 快速反向切回不限时，再切回 100 分钟
      await tester.tap(find.byKey(const Key('timer-preset-unlimited')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('timer-preset-100')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recording-timer-action-row')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      animBridge.close();
      animApi.dio.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
