import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.scale = 1});
  final double scale;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final anchor = GlobalKey<ScheduleAnchorViewState>();
  final boundary = GlobalKey();
  bool day = false;
  double left = 160;
  void change({bool? dayMode, double? origin}) => setState(() {
        day = dayMode ?? day;
        left = origin ?? left;
      });

  @override
  Widget build(BuildContext context) => RepaintBoundary(
      key: boundary,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(widget.scale)),
              child: child!),
          home: Scaffold(
              body: Padding(
                  padding: EdgeInsets.only(left: left, top: 48),
                  child: ScheduleAnchorView(
                      key: anchor,
                      entries: [
                        for (final item in [
                          ('anchor', 4, '08:15', '09:50', '工程力学空间一般力系及其平衡条件'),
                          ('later', 4, '14:15', '15:50', '线性代数'),
                          ('night', 4, '19:00', '20:35', '大学英语'),
                          ('other', 2, '10:05', '11:40', '普通物理'),
                        ])
                          {
                            'id': item.$1,
                            'weekday': item.$2,
                            'start_time': item.$3,
                            'end_time': item.$4,
                            'course_name': item.$5,
                            'location': '教学楼4-402',
                          }
                      ],
                      weekStart: DateTime(2026, 10, 12),
                      today: DateTime(2026, 10, 15),
                      selectedDay: 4,
                      dayMode: day,
                      viewportOriginX: left,
                      onSelectDay: (_) {},
                      onOpen: (_) {})))));
}

Finder _key(String value) => find.byKey(ValueKey(value));
ScrollController _scroll(WidgetTester tester, String axis) => tester
    .widget<SingleChildScrollView>(_key('schedule-anchor-$axis'))
    .controller!;

Map<String, Rect> _rects(WidgetTester tester) => {
      for (final name in [
        'anchor-grid',
        for (var i = 0; i < 10; i++) 'anchor-slot-time-$i',
        'schedule-anchor-course-anchor',
        'schedule-anchor-day-4',
        'anchor-title-anchor',
        'anchor-room-anchor',
        'anchor-time-anchor',
      ])
        name: tester.getRect(_key(name))
    };

void _same(Map<String, Rect> before, Map<String, Rect> after, String why,
    {bool responsiveCommand = false}) {
  for (final name in before.keys) {
    final a = before[name]!, b = after[name]!;
    for (final pair in [
      (a.left, b.left),
      (a.top, b.top),
      if (!(responsiveCommand &&
          (name.startsWith('anchor-title-') ||
              name.startsWith('anchor-room-')))) ...[
        (a.width, b.width),
        (a.height, b.height)
      ]
    ]) {
      expect(pair.$2, closeTo(pair.$1, .0001), reason: '$why: $name');
    }
  }
}

bool _painted(WidgetTester tester, String name) {
  var visible = true;
  tester.element(_key(name)).visitAncestorElements((element) {
    if (element.widget case Opacity(opacity: final alpha)) {
      if (alpha == 0) visible = false;
    }
    if (element.widget case Offstage(offstage: true)) visible = false;
    return true;
  });
  return visible;
}

Future<void> _zeroStable(WidgetTester tester, String why) async {
  final before = _rects(tester);
  final paintedBefore = {
    for (final name in before.keys) name: _painted(tester, name)
  };
  await tester.pump();
  final after = _rects(tester);
  final checked = {
    for (final name in before.keys)
      if (paintedBefore[name]! || _painted(tester, name)) name: before[name]!
  };
  _same(checked, after, '$why zero-duration pump (every painted object)');
  expect(tester.takeException(), isNull);
}

Future<void> _capture(WidgetTester tester, _HarnessState h, String name) async {
  await tester.runAsync(() async {
    final image = await (h.boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/judge-$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<_HarnessState> _mount(WidgetTester tester, double scale) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(960, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.runAsync(loadFonts);
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(key: key, scale: scale));
  await tester.pumpAndSettle();
  return key.currentState!;
}

Future<void> _frames(WidgetTester tester, int milliseconds,
    {List<Map<String, Object?>>? trace}) async {
  var elapsed = 0;
  final fieldSizes = {
    for (final f in ['title', 'room', 'time'])
      f: tester.getSize(_key('anchor-$f-anchor'))
  };
  while (elapsed < milliseconds) {
    final step = (milliseconds - elapsed).clamp(1, 16);
    await tester.pump(Duration(milliseconds: step));
    elapsed += step;
    final rects = _rects(tester);
    for (final f in fieldSizes.keys) {
      expect(tester.getSize(_key('anchor-$f-anchor')), fieldSizes[f],
          reason: '${elapsed}ms fixed $f typography metrics');
    }
    trace?.add({
      'ms': elapsed,
      'rects':
          rects.map((k, v) => MapEntry(k, [v.left, v.top, v.width, v.height]))
    });
    await _zeroStable(tester, 'at ${elapsed}ms');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scale in [1.0, 2.0]) {
    testWidgets('独立逐帧${scale}x：外部padding、正反、滚动及490ms收尾原子稳定', (tester) async {
      final h = await _mount(tester, scale), state = h.anchor.currentState!;
      _scroll(tester, 'horizontal').jumpTo(_scroll(tester, 'horizontal')
          .position
          .maxScrollExtent
          .clamp(0.0, 80.0));
      _scroll(tester, 'vertical').jumpTo(120);
      await tester.pump();
      final cardElement = tester.element(_key('schedule-anchor-course-anchor'));
      final fields = {
        for (final f in ['title', 'room', 'time'])
          f: (
            tester.element(_key('anchor-$f-anchor')),
            tester.getSize(_key('anchor-$f-anchor'))
          )
      };
      final initialWeek = state.debugWeekOffset;
      final before = _rects(tester);
      await _capture(tester, h, '${scale}x-week-before');
      tester.view.physicalSize = const Size(760, 720);
      h.change(dayMode: true, origin: 0);
      await tester.pump();
      _same(before, _rects(tester), 'week→day resize command frame',
          responsiveCommand: true);
      await _zeroStable(tester, 'week→day command frame');
      final trace = <Map<String, Object?>>[];
      await _frames(tester, 240, trace: trace);
      await _capture(tester, h, '${scale}x-to-day-middle');
      await _frames(tester, 249, trace: trace);
      await tester.pump(const Duration(milliseconds: 1));
      expect(state.debugProgress, 0);
      await _zeroStable(tester, 'exact 490ms to day');
      await tester.pump(const Duration(milliseconds: 1));
      await _zeroStable(tester, '491ms to day');
      expect(_scroll(tester, 'horizontal').offset, state.debugDayOffset.dx);
      expect(_scroll(tester, 'vertical').offset, state.debugDayOffset.dy);
      await _capture(tester, h, '${scale}x-day-end');
      final dayBefore = {
        for (final e in _rects(tester).entries)
          if (_painted(tester, e.key)) e.key: e.value
      };
      tester.view.physicalSize = const Size(960, 720);
      h.change(dayMode: false, origin: 160);
      await tester.pump();
      _same(dayBefore, _rects(tester), 'day→week resize command frame',
          responsiveCommand: true);
      await _zeroStable(tester, 'day→week command frame');
      await _frames(tester, 240, trace: trace);
      await _capture(tester, h, '${scale}x-to-week-middle');
      await _frames(tester, 249, trace: trace);
      await tester.pump(const Duration(milliseconds: 1));
      expect(state.debugProgress, 1);
      await _zeroStable(tester, 'exact 490ms to week');
      await tester.pump(const Duration(milliseconds: 1));
      await _zeroStable(tester, '491ms to week');
      expect(state.debugWeekOffset, initialWeek);
      expect(_scroll(tester, 'horizontal').offset, initialWeek.dx);
      expect(_scroll(tester, 'vertical').offset, initialWeek.dy);
      expect(tester.element(_key('schedule-anchor-course-anchor')),
          same(cardElement));
      for (final f in fields.keys) {
        expect(tester.element(_key('anchor-$f-anchor')), same(fields[f]!.$1));
        // A narrower real viewport can remeasure paragraphs to keep seven
        // columns visible. Elements and zero-duration geometry stay stable.
        expect(tester.getSize(_key('anchor-$f-anchor')).width,
            lessThanOrEqualTo(fields[f]!.$2.width + .01));
      }
      await _capture(tester, h, '${scale}x-week-end');
      await tester.runAsync(() async =>
          File('../review-frames/judge-${scale}x-trace.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(trace)));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('独立同周模式：原点变动与滚动extent缩减不能令时间栏瞬跳', (tester) async {
    final h = await _mount(tester, 1);
    _scroll(tester, 'horizontal').jumpTo(_scroll(tester, 'horizontal')
        .position
        .maxScrollExtent
        .clamp(0.0, 100.0));
    _scroll(tester, 'vertical').jumpTo(220);
    await tester.pump();
    final before = _rects(tester);
    tester.view.physicalSize = const Size(5000, 720);
    h.change(origin: 16);
    await tester.pump();
    _same(before, _rects(tester), 'same-week resize first frame',
        responsiveCommand: true);
    await _zeroStable(tester, 'same-week command frame');
    await _frames(tester, 490);
    // Reflow starts in LayoutBuilder; its first ticker is the next frame.
    // Test the entire first-ticker+490ms interval without an endpoint exemption.
    await tester.pump(const Duration(milliseconds: 16));
    await _zeroStable(tester, 'same-week first ticker plus490 completion');
    await _zeroStable(tester, 'same-week completion');
    expect(_scroll(tester, 'horizontal').offset, 0);
    final slot = tester.getRect(_key('anchor-slot-time-0'));
    expect(slot.left, 16);
    expect(tester.getRect(_key('anchor-grid')).left, 16);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立快速反向：每次命令保持时间、网格与字形的当前全局矩形', (tester) async {
    final h = await _mount(tester, 2), state = h.anchor.currentState!;
    _scroll(tester, 'horizontal').jumpTo(_scroll(tester, 'horizontal')
        .position
        .maxScrollExtent
        .clamp(0.0, 70.0));
    _scroll(tester, 'vertical').jumpTo(180);
    await tester.pump();
    for (final target in [
      (true, 0.0, 760.0),
      (false, 160.0, 960.0),
      (true, 0.0, 740.0),
      (false, 110.0, 1050.0),
      (true, 0.0, 780.0)
    ]) {
      final before = _rects(tester),
          p = state.debugProgress,
          velocity = state.debugVelocity;
      tester.view.physicalSize = Size(target.$3, 720);
      h.change(dayMode: target.$1, origin: target.$2);
      await tester.pump();
      expect(state.debugProgress, closeTo(p, 1e-9));
      expect(state.debugVelocity, closeTo(velocity, 1e-6));
      _same(before, _rects(tester), 'rapid reverse command',
          responsiveCommand: true);
      await _frames(tester, 96);
    }
    await _frames(tester, 600);
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立正式字体截图：100/200%未滚动时间栏的开始中间终点', (tester) async {
    for (final scale in [1.0, 2.0]) {
      final h = await _mount(tester, scale);
      _scroll(tester, 'horizontal').jumpTo(_scroll(tester, 'horizontal')
          .position
          .maxScrollExtent
          .clamp(0.0, 0.0));
      _scroll(tester, 'vertical').jumpTo(0);
      await tester.pump();
      await _capture(tester, h, '${scale}x-visible-gutter-week-start');
      h.change(dayMode: true, origin: 0);
      tester.view.physicalSize = const Size(760, 720);
      await tester.pump();
      await _zeroStable(tester, 'visible-gutter reverse command');
      await _frames(tester, 240);
      await _capture(tester, h, '${scale}x-visible-gutter-to-day-middle');
      await _frames(tester, 250);
      await _capture(tester, h, '${scale}x-visible-gutter-day-end');
      h.change(dayMode: false, origin: 160);
      tester.view.physicalSize = const Size(960, 720);
      await tester.pump();
      await _zeroStable(tester, 'visible-gutter forward command');
      await _frames(tester, 240);
      await _capture(tester, h, '${scale}x-visible-gutter-to-week-middle');
      await _frames(tester, 249);
      await _capture(tester, h, '${scale}x-visible-gutter-week-489');
      await tester.pump(const Duration(milliseconds: 1));
      await _capture(tester, h, '${scale}x-visible-gutter-week-490');
      await _zeroStable(tester, 'visible gutter 490ms');
      await _capture(tester, h, '${scale}x-visible-gutter-week-490-zero');
      await tester.pump(const Duration(milliseconds: 1));
      await _zeroStable(tester, 'visible gutter 491ms');
      await _capture(tester, h, '${scale}x-visible-gutter-week-491');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
