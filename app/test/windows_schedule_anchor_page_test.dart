import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:class_notes_assistant/features/schedule/timetable_layout.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

Finder _course(String id) =>
    find.byKey(ValueKey<String>('schedule-anchor-course-$id'));

Future<void> _mount(WidgetTester tester, ApiClient api,
    {double width = 1200,
    double scale = 1,
    bool dark = false,
    GlobalKey? captureKey}) async {
  SharedPreferences.setMockInitialValues({'cna_semester_start': '2026-08-31'});
  tester.view.physicalSize = Size(width, scale > 1 ? 1040 : 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: SchedulePage(
              apiClient: api, referenceDate: DateTime(2026, 10, 9)))));
  await tester.pumpAndSettle();
  expect(find.byType(ScheduleAnchorView), findsOneWidget);
  await tester.tap(find.text('当天'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final output = Platform.environment['CNA_UI_OUTPUT'];
  if (output == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(output).createSync(recursive: true);
    File('$output/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows真课表页当天到整周保留同一课程和详情，反向从当前矩形续行', (tester) async {
    final api = mockApi([
      {
        ...entry(start: '08:15', end: '09:50', weeks: [6, 7]),
        'id': 'anchor-a',
        'weekday': 5,
        'course_name': '工程力学'
      },
      {
        ...entry(start: '10:05', end: '11:40', weeks: [6, 7]),
        'id': 'anchor-b',
        'weekday': 5,
        'course_name': '线性代数'
      },
      {
        ...entry(weeks: [6, 7]),
        'id': 'other',
        'weekday': 3
      }
    ]);
    await _mount(tester, api);
    final card = _course('anchor-a');
    expect(card, findsOneWidget);
    final state =
        tester.state<ScheduleAnchorViewState>(find.byType(ScheduleAnchorView));
    expect(state.debugProgress, 0);
    final element = tester.element(card);
    final start = tester.getRect(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('课程详情'), findsOneWidget);
    final detail = find.byKey(const ValueKey('schedule-floating-details'));
    final detailStart = tester.getRect(detail);
    await tester.tap(find.text('整周'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));
    final middle = tester.getRect(card);
    final middleProgress = state.debugProgress;
    expect(middleProgress, inExclusiveRange(0, 1));
    expect(tester.element(card), same(element));
    expect((middle.width - start.width).abs(), greaterThan(1));
    expect(tester.getRect(detail), detailStart);
    await tester.tap(find.text('当天'));
    await tester.pump();
    expect(state.debugProgress, middleProgress);
    expect(tester.getRect(card), middle, reason: '反向命令当前帧不能重置课程几何');
    await tester.pump(const Duration(milliseconds: 36));
    final reversing = tester.getRect(card);
    expect(reversing.width, isNot(start.width), reason: '反向是持续动画，不能直接硬切回当天');
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(tester.element(card), same(element));
    expect(tester.getRect(card), start);
    expect(tester.getRect(detail), detailStart);
    await tester.tap(find.text('整周'));
    await tester.pumpAndSettle();
    final end = tester.getRect(card);
    expect(state.debugProgress, 1);
    expect(end.width, lessThan(start.width));
    expect(middle.width, greaterThan(end.width));
    expect(tester.element(card), same(element));
    expect(tester.getRect(detail), detailStart);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  testWidgets('Windows整周转场后下一周数据与右键真实日期调课入口仍可用', (tester) async {
    final api = mockApi([
      {
        ...entry(start: '08:15', end: '09:50', weeks: [6]),
        'id': 'week6',
        'weekday': 5,
        'course_name': '本周工程力学'
      },
      {
        ...entry(start: '10:05', end: '11:40', weeks: [7]),
        'id': 'week7',
        'weekday': 5,
        'course_name': '下周线性代数'
      }
    ]);
    await _mount(tester, api);
    await tester.tap(find.text('整周'));
    await tester.pumpAndSettle();
    expect(_course('week6'), findsOneWidget);
    expect(_course('week7'), findsNothing);
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    expect(find.text('第 7 周 · 周五'), findsOneWidget);
    expect(_course('week6'), findsNothing);
    expect(_course('week7'), findsOneWidget);
    final gesture = await tester.startGesture(
        tester.getCenter(_course('week7')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('调课到…'), findsOneWidget);
    await tester.tap(find.text('调课到…'));
    await tester.pumpAndSettle();
    expect(find.text('下周线性代数 · 2026年10月16日'), findsOneWidget);
    await tester.tap(find.text('周三 · 2026年10月14日'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '确认调课'), findsOneWidget);
    expect(
        find.textContaining('2026年10月16日 调到第 7 周 2026年10月14日'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_course('week7'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  final snapshot = Platform.environment['CNA_SCHEDULE_SNAPSHOT'];
  if (snapshot == null) return;
  final raw =
      jsonDecode(File(snapshot).readAsStringSync().replaceFirst('\uFEFF', ''))
          as Map;
  final actual = (raw['data'] as List).cast<Map<String, dynamic>>();
  for (final config in [
    (1200.0, 1.0, false),
    (680.0, 1.0, false),
    (1200.0, 2.0, true),
    (680.0, 2.0, true)
  ]) {
    testWidgets('正式字体Windows课表控件帧 ${config.$1} ${config.$2}x', (tester) async {
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = shadows);
      final api = mockApi(actual);
      final key = GlobalKey();
      await _mount(tester, api,
          width: config.$1, scale: config.$2, dark: config.$3, captureKey: key);
      final selected =
          actual.firstWhere((e) => e['weekday'] == 5 && appearsInWeek(e, 6));
      final card = _course('${selected['id']}');
      expect(card, findsOneWidget);
      if (config.$1 >= 850) {
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.text('课程详情'), findsOneWidget);
      }
      final prefix =
          'schedule-page-${config.$1.toInt()}-${config.$2.toInt()}x-${config.$3 ? 'dark' : 'light'}';
      await _capture(tester, key, '$prefix-start');
      await tester.tap(find.text('整周'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 122));
      await _capture(tester, key, '$prefix-quarter');
      await tester.pump(const Duration(milliseconds: 123));
      await _capture(tester, key, '$prefix-middle');
      await tester.pumpAndSettle();
      await _capture(tester, key, '$prefix-end');
      await tester.tap(find.text('当天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 245));
      await _capture(tester, key, '$prefix-return');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(card, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
      debugDisableShadows = shadows;
    });
  }
}
