import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/api_result.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/asr/asr_job_card.dart';
import 'package:class_notes_assistant/features/recording/recent_records.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TaskApi extends ApiClient {
  TaskApi() : super(baseUrl: 'http://task-test.invalid');
  int cancellations = 0, deletions = 0, recordingsDeleted = 0;
  Completer<ApiResult<Map<String, dynamic>>>? pending;
  bool fail = false;
  @override
  Future<ApiResult<Map<String, dynamic>>> cancelAsrJob(String id) async {
    cancellations++;
    if (pending != null) return await pending!.future;
    return ApiResult.ok({...task('cancelling'), 'can_cancel': false});
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> retryAsrJob(String id) async =>
      ApiResult.ok({...task('queued'), 'can_retry': false, 'can_cancel': true});
  @override
  Future<ApiResult<Map<String, dynamic>>> deleteAsrJob(String id) async {
    deletions++;
    return fail
        ? const ApiResult.failed('删除失败，任务仍保留')
        : ApiResult.ok({'id': id, 'status': 'deleted'});
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> deleteAsrRecording(String id) async {
    recordingsDeleted++;
    return ApiResult.ok({
      ...task('failed'),
      'result': {'source_deleted': true, 'source_note': '电脑源录音已删除'},
      'can_delete_recording': false,
      'can_retry': false
    });
  }
}

Map<String, dynamic> task(String status) => {
      'id': 'one',
      'source_name': '工程力学.m4a',
      'status': status,
      'result': <String, dynamic>{},
    };

class Requests implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<dynamic>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
        jsonEncode({'code': 0, 'data': options.method == 'GET' ? [] : {}}), 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
      'recent records sort real creation timestamps and preserve unknown order',
      () {
    final input = [
      {'id': 'unknown-a'},
      {'id': 'old', 'created_at': '2026-10-29T12:00:00'},
      {'id': 'new', 'created_at': '2026-10-31T12:00:00'},
      {'id': 'unknown-b'},
    ];
    expect(newestRecords(input).map((r) => r['id']),
        ['new', 'old', 'unknown-a', 'unknown-b']);
    expect(input.first['id'], 'unknown-a');
  });

  test(
      'upload timestamps round trip and old receipts retain reverse queue order',
      () {
    UploadItem upload(String id, {DateTime? date}) => UploadItem(
        id: id,
        filePath: '$id.m4a',
        courseId: 'course',
        lesson: 1,
        classDate: '2026-01-01',
        createdAt: date);
    final oldA = upload('legacy-a'), oldB = upload('legacy-b');
    final added = upload('new', date: DateTime.utc(2026, 10, 31));
    expect(UploadItem.fromJson(added.toJson()).createdAt, added.createdAt);
    expect(UploadItem.fromJson(oldA.toJson()).createdAt, isNull);
    expect(newestUploads([oldA, oldB, added]).map((e) => e.id),
        ['new', 'legacy-b', 'legacy-a']);
  });

  test(
      'task API keeps existing list endpoint and sends explicit full-history/delete verbs',
      () async {
    final api = ApiClient(baseUrl: 'http://task-test.invalid');
    final requests = Requests();
    api.dio.httpClientAdapter = requests;
    await api.getAsrJobs();
    await api.getAllAsrJobs();
    await api.cancelAsrJob('task/id #');
    await api.deleteAsrJob('task/id #');
    await api.deleteAsrRecording('task/id #');
    expect(requests.requests.map((r) => r.method),
        ['GET', 'GET', 'POST', 'DELETE', 'DELETE']);
    expect(requests.requests[0].queryParameters, isEmpty);
    expect(requests.requests[1].queryParameters, {'all': true});
    expect(requests.requests[2].path, '/api/asr/jobs/task%2Fid%20%23/cancel');
    expect(
        requests.requests.last.path, '/api/asr/jobs/task%2Fid%20%23/recording');
  });

  testWidgets(
      'accepted cancellation survives stale running poll and advances to cancelled',
      (tester) async {
    final api = TaskApi();
    final current = ValueNotifier(task('running'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
                valueListenable: current,
                builder: (_, job, __) => AsrJobCard(
                    key: const ValueKey('one'), job: job, apiClient: api)))));
    await tester.tap(find.text('取消转写'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, '取消转写').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.cancellations, 1);
    expect(find.text('正在取消，等待识别进程停止'), findsOneWidget);
    current.value = {...task('running')};
    await tester.pump();
    expect(find.text('正在取消，等待识别进程停止'), findsOneWidget);
    expect(find.text('取消转写'), findsNothing);
    current.value = {...task('cancelled')};
    await tester.pump();
    expect(find.text('已取消转写'), findsOneWidget);
    expect(find.text('手动重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    current.dispose();
  });

  testWidgets('delete failure retains task and exposes error', (tester) async {
    final api = TaskApi()..fail = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AsrJobCard(job: task('failed'), apiClient: api))));
    await tester.tap(find.text('删除任务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, '删除任务').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.deletions, 1);
    expect(find.text('工程力学.m4a'), findsOneWidget);
    expect(find.text('删除失败，任务仍保留'), findsOneWidget);
  });

  testWidgets(
      'recording deletion confirms scope and stale poll cannot restore retry',
      (tester) async {
    final api = TaskApi();
    final current = ValueNotifier(task('failed'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
                valueListenable: current,
                builder: (_, job, __) => AsrJobCard(
                    key: const ValueKey('one'), job: job, apiClient: api)))));
    await tester.tap(find.text('删除电脑录音'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('微力同步'), findsOneWidget);
    expect(find.textContaining('保留转写文本和台账'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除电脑录音').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.recordingsDeleted, 1);
    current.value = {...task('failed')};
    await tester.pump();
    expect(find.text('手动重试'), findsNothing);
    expect(find.text('删除电脑录音'), findsNothing);
    expect(find.text('电脑源录音已删除'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    current.dispose();
  });
  for (final resumed in ['queued', 'running']) {
    testWidgets(
        'fresh revision accepts another device $resumed after cancellation',
        (tester) async {
      final api = TaskApi();
      final current = ValueNotifier((task('running'), 1));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ValueListenableBuilder(
                  valueListenable: current,
                  builder: (_, value, __) => AsrJobCard(
                      key: const ValueKey('one'),
                      job: value.$1,
                      snapshotRevision: value.$2,
                      apiClient: api)))));
      await tester.tap(find.text('取消转写'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(TextButton, '取消转写').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      current.value = (task(resumed), 1);
      await tester.pump();
      expect(find.text('正在取消，等待识别进程停止'), findsOneWidget);
      current.value = (task(resumed), 2);
      await tester.pump();
      expect(find.text(resumed == 'queued' ? '等待转写' : '正在转写'), findsWidgets);
      expect(find.text('正在取消，等待识别进程停止'), findsNothing);
      expect(find.text('正在停止转写，录音保留'), findsNothing);
      expect(find.text('取消转写'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      current.dispose();
    });
  }
  for (final state in ['failed', 'cancelled']) {
    testWidgets('fresh revision accepts another device $state after retry',
        (tester) async {
      final api = TaskApi();
      final current = ValueNotifier((task('failed'), 1));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ValueListenableBuilder(
                  valueListenable: current,
                  builder: (_, value, __) => AsrJobCard(
                      key: const ValueKey('one'),
                      job: value.$1,
                      snapshotRevision: value.$2,
                      apiClient: api)))));
      await tester.tap(find.text('手动重试'));
      await tester.pump();
      current.value = (task(state), 1);
      await tester.pump();
      expect(find.text('等待转写'), findsOneWidget);
      current.value = (task(state), 2);
      await tester.pump();
      expect(find.text(state == 'failed' ? '转写失败' : '已取消转写'), findsOneWidget);
      expect(find.text('已重新加入转写队列'), findsNothing);
      expect(find.text('手动重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      current.dispose();
    });
  }
  testWidgets(
      'post-action refresh floor rejects older snapshot even when revision increased',
      (tester) async {
    final api = TaskApi();
    final current = ValueNotifier((task('running'), 1));
    final freshRead = Completer<int>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
                valueListenable: current,
                builder: (_, value, __) => AsrJobCard(
                    key: const ValueKey('one'),
                    job: value.$1,
                    snapshotRevision: value.$2,
                    apiClient: api,
                    refreshSnapshot: () => freshRead.future)))));
    await tester.tap(find.text('取消转写'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, '取消转写').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    current.value = (task('running'), 2);
    await tester.pump();
    expect(find.text('正在取消，等待识别进程停止'), findsOneWidget);
    freshRead.complete(3);
    await tester.pump();
    expect(find.text('正在取消，等待识别进程停止'), findsOneWidget);
    current.value = (task('queued'), 4);
    await tester.pump();
    expect(find.text('等待转写'), findsOneWidget);
    expect(find.text('正在停止转写，录音保留'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    current.dispose();
  });
}
