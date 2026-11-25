import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/core/constants.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/course_store.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/recording_history_page.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/platform/recording_bridge.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

class _StaleScan extends StubRecordingBridge {
  _StaleScan(this.path);
  final String path;
  @override
  Future<List<Map<String, dynamic>>> listRecordingFiles() async => [
        {'filePath': path, 'courseId': 'mechanics', 'classDate': '2026-11-02'}
      ];
}

class _ActiveRecording extends StubRecordingBridge {
  _ActiveRecording(this.file);
  final File file;
  final sessionId = 'rec_auto_mechanics_1793607300000';
  bool active = true;
  bool discardRequested = false;

  @override
  Future<RecordingStatus> getStatus() async => RecordingStatus(
      isRecording: active,
      isPaused: false,
      sessionId: sessionId,
      elapsedMs: 23000,
      amplitude: 0,
      courseId: 'mechanics');

  @override
  Future<List<Map<String, dynamic>>> listRecordingFiles() async =>
      active || !file.existsSync()
          ? []
          : [
              {
                'filePath': file.path,
                'courseId': 'mechanics',
                'classDate': '2026-11-02',
                'discardRequested': discardRequested
              }
            ];
}

class _DeleteFixture {
  late Directory dir;
  late File file;
  late ApiClient api;
  late UploadQueue queue;
  final restoredQueues = <UploadQueue>[];
  final requests = <String>[];
  int deletes = 0;
  bool failDelete = false;
  Completer<void>? pairingEntered;
  Completer<void>? releasePairing;
  Completer<void>? deleteEntered;
  Completer<void>? releaseDelete;

  Future<void> init(
      {UploadStatus status = UploadStatus.failed, bool seed = true}) async {
    dir = await Directory.systemTemp.createTemp('remember-local-delete-');
    file = await File('${dir.path}/accidental_recording.m4a')
        .writeAsBytes([1, 2, 3, 4]);
    SharedPreferences.setMockInitialValues({
      CourseStore.cacheKey: jsonEncode([
        {'id': 'mechanics', 'name': '工程力学', 'auto_record': false}
      ]),
      'class_notes_upload_queue': jsonEncode([
        if (seed)
          UploadItem(
                  id: 'accidental',
                  filePath: file.path,
                  courseId: 'mechanics',
                  lesson: 1,
                  classDate: '2026-11-02',
                  status: status,
                  retryable: false,
                  error: '电脑未连接')
              .toJson()
      ])
    });
    api = ApiClient(baseUrl: 'http://delete-test.invalid');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      requests.add(o.path);
      if (o.path == '/api/pairing/check' && releasePairing != null) {
        if (!(pairingEntered?.isCompleted ?? true)) pairingEntered!.complete();
        await releasePairing!.future;
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'code': 0,
          'data': {'paired': true, 'server_id': 'aaaaaaaaaaaaaaaa'}
        }));
      } else {
        h.reject(DioException(
            requestOptions: o, type: DioExceptionType.connectionError));
      }
    }));
    queue = _newQueue();
    if (seed) {
      await _loaded(queue);
    } else {
      await Future<void>.delayed(Duration.zero);
    }
  }

  UploadQueue _newQueue() => UploadQueue(
      apiClient: api,
      retryDelay: const Duration(minutes: 1),
      deleteLocalFile: (path) async {
        deletes++;
        if (!(deleteEntered?.isCompleted ?? true)) deleteEntered!.complete();
        if (releaseDelete != null) await releaseDelete!.future;
        if (failDelete) throw FileSystemException('模拟删除失败', path);
        final target = File(path);
        if (await target.exists()) await target.delete();
      });

  static Future<void> _loaded(UploadQueue queue) async {
    await queue.queueStream
        .firstWhere((items) => items.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
  }

  Future<UploadQueue> reopen() async {
    final restored = _newQueue();
    restoredQueues.add(restored);
    await _loaded(restored);
    return restored;
  }

  Future<void> close() async {
    queue.dispose();
    for (final restored in restoredQueues) {
      restored.dispose();
    }
    api.dio.close(force: true);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    // File IO completes outside the widget clock, while the tapped widget's
    // continuations still need the test clock's microtasks to be drained.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), true, reason: '等待本地录音状态超时');
}

Future<void> _capture(GlobalKey key, String name) async {
  final output = Platform.environment['CNA_UI_OUTPUT'];
  if (output == null) return;
  await Directory(output).create(recursive: true);
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final frame = await boundary.toImage(pixelRatio: 2);
  final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
  await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  frame.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('删除真实临时录音后保留已删除记录，重新扫描和重启不会再上传', () async {
    final f = _DeleteFixture();
    await f.init();
    addTearDown(f.close);
    expect(f.queue.canDeleteLocalRecording('accidental'), true);
    await f.queue.deleteLocalRecording('accidental');
    expect(await f.file.exists(), false);
    expect(f.deletes, 1);
    expect(f.queue.items.single.status, UploadStatus.deleted);
    expect(f.queue.canDeleteLocalRecording('accidental'), false);
    await f.queue.recoverLocalRecordings(_StaleScan(f.file.path));
    expect(f.queue.items, hasLength(1));
    expect(f.queue.items.single.status, UploadStatus.deleted);
    final restored = await f.reopen();
    await restored.retryWhenConnected();
    await restored.processNext();
    expect(restored.items.single.status, UploadStatus.deleted);
    expect(f.requests, isEmpty);
  });

  test('删除失败仍停止同步，重试与指定课程不能恢复上传，重启保留待删除状态', () async {
    final f = _DeleteFixture();
    await f.init();
    addTearDown(f.close);
    f.failDelete = true;
    await expectLater(
        f.queue.deleteLocalRecording('accidental'), throwsA(anything));
    expect(await f.file.exists(), true);
    expect(f.queue.items.single.status, UploadStatus.deleting);
    expect(f.queue.items.single.error, isNotEmpty);
    f.queue.retry('accidental');
    f.queue.assignCourse('accidental', 'another-course');
    expect(f.queue.items.single.status, UploadStatus.deleting);
    expect(f.queue.items.single.courseId, 'mechanics');
    final restored = await f.reopen();
    await restored.retryWhenConnected();
    await restored.processNext();
    expect(restored.items.single.status, UploadStatus.deleting);
    expect(f.requests, isEmpty);
    f.failDelete = false;
    await restored.deleteLocalRecording('accidental');
    expect(restored.items.single.status, UploadStatus.deleted);
    expect(await f.file.exists(), false);
  });

  test('连接检查等待期间删除，稍后返回的连接结果不能把录音重新入队', () async {
    final f = _DeleteFixture();
    await f.init();
    addTearDown(f.close);
    f.queue.items.single.retryable = true;
    f.pairingEntered = Completer<void>();
    f.releasePairing = Completer<void>();
    final reconnecting = f.queue.retryWhenConnected();
    await f.pairingEntered!.future.timeout(const Duration(seconds: 5));
    await f.queue.deleteLocalRecording('accidental');
    f.releasePairing!.complete();
    await reconnecting;
    expect(f.queue.items.single.status, UploadStatus.deleted);
    expect(f.requests, ['/api/pairing/check']);
    expect(await f.file.exists(), false);
  });

  test('删除预留期间不可重复删除或上传，失败后可以再次明确删除', () async {
    final f = _DeleteFixture();
    await f.init();
    addTearDown(f.close);
    f.deleteEntered = Completer<void>();
    f.releaseDelete = Completer<void>();
    final deleting = f.queue.deleteLocalRecording('accidental');
    await f.deleteEntered!.future.timeout(const Duration(seconds: 5));
    expect(f.queue.isDeletingLocalRecording('accidental'), true);
    expect(f.queue.canDeleteLocalRecording('accidental'), false);
    f.queue.retry('accidental');
    await f.queue.processNext();
    expect(f.requests, isEmpty);
    f.releaseDelete!.complete();
    await deleting;
    expect(f.deletes, 1);
    expect(f.queue.isDeletingLocalRecording('accidental'), false);
    expect(f.queue.items.single.status, UploadStatus.deleted);
  });

  for (final status in [UploadStatus.uploading, UploadStatus.completed]) {
    test('${status.name} 录音拒绝删除，不触碰文件', () async {
      final f = _DeleteFixture();
      await f.init();
      addTearDown(f.close);
      f.queue.items.single.status = status;
      expect(f.queue.canDeleteLocalRecording('accidental'), false);
      await expectLater(
          f.queue.deleteLocalRecording('accidental'), throwsA(anything));
      expect(await f.file.exists(), true);
      expect(f.deletes, 0);
    });
  }

  for (final dark in [false, true]) {
    final scale = dark ? 2.0 : 1.0;
    testWidgets('手机删除确认可取消和执行 ${dark ? '深色200%' : '浅色100%'}', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = _DeleteFixture();
      await tester.runAsync(f.init);
      addTearDown(f.close);
      await tester.runAsync(loadFonts);
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: UploadHistoryPage(queue: f.queue))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除手机录音'));
      await tester.tap(find.text('删除手机录音'));
      await tester.pumpAndSettle();
      expect(find.text('删除这段手机录音？'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester
          .runAsync(() => _capture(capture, 'phone-delete-dialog-$scale'));
      await tester.tap(find.text('保留录音'));
      await tester.pumpAndSettle();
      expect(f.deletes, 0);
      expect(await tester.runAsync(f.file.exists), true);
      await tester.tap(find.text('删除手机录音'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除录音'));
      await tester.pump();
      await _pumpUntil(tester,
          () => f.queue.items.single.status == UploadStatus.deleted);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(f.file.exists), false);
      expect(f.deletes, 1);
      expect(find.text('删除手机录音'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester
          .runAsync(() => _capture(capture, 'phone-delete-complete-$scale'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('正在上传的手机录音删除入口禁用', (tester) async {
    final f = _DeleteFixture();
    await tester.runAsync(f.init);
    addTearDown(f.close);
    f.queue.items.single.status = UploadStatus.uploading;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body:
                UploadRecordCard(item: f.queue.items.single, queue: f.queue))));
    await tester.pump();
    final action = find.ancestor(
        of: find.text('删除手机录音'),
        matching: find.byWidgetPredicate((widget) => widget is TextButton));
    expect(action, findsOneWidget);
    expect(tester.widget<TextButton>(action).onPressed, isNull);
    expect(f.deletes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failDiscard in [false, true]) {
    testWidgets(
        '当前录音停止并删除${failDiscard ? '失败后保留待删除文件且不上传' : '确认前继续录音、确认后只删除捕获的会话'}',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = _DeleteFixture();
      await tester.runAsync(() => f.init(seed: false));
      addTearDown(f.close);
      final bridge = _ActiveRecording(f.file);
      const channel = MethodChannel(AppConstants.channelAudioRecorder);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call);
        if (call.method != 'discardRecording') {
          throw MissingPluginException('unexpected ${call.method}');
        }
        bridge.active = false;
        bridge.discardRequested = true;
        if (failDiscard) {
          throw PlatformException(
              code: 'RECORDING_DELETE_FAILED', message: '模拟文件暂时无法删除');
        }
        f.file.deleteSync();
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.runAsync(loadFonts);
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.darkTheme,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!),
              home: RecordingPage(
                  recordingBridge: bridge, uploadQueue: f.queue))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('停止并删除'));
      await tester
          .runAsync(() => _capture(capture, 'phone-active-recording-2.0'));
      await tester.tap(find.text('停止并删除'));
      await tester.pumpAndSettle();
      expect(find.text('停止并删除这次录音？'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.runAsync(
          () => _capture(capture, 'phone-discard-session-dialog-2.0'));
      await tester.tap(find.text('继续录音'));
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () {
        final button = find.ancestor(
            of: find.text('停止并删除'),
            matching: find.byWidgetPredicate((widget) => widget is TextButton));
        return tester.widget<TextButton>(button).onPressed != null;
      });
      expect(bridge.active, true);
      expect(f.file.existsSync(), true);
      expect(calls, isEmpty);
      await tester.ensureVisible(find.text('停止并删除'));
      await tester.tap(find.text('停止并删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止并删除').last);
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () => calls.isNotEmpty);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'discardRecording');
      expect(calls.single.arguments, {'sessionId': bridge.sessionId});
      expect(bridge.active, false);
      if (failDiscard) {
        await _pumpUntil(tester, () => f.queue.items.isNotEmpty);
        expect(f.file.existsSync(), true);
        expect(f.queue.items.single.status, UploadStatus.deleting);
        expect(f.queue.items.single.retryable, false);
        await tester.runAsync(f.queue.retryWhenConnected);
        await tester.runAsync(f.queue.processNext);
        expect(f.requests, isEmpty);
      } else {
        expect(f.file.existsSync(), false);
        expect(f.queue.items, isEmpty);
        expect(f.requests, isEmpty);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
