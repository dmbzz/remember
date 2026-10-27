import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/course_palette.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

const _boundary = ValueKey('judge-week-fit-root');
Finder _key(String value) => find.byKey(ValueKey(value), skipOffstage: false);
Finder get _shell => _key('touch-orientation-capsule');
const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];
final _entries = <Map<String, dynamic>>[
  for (var day = 1; day <= 7; day++)
    {
      ...entry(start: '08:15', end: '09:50'),
      'id': 'day-$day',
      'course_id': 'course-$day',
      'weekday': day,
      'course_name': [
        '工程力学空间一般力系及其平衡条件',
        '普通物理',
        '线性代数',
        '大学体育',
        '大学英语',
        '电工电子技术',
        'C语言程序设计'
      ][day - 1],
      'location': '教学楼$day-408',
    },
  {
    ...entry(start: '09:05', end: '10:50'),
    'id': 'overlap',
    'course_id': 'overlap',
    'weekday': 3,
    'course_name': '大学物理实验',
    'location': '实验楼2-405',
  },
  {
    ...entry(start: '19:30', end: '21:05'),
    'id': 'night',
    'course_id': 'night',
    'weekday': 5,
    'course_name': '晚间程序设计课程',
    'location': '机房5-410',
  },
];

Future<ApiClient> _mount(WidgetTester tester,
    {double width = 1000,
    double height = 800,
    double scale = 1,
    bool dark = false,
    bool reduce = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  SharedPreferences.setMockInitialValues({'cna_semester_start': '2026-08-31'});
  await tester.runAsync(loadFonts);
  final api = mockApi(_entries);
  await tester.pumpWidget(RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme)
            .copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduce),
            child: child!),
        home: StudyNavigationLayout(
            content: SchedulePage(
                apiClient: api, referenceDate: DateTime(2026, 10, 9)),
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) {}),
      )));
  await tester.pumpAndSettle();
  return api;
}

bool _painted(WidgetTester tester, Finder finder) {
  var result = true;
  tester.element(finder).visitAncestorElements((element) {
    if (element.widget case Opacity(opacity: final a)) {
      if (a == 0) result = false;
    }
    if (element.widget case Offstage(offstage: true)) result = false;
    return true;
  });
  return result;
}

List<Rect> _glyphs(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText();
  return paragraph
      .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length))
      .map((b) => b.toRect().shift(paragraph.localToGlobal(Offset.zero)))
      .toList();
}

void _weekFit(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(ScheduleAnchorView));
  final horizontal = tester
      .widget<SingleChildScrollView>(_key('schedule-anchor-horizontal'))
      .controller!;
  expect(horizontal.position.maxScrollExtent, closeTo(0, .001),
      reason: '整周七天不能依赖横向滚动才能找到');
  for (var day = 1; day <= 7; day++) {
    final header = tester.getRect(_key('schedule-anchor-day-$day'));
    expect(header.left, greaterThanOrEqualTo(viewport.left - .01));
    expect(header.right, lessThanOrEqualTo(viewport.right + .01));
    for (final e in _entries.where((e) => e['weekday'] == day)) {
      final card = _key('schedule-anchor-course-${e['id']}');
      expect(card, findsOneWidget);
      expect(_painted(tester, card), isTrue);
      final rect = tester.getRect(card);
      expect(rect.left, greaterThanOrEqualTo(header.left - .01),
          reason: '${e['id']} left');
      expect(rect.right, lessThanOrEqualTo(header.right + .01),
          reason: '${e['id']} right');
      for (final field in ['title', 'room', 'time']) {
        final f = _key('anchor-$field-${e['id']}');
        if (!_painted(tester, f)) continue;
        for (final glyph in _glyphs(tester, f)) {
          expect(glyph.left, greaterThanOrEqualTo(rect.left - .01),
              reason: '$field ${e['id']} glyph left');
          expect(glyph.right, lessThanOrEqualTo(rect.right + .01),
              reason: '$field ${e['id']} glyph right');
        }
      }
      final material = tester.widget<Material>(
          find.descendant(of: card, matching: find.byType(Material)).first);
      expect(material.color,
          CoursePalette.of(tester.element(card), '${e['course_name']}').fill);
    }
  }
  final overlap = tester.getRect(_key('schedule-anchor-course-overlap'));
  final slotTwo = tester.getRect(_key('anchor-slot-time-1'));
  if ((overlap.top - (slotTwo.top - 4)).abs() > .01) {
    final room = tester.widget<Text>(_key('anchor-room-overlap'));
    expect(room.data, startsWith('同时段'), reason: '冲突叠排移开标尺位置时必须明确这是同时间组');
    final time = _key('anchor-time-overlap');
    var opacity = 1.0;
    tester.element(time).visitAncestorElements((element) {
      if (element.widget case Opacity(opacity: final a)) opacity *= a;
      return true;
    });
    expect(opacity, closeTo(1, .000001), reason: '移开真实时间标尺的冲突卡必须显示完整起止时间');
    expect(tester.widget<Text>(time).data, '09:05\n10:50');
    expect(
        tester.getRect(time).bottom, lessThanOrEqualTo(overlap.bottom + .01));
  }
}

void _timesAvoidDock(WidgetTester tester) {
  final shell = tester.getRect(_shell);
  final view = tester.getRect(find.byType(ScheduleAnchorView));
  for (final f in [
    for (var i = 0; i < 10; i++) _key('anchor-slot-time-$i'),
    for (final e in _entries) _key('anchor-time-${e['id']}')
  ]) {
    if (!_painted(tester, f)) continue;
    for (final glyph in _glyphs(tester, f)) {
      if (!view.overlaps(glyph)) continue;
      expect(shell.overlaps(glyph), isFalse,
          reason: '收起悬浮Dock不能覆盖可见时间 $f $glyph shell=$shell');
    }
  }
}

Map<String, Rect> _rects(WidgetTester tester) => {
      for (final name in [
        'anchor-grid',
        for (var i = 0; i < 10; i++) 'anchor-slot-time-$i',
        for (var day = 1; day <= 7; day++) 'schedule-anchor-day-$day',
        for (final e in _entries) ...[
          'schedule-anchor-course-${e['id']}',
          'anchor-title-${e['id']}',
          'anchor-room-${e['id']}',
          'anchor-time-${e['id']}'
        ]
      ])
        if (_painted(tester, _key(name))) name: tester.getRect(_key(name)),
    };
void _same(Map<String, Rect> a, Map<String, Rect> b, String why) {
  for (final name in a.keys) {
    if (!b.containsKey(name)) continue;
    for (final pair in [
      (a[name]!.left, b[name]!.left),
      (a[name]!.top, b[name]!.top),
      (a[name]!.width, b[name]!.width),
      (a[name]!.height, b[name]!.height)
    ]) {
      expect(pair.$2, closeTo(pair.$1, .0001), reason: '$why $name');
    }
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_boundary))
        .toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/week-fit-$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final width in [900.0, 1000.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('独立真实页七天fit/颜色/冲突/时间不遮挡 ${width}x ${scale}x', (tester) async {
        final oldShadows = debugDisableShadows;
        debugDisableShadows = false;
        addTearDown(() {
          debugDisableShadows = oldShadows;
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
        });
        final api = await _mount(tester,
            width: width, scale: scale, dark: width == 1200);
        _weekFit(tester);
        _timesAvoidDock(tester);
        await _capture(tester, '${width.toInt()}-${scale}x-week');
        final before = _rects(tester);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset(width - 30, 30));
        await mouse.moveTo(tester.getCenter(_shell));
        await tester.pump(const Duration(milliseconds: 70));
        await tester.pump(const Duration(milliseconds: 110));
        _same(before, _rects(tester), 'hover中不能推动课表');
        await tester.pumpAndSettle();
        _same(before, _rects(tester), 'hover后不能推动课表');
        await _capture(tester, '${width.toInt()}-${scale}x-hover');
        await mouse.moveTo(Offset(width - 30, 30));
        await tester.pumpAndSettle();
        await mouse.removePointer();
        final vertical = tester
            .widget<SingleChildScrollView>(_key('schedule-anchor-vertical'))
            .controller!;
        vertical.jumpTo(vertical.position.maxScrollExtent * .55);
        await tester.pump();
        _timesAvoidDock(tester);
        vertical.jumpTo(0);
        await tester.pump();
        final overlap = _key('schedule-anchor-course-overlap');
        await tester.ensureVisible(overlap);
        await tester.pumpAndSettle();
        await _capture(tester, '${width.toInt()}-${scale}x-overlap');
        await tester.tap(overlap);
        await tester.pumpAndSettle();
        expect(_key('schedule-floating-details'), findsOneWidget);
        expect(find.text('大学物理实验').evaluate().length, greaterThanOrEqualTo(2));
        await tester.tap(_key('schedule-close-details'));
        await tester.pumpAndSettle();
        expect(_key('schedule-floating-details'), findsNothing);
        await tester.tap(find.text('当天'));
        await tester.pumpAndSettle();
        _timesAvoidDock(tester);
        expect(_painted(tester, _key('anchor-time-day-5')), isTrue,
            reason: '左Dock日模式的具体时间保持可见');
        await _capture(tester, '${width.toInt()}-${scale}x-day');
        final dayScroll = tester
            .widget<SingleChildScrollView>(_key('schedule-anchor-vertical'))
            .controller!;
        dayScroll.jumpTo(dayScroll.position.maxScrollExtent);
        await tester.pump();
        _timesAvoidDock(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        api.dio.close();
        debugDisableShadows = oldShadows;
      });
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('独立自适应和快速反向zero-pump稳定 ${scale}x', (tester) async {
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final api = await _mount(tester, scale: scale);
      final anchor = tester.element(_key('schedule-anchor-course-day-5'));
      for (final width in [800.0, 1000.0, 820.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump();
        for (var elapsed = 0; elapsed < 496; elapsed += 16) {
          final before = _rects(tester);
          await tester.pump();
          _same(before, _rects(tester), '$width ${elapsed}ms zero');
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull);
          if (elapsed == 240) {
            await _capture(tester, 'resize-${scale}x-${width.toInt()}-middle');
          }
        }
        expect(
            tester.element(_key('schedule-anchor-course-day-5')), same(anchor));
        if (width >= 850) _weekFit(tester);
        _timesAvoidDock(tester);
      }
      for (final width in [800.0, 1100.0, 820.0, 1000.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 96));
        final before = _rects(tester);
        await tester.pump();
        _same(before, _rects(tester), '快速反向zero');
      }
      await tester.pumpAndSettle();
      _weekFit(tester);
      _timesAvoidDock(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
    });
  }
  testWidgets('独立200%短窗减少动态效果保留七天和时间', (tester) async {
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final api = await _mount(tester,
        width: 1000, height: 600, scale: 2, reduce: true, dark: true);
    _weekFit(tester);
    _timesAvoidDock(tester);
    for (final width in [800.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 600);
      await tester.pump();
      await tester.pump();
      final state = tester
          .state<ScheduleAnchorViewState>(find.byType(ScheduleAnchorView));
      expect(state.debugIsAnimating, isFalse);
      expect(state.debugProgress, width < 850 ? 0 : 1);
      if (width >= 850) {
        _weekFit(tester);
        _timesAvoidDock(tester);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
  testWidgets('独立200%三门冲突摘要保留真实起止时间', (tester) async {
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final extra = [
      for (var i = 1; i <= 2; i++)
        {
          ...entry(start: '08:15', end: '09:50'),
          'id': 'triple-$i',
          'course_id': 'triple-$i',
          'weekday': 4,
          'course_name': '冲突实验课程$i',
          'location': '实验楼2-408',
        }
    ];
    _entries.addAll(extra);
    addTearDown(
        () => _entries.removeWhere((e) => '${e['id']}'.startsWith('triple-')));
    final api = await _mount(tester, width: 900, scale: 2);
    _weekFit(tester);
    _timesAvoidDock(tester);
    for (final id in ['day-4', 'triple-1', 'triple-2']) {
      expect(
          tester.widget<Text>(_key('anchor-room-$id')).data, startsWith('同时段'));
      final time = _key('anchor-time-$id');
      var opacity = 1.0;
      tester.element(time).visitAncestorElements((element) {
        if (element.widget case Opacity(opacity: final a)) opacity *= a;
        return true;
      });
      expect(opacity, closeTo(1, .000001));
      expect(tester.widget<Text>(time).data, '08:15\n09:50');
    }
    await _capture(tester, '900-2.0x-triple');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
