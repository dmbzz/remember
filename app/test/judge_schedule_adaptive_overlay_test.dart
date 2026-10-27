import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];

final _shell = find.byKey(const ValueKey('touch-orientation-capsule'));
Finder _course(String id) => find.byKey(ValueKey('schedule-anchor-course-$id'));

Future<void> _mount(WidgetTester tester,
    {required Widget content,
    required Size size,
    GlobalKey? boundary,
    bool dark = false,
    double scale = 1}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme)
              .copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: StudyNavigationLayout(
              content: content,
              destinations: _destinations,
              selectedIndex: 0,
              onSelected: (_) {}))));
  await tester.pumpAndSettle();
}

Future<void> _capture(
    WidgetTester tester, GlobalKey boundary, String name) async {
  await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

ApiClient _api() => mockApi([
      {
        ...entry(start: '08:15', end: '09:50'),
        'id': 'anchor',
        'weekday': 5,
        'course_name': '工程力学课程锚点',
      },
      {
        ...entry(start: '10:05', end: '11:40'),
        'id': 'later',
        'weekday': 5,
        'course_name': '线性代数课程',
      },
      {
        ...entry(start: '08:15', end: '09:50'),
        'id': 'monday',
        'weekday': 1,
        'course_name': '普通物理课程',
      },
      {
        ...entry(start: '10:05', end: '11:40'),
        'id': 'wednesday',
        'weekday': 3,
        'course_name': '电工电子课程',
      },
    ]);

ScheduleAnchorViewState _anchorState(WidgetTester tester) =>
    tester.state<ScheduleAnchorViewState>(find.byType(ScheduleAnchorView));

void main() {
  testWidgets('独立生命周期：仅resize重排时隐藏页面也须结束旧动画', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(760, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: StatefulBuilder(builder: (context, set) {
          update = set;
          return TickerMode(
              enabled: visible,
              child: ScheduleAnchorView(
                  entries: [
                    {...entry(), 'id': 'lifecycle', 'weekday': 5}
                  ],
                  weekStart: DateTime(2026, 10, 5),
                  today: DateTime(2026, 10, 9),
                  selectedDay: 5,
                  dayMode: true,
                  onSelectDay: (_) {},
                  onOpen: (_) {}));
        })));
    await tester.pumpAndSettle();
    final state = _anchorState(tester);
    expect(state.debugIsAnimating, isFalse);
    tester.view.physicalSize = const Size(600, 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.debugIsAnimating, isTrue);
    expect(state.debugProgress, 0);
    update(() => visible = false);
    await tester.pump();
    expect(state.debugIsAnimating, isFalse,
        reason: '仅_reflow运行时也要遵守隐藏页停止旧运动的既有行为');
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立整页：跨850详情断点当前帧课程几何保持且490ms到达', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    final api = _api();
    final boundary = GlobalKey();
    await _mount(tester,
        content:
            SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
        size: const Size(851, 900),
        boundary: boundary);
    final state = _anchorState(tester);
    final element = tester.element(_course('anchor'));
    expect(state.debugProgress, 1);
    final before = state.debugCourseRects['anchor']!;
    await _capture(tester, boundary, 'breakpoint-wide-before');
    tester.view.physicalSize = const Size(849, 900);
    await tester.pump();
    final first = state.debugCourseRects['anchor']!;
    await _capture(tester, boundary, 'breakpoint-narrow-first');
    expect(first.left, closeTo(before.left, .05),
        reason: '详情栏删除与mode retarget同帧不可丢失旧viewport几何');
    expect(first.width, closeTo(before.width, .05));
    expect(state.debugProgress, 1);
    await tester.pump(const Duration(milliseconds: 245));
    await _capture(tester, boundary, 'breakpoint-narrow-middle');
    expect(state.debugProgress, inExclusiveRange(0, 1));
    expect(tester.element(_course('anchor')), same(element));
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    await _capture(tester, boundary, 'breakpoint-narrow-end');
    final narrow = state.debugCourseRects['anchor']!;
    tester.view.physicalSize = const Size(851, 900);
    await tester.pump();
    expect(state.debugCourseRects['anchor']!.left, closeTo(narrow.left, .05));
    expect(state.debugCourseRects['anchor']!.width, closeTo(narrow.width, .05));
    await tester.pump(const Duration(milliseconds: 245));
    await _capture(tester, boundary, 'breakpoint-wide-return-middle');
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(tester.element(_course('anchor')), same(element));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  testWidgets('独立整页：手选仅当前widthband有效并保留所选星期', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    final api = _api();
    await _mount(tester,
        content:
            SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
        size: const Size(1200, 900));
    final state = _anchorState(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-anchor-day-3')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ScheduleAnchorView>(find.byType(ScheduleAnchorView))
            .selectedDay,
        3);
    await tester.tap(find.text('当天'));
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    tester.view.physicalSize = const Size(849, 900);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    await tester.tap(find.text('整周'));
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    tester.view.physicalSize = const Size(800, 900);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    tester.view.physicalSize = const Size(851, 900);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    tester.view.physicalSize = const Size(849, 900);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(
        tester
            .widget<ScheduleAnchorView>(find.byType(ScheduleAnchorView))
            .selectedDay,
        3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  testWidgets('独立Dock：左侧外部显示真实背景并可点击，壳内空白不可穿透', (tester) async {
    var taps = 0;
    final boundary = GlobalKey();
    const background = Color(0xff274c73);
    await _mount(tester,
        content: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child:
                const ColoredBox(color: background, child: SizedBox.expand())),
        size: const Size(1200, 900),
        boundary: boundary);
    final shell = tester.getRect(_shell);
    final point = Offset(3, shell.center.dy);
    expect(shell.contains(point), isFalse);
    await tester.tapAt(point);
    await tester.pump();
    expect(taps, 1, reason: 'Dock左侧外部必须命中页面而非保留的空slot');
    await tester.tapAt(shell.topLeft + const Offset(1, 1));
    await tester.pump();
    expect(taps, 2, reason: '圆角透明部分也属于页面');
    await tester.tapAt(shell.bottomCenter - const Offset(0, 8));
    await tester.pump();
    expect(taps, 2, reason: '壳内部空白必须属于Dock');
    await tester.runAsync(() async {
      final image = await (boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      expect(data!.getUint8(offset), 0x27);
      expect(data.getUint8(offset + 1), 0x4c);
      expect(data.getUint8(offset + 2), 0x73);
      image.dispose();
    });
    await _capture(tester, boundary, 'dock-real-background');
    final icon = find.descendant(
        of: find.byKey(const ValueKey('capsule-item-0')),
        matching: find.byType(Icon));
    final iconBefore = tester.getCenter(icon);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 100));
    await mouse.moveTo(shell.center);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    expect(tester.getRect(_shell).width, greaterThan(shell.width));
    expect((tester.getCenter(icon) - iconBefore).distance, lessThan(.01));
    await _capture(tester, boundary, 'dock-real-background-hover');
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立整页：跨900和850连续快速反向不改变命令帧全局课程矩形', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    final api = _api();
    final boundary = GlobalKey();
    await _mount(tester,
        content:
            SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
        size: const Size(1000, 900),
        boundary: boundary);
    final state = _anchorState(tester);
    final element = tester.element(_course('anchor'));
    for (final width in [840.0, 1000.0, 830.0, 1000.0, 840.0]) {
      final rect = tester.getRect(_course('anchor'));
      final p = state.debugProgress;
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();
      final next = tester.getRect(_course('anchor'));
      expect((next.topLeft - rect.topLeft).distance, lessThan(.05),
          reason: '跨导航和详情断点命令帧需保留全局位置 width=$width');
      expect(next.width, closeTo(rect.width, .05));
      expect(state.debugProgress, closeTo(p, 1e-9));
      expect(tester.element(_course('anchor')), same(element));
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(
          tester, boundary, 'rapid-${width.toInt()}-${p.toStringAsFixed(2)}');
    }
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  testWidgets('独立整页：窗口导航联动490ms模式终态与尺寸重排余程帧', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    final api = _api();
    final boundary = GlobalKey();
    await _mount(tester,
        content:
            SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
        size: const Size(1000, 900),
        boundary: boundary);
    final state = _anchorState(tester);
    tester.view.physicalSize = const Size(840, 900);
    await tester.pump();
    await tester.pump();
    var previous = 0;
    final observations = <String>[];
    for (final elapsed in [0, 245, 440, 490, 506, 735, 930]) {
      while (previous < elapsed) {
        final step = (elapsed - previous).clamp(1, 16);
        await tester.pump(Duration(milliseconds: step));
        previous += step;
      }
      await _capture(tester, boundary, 'resize-timeline-$elapsed');
      observations.add('$elapsed ms p=${state.debugProgress} '
          'animating=${state.debugIsAnimating} '
          'rect=${tester.getRect(_course('anchor'))}');
      File('../review-frames/resize-timeline.txt')
          .writeAsStringSync(observations.join('\n'));
      if (elapsed >= 490) expect(state.debugProgress, 0);
      if (elapsed >= 506) {
        expect(state.debugIsAnimating, isFalse,
            reason: '490ms模式过渡加一帧提交后不得还有额外整段尺寸重排');
        final rect = tester.getRect(_course('anchor'));
        expect(rect.left, closeTo(18, .05));
        expect(rect.width, closeTo(840 - 36, .05));
      }
    }
    File('../review-frames/resize-timeline.txt')
        .writeAsStringSync(observations.join('\n'));
    await tester.pumpAndSettle();
    expect(state.debugIsAnimating, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  for (final config in [
    (const Size(1200, 900), 1.0, false),
    (const Size(1000, 700), 1.0, false),
    (const Size(1000, 400), 1.0, false),
    (const Size(1200, 1040), 2.0, true),
  ]) {
    testWidgets('独立整页视觉帧 ${config.$1} ${config.$2}x', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'cna_semester_start': '2026-08-31'});
      final api = _api();
      final boundary = GlobalKey();
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = shadows);
      await _mount(tester,
          content: SchedulePage(
              apiClient: api, referenceDate: DateTime(2026, 10, 9)),
          size: config.$1,
          scale: config.$2,
          dark: config.$3,
          boundary: boundary);
      final prefix =
          'whole-${config.$1.width.toInt()}-${config.$1.height.toInt()}-${config.$2.toInt()}x';
      await _capture(tester, boundary, '$prefix-wide');
      final h = find
          .descendant(
              of: find.byKey(const ValueKey('schedule-anchor-horizontal')),
              matching: find.byType(Scrollable))
          .first;
      tester.state<ScrollableState>(h).position.jumpTo(0);
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '$prefix-week-left');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 100));
      await mouse.moveTo(tester.getCenter(_shell));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '$prefix-week-hover');
      await mouse.removePointer();
      await tester.tap(find.text('当天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 245));
      await _capture(tester, boundary, '$prefix-day-middle');
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '$prefix-day-end');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
      debugDisableShadows = shadows;
    });
  }

  testWidgets('独立笔记：实际筛选与检索入口的Dock叠层帧', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(baseUrl: 'http://independent-notes.test');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (req, handler) {
      handler.resolve(Response(requestOptions: req, statusCode: 200, data: {
        'code': 0,
        'data': {
          'items': List.generate(
              20,
              (i) => {
                    'note_id': 'review-note-$i',
                    'topic': '平面一般力系课堂笔记 $i',
                    'course_name': i.isEven ? '工程力学' : '线性代数',
                    'class_date': '2026-10-15',
                  }),
          'total': 20,
        },
        'message': 'ok',
      }));
    }));
    final boundary = GlobalKey();
    await _mount(tester,
        content: NotesPage(apiClient: api),
        size: const Size(1000, 700),
        boundary: boundary);
    await _capture(tester, boundary, 'notes-1000-closed');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 100));
    await mouse.moveTo(tester.getCenter(_shell));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'notes-1000-hover');
    final all = tester.getRect(find.text('全部'));
    final search = tester.getRect(find.byType(TextField));
    final shell = tester.getRect(_shell);
    expect(search.left, closeTo(100, .01),
        reason: '页面按自身840最大宽居中，不能因Dock再留左侧占位');
    File('../review-frames/notes-1000-control-geometry.txt')
        .writeAsStringSync('shell=$shell\nallLabel=$all\nsearch=$search\n');
    await mouse.moveTo(const Offset(700, 100));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工程力学'));
    await tester.pumpAndSettle();
    expect(find.text('最近笔记 · 10'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('最近笔记 · 20'), findsOneWidget);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
