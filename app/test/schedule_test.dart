import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/features/schedule/timetable_layout.dart';
import 'note_rendering_test.dart' show loadFonts;

Map<String, dynamic> entry(
        {String start = '14:15',
        String end = '15:50',
        List<int> weeks = const [6]}) =>
    {
      'id': 'a',
      'course_id': 'course',
      'course_name': '线性代数',
      'weekday': 4,
      'period': 3,
      'start_time': start,
      'end_time': end,
      'weeks': weeks,
      'confirmed': true,
      'location': '教学楼3-408',
    };
ApiClient mockApi(List<Map<String, dynamic>> entries, {bool failure = false}) {
  final api = ApiClient(baseUrl: 'http://schedule.test');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (failure) {
      handler.reject(DioException(
          requestOptions: options, type: DioExceptionType.connectionError));
      return;
    }
    handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
      'code': 0,
      'data': options.path == '/api/schedule'
          ? entries
          : (Platform.environment['CNA_COURSES_SNAPSHOT'] == null
              ? <Map<String, dynamic>>[]
              : jsonDecode(File(Platform.environment['CNA_COURSES_SNAPSHOT']!)
                  .readAsStringSync()
                  .replaceFirst('\uFEFF', ''))['data']),
      'message': 'ok'
    }));
  }));
  return api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('真实时间定位下午小节；冲突课程都保留，未知时间可单独查看', () {
    final afternoon = layoutDay([entry()]).single;
    expect(afternoon.top, 4);
    expect(afternoon.bottom, 6); // 第5–6小节，而非第3小节
    final overlap = layoutDay([entry(), entry(start: '15:05', end: '16:45')]);
    expect(overlap.length, 2);
    expect(overlap.every((e) => e.laneCount == 2), isTrue);
    expect(overlap.map((e) => e.lane).toSet().length, 2);
    expect(fitsGrid(entry(start: '22:00', end: '23:00')), isFalse);
    expect(fitsGrid(entry(start: '待定')), isFalse);
  });
  test('第6周停课、单双周与周一边界', () {
    expect(teachingWeek(DateTime(2026, 10, 9), DateTime(2026, 8, 31)), 6);
    expect(teachingWeek(DateTime(2026, 10, 12), DateTime(2026, 8, 31)), 7);
    expect(appearsInWeek(entry(weeks: [1, 3, 5, 7]), 6), isFalse);
    expect(appearsInWeek(entry(weeks: [1, 2, 3, 4, 5, 7, 8, 9]), 6), isFalse);
    expect(appearsInWeek(entry(weeks: [1, 2, 3, 4, 5, 7, 8, 9]), 7), isTrue);
    expect(appearsInWeek({...entry(), 'confirmed': false}, 6), isFalse);
  });
  test('断网保留缓存及新的学期设置；首次断网明确失败', () async {
    SharedPreferences.setMockInitialValues({});
    final online = mockApi([entry()]);
    final saved = await ScheduleStore.load(online);
    expect(saved.entries.length, 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cna_widget_term_label', '新学期');
    final offline = mockApi([], failure: true);
    final cached = await ScheduleStore.load(offline);
    expect(cached.offline, isTrue);
    expect(cached.entries.single['course_name'], '线性代数');
    expect(cached.termLabel, '新学期');
    await prefs.remove(ScheduleStore.cacheKey);
    await expectLater(ScheduleStore.load(offline), throwsStateError);
    online.dio.close();
    offline.dio.close();
  });
  testWidgets('课表缓存先显示，不等待断网超时', (tester) async {
    await tester.runAsync(loadFonts);
    final cached = ScheduleSnapshot(
        entries: [entry()],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 8),
        termLabel: '大二上');
    SharedPreferences.setMockInitialValues(
        {ScheduleStore.cacheKey: jsonEncode(cached.toJson())});
    final pending = <void Function()>[];
    final api = ApiClient(baseUrl: 'http://offline.test');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path != '/api/schedule/snapshot') {
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.connectionError));
        return;
      }
      pending.add(() => handler.reject(DioException(
          requestOptions: options, type: DioExceptionType.connectionError)));
    }));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: SchedulePage(
            apiClient: api, referenceDate: DateTime(2026, 10, 8))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.textContaining('离线课表'), findsOneWidget);
    expect(
        pending.length, 1); // the new combined snapshot replaces two requests
    for (final reject in pending) {
      reject();
    }
    await tester.pumpAndSettle();
    expect(find.text('线性代数'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
  testWidgets('右键调课显示实际日期并只提交所点日期', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    await tester.runAsync(loadFonts);
    final entries = <Map<String, dynamic>>[
      {
        ...entry(start: '08:15', end: '09:50', weeks: [6, 7]),
        'weekday': 5
      }
    ];
    Map<String, dynamic>? submitted;
    final api = ApiClient(baseUrl: 'http://schedule.test');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path.endsWith('/reschedule')) {
        submitted = (options.data as Map).cast<String, dynamic>();
        entries
          ..clear()
          ..add({
            ...entry(start: '08:15', end: '09:50', weeks: [7]),
            'weekday': 5
          })
          ..add({
            ...entry(start: '08:15', end: '09:50', weeks: [7]),
            'weekday': 3,
            'id': 'moved'
          });
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'code': 0, 'data': entries.last, 'message': 'ok'}));
        return;
      }
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'code': 0,
        'data': options.path == '/api/schedule'
            ? entries
            : <Map<String, dynamic>>[],
        'message': 'ok'
      }));
    }));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: SchedulePage(
            apiClient: api, referenceDate: DateTime(2026, 10, 9))));
    await tester.pumpAndSettle();
    final point = tester.getCenter(find.text('线性代数').first);
    final gesture = await tester.startGesture(point,
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('调课到…'), findsOneWidget);
    await tester.tap(find.text('调课到…'));
    await tester.pumpAndSettle();
    expect(find.text('线性代数 · 2026年10月9日'), findsOneWidget);
    await tester.tap(find.textContaining('第 6 周 · 10月5日'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('第 7 周 · 10月12日').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('周三 · 2026年10月14日'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认调课'));
    await tester.pumpAndSettle();
    expect(submitted, {
      'semester_start': '2026-08-31',
      'source_date': '2026-10-09',
      'target_date': '2026-10-14',
    });
    expect(find.text('第 7 周 · 周五'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
  final snapshotPath = Platform.environment['CNA_SCHEDULE_SNAPSHOT'];
  if (snapshotPath == null) return;
  final raw = jsonDecode(
      File(snapshotPath).readAsStringSync().replaceFirst('\uFEFF', '')) as Map;
  final actual = (raw['data'] as List).cast<Map<String, dynamic>>();
  test('38条实际课表按周过滤且全部有网格位置', () {
    expect(actual.length, 38);
    expect(actual.every(fitsGrid), isTrue);
    final physics = actual
        .where(
            (e) => '${e['course_name']}'.contains('普通物理') && e['weekday'] == 3)
        .toList();
    expect(physics, isNotEmpty);
    expect(physics.any((e) => appearsInWeek(e, 6)), isFalse);
    final visible = actual.where((e) => appearsInWeek(e, 6)).toList();
    expect(
        List.generate(
                7,
                (day) =>
                    layoutDay(visible.where((e) => e['weekday'] == day + 1)))
            .expand((e) => e)
            .length,
        visible.length);
  });
  for (final config in [
    (390.0, 1.0, false),
    (1200.0, 1.0, false),
    (390.0, 2.0, true)
  ]) {
    testWidgets('真实整周课表 ${config.$1} 字号${config.$2}', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'cna_semester_start': '2026-08-31'});
      tester.view.physicalSize = Size(config.$1, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(loadFonts);
      final api = mockApi(actual);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: config.$3 ? AppTheme.darkTheme : AppTheme.lightTheme,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(config.$2)),
                  child: child!),
              home: SchedulePage(
                  apiClient: api, referenceDate: DateTime(2026, 10, 9)))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('第 6 周 · 周五'), findsOneWidget);
      final output = Platform.environment['CNA_UI_OUTPUT'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$output/课表-${config.$1.toInt()}-${config.$2.toInt()}x.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
      }
      if (config.$2 == 1) {
        final name = actual
            .firstWhere(
                (e) => e['weekday'] == 5 && appearsInWeek(e, 6))['course_name']
            .toString();
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
        expect(find.text('这门课自动录音'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一周'));
        await tester.pumpAndSettle();
        expect(find.text('第 7 周 · 周五'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
    });
  }
}
