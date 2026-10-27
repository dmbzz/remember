import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/orientation_capsule.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
Finder _key(String s) => find.byKey(ValueKey(s));
final _shell = _key('touch-orientation-capsule');
const _boundary = ValueKey('judge-floating-dock-boundary');

ApiClient _scheduleApi() => mockApi([
      {
        ...entry(start: '08:15', end: '09:50'),
        'id': 'anchor',
        'weekday': 5,
        'course_name': '工程力学课程锚点'
      },
      {
        ...entry(start: '10:05', end: '11:40'),
        'id': 'later',
        'weekday': 5,
        'course_name': '线性代数课程'
      },
      {
        ...entry(start: '08:15', end: '09:50'),
        'id': 'monday',
        'weekday': 1,
        'course_name': '普通物理课程'
      },
      {
        ...entry(start: '14:15', end: '15:50'),
        'id': 'night',
        'weekday': 7,
        'course_name': '大学英语课程'
      },
    ]);

ApiClient _notesApi() {
  final api = ApiClient(baseUrl: 'http://judge-notes.test');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (req, handler) {
    handler.resolve(Response(requestOptions: req, statusCode: 200, data: {
      'code': 0,
      'message': 'ok',
      'data': {
        'items': List.generate(
            20,
            (i) => {
                  'note_id': 'judge-note-$i',
                  'topic': '平面一般力系课堂笔记 $i',
                  'course_name': i.isEven ? '工程力学' : '线性代数',
                  'class_date': '2026-10-15',
                }),
        'total': 20,
      },
    }));
  }));
  return api;
}

Future<void> _mount(WidgetTester tester, Widget content,
    {bool navigation = true,
    bool baselineTimeProtection = false,
    bool dark = false,
    double scale = 1,
    Size size = const Size(1000, 900),
    bool reduce = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.runAsync(loadFonts);
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
          home: navigation
              ? StudyNavigationLayout(
                  content: content,
                  destinations: _destinations,
                  selectedIndex: 0,
                  onSelected: (_) {})
              : Builder(builder: (context) {
                  if (!baselineTimeProtection) return content;
                  // Compare the same requested time layout with and without
                  // the overlay. This does not reserve any page-width slot.
                  final theme = Theme.of(context);
                  var labelHeight = 0.0;
                  for (final destination in _destinations) {
                    final painter = TextPainter(
                        text: TextSpan(
                            text: destination.$3,
                            style: TextStyle(
                                inherit: false,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                                letterSpacing: 0,
                                fontFamilyFallback: theme
                                    .textTheme.bodyMedium?.fontFamilyFallback,
                                fontFamily:
                                    theme.textTheme.bodyMedium?.fontFamily)),
                        textDirection: TextDirection.ltr,
                        textScaler: MediaQuery.textScalerOf(context))
                      ..layout();
                    final height = painter.height.ceilToDouble() + 1;
                    if (height > labelHeight) labelHeight = height;
                    painter.dispose();
                  }
                  return StudyFloatingTimeInset(
                      leading:
                          48 + (28 + labelHeight).clamp(56.0, double.infinity),
                      child: content);
                }))));
  await tester.pumpAndSettle();
}

Future<Uint8List> _capture(WidgetTester tester, String name) async {
  late Uint8List raw;
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_boundary))
        .toImage(pixelRatio: 1);
    raw = Uint8List.fromList(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List());
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/floating-$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
  return raw;
}

// Compare real pages against the same page without the navigation wrapper.
// The baseline uses the requested same time gutter; a full-height navigation
// slot or opaque outside layer still changes actual pixels here.
void _sameExterior(
    Uint8List baseline, Uint8List overlay, Rect shell, Size size) {
  var checked = 0, changed = 0;
  final shadow = shell.inflate(18);
  for (var y = 2; y < size.height - 2; y += 3) {
    for (var x = 2; x < size.width - 2; x += 3) {
      if (shadow.contains(Offset(x.toDouble(), y.toDouble()))) continue;
      final i = (y * size.width.toInt() + x) * 4;
      checked++;
      if (List.generate(4, (c) => (baseline[i + c] - overlay[i + c]).abs())
          .any((difference) => difference > 1)) changed++;
    }
  }
  expect(checked, greaterThan(50000));
  expect(changed, 0, reason: 'Dock外必须绘制同一个真实页面；含标题/搜索/课表，不能预留空带');
}

Map<String, Rect> _scheduleRects(WidgetTester tester) => {
      for (final s in [
        'anchor-grid',
        for (var i = 0; i < 10; i++) 'anchor-slot-time-$i',
        'schedule-anchor-course-anchor',
        'anchor-title-anchor',
        'anchor-room-anchor',
        'anchor-time-anchor'
      ])
        s: tester.getRect(_key(s)),
    };

bool _painted(WidgetTester tester, String s) {
  var painted = true;
  tester.element(_key(s)).visitAncestorElements((element) {
    if (element.widget case Opacity(opacity: final a)) {
      if (a == 0) painted = false;
    }
    if (element.widget case Offstage(offstage: true)) painted = false;
    return true;
  });
  return painted;
}

void _sameRects(Map<String, Rect> a, Map<String, Rect> b, String why,
    {bool responsiveCommand = false}) {
  for (final s in a.keys) {
    final before = a[s]!, after = b[s]!;
    expect((after.topLeft - before.topLeft).distance, lessThan(.0001),
        reason: '$why $s');
    if (!(responsiveCommand &&
        (s.startsWith('anchor-title-') || s.startsWith('anchor-room-')))) {
      expect(after.width, closeTo(before.width, .0001),
          reason: '$why $s width');
      expect(after.height, closeTo(before.height, .0001),
          reason: '$why $s height');
    }
  }
}

Future<void> _zeroStable(WidgetTester tester, String why) async {
  final before = _scheduleRects(tester);
  final visible = {for (final s in before.keys) s: _painted(tester, s)};
  await tester.pump();
  _sameRects({
    for (final s in before.keys)
      if (visible[s]! || _painted(tester, s)) s: before[s]!
  }, _scheduleRects(tester), why);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
  });
  for (final dark in [false, true]) {
    for (final notes in [false, true]) {
      testWidgets(
          '独立真实页面 ${notes ? 'Notes' : 'Schedule'} ${dark ? 'dark' : 'light'} 200% 无Dock占位及局部避让',
          (tester) async {
        final oldShadow = debugDisableShadows;
        debugDisableShadows = false;
        addTearDown(() {
          debugDisableShadows = oldShadow;
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
        });
        final baselineApi = notes ? _notesApi() : _scheduleApi();
        Widget page(ApiClient api) => notes
            ? NotesPage(apiClient: api)
            : SchedulePage(
                apiClient: api, referenceDate: DateTime(2026, 10, 9));
        final prefix =
            '${notes ? 'notes' : 'schedule'}-${dark ? 'dark' : 'light'}-200';
        const size = Size(1000, 900);
        await _mount(tester, page(baselineApi),
            navigation: false,
            baselineTimeProtection: !notes,
            dark: dark,
            scale: 2);
        final baseline = await _capture(tester, '$prefix-reference');
        final reference = notes
            ? tester.getRect(find.byType(TextField))
            : tester.getRect(find.byType(ScheduleAnchorView));
        await tester.pumpWidget(const SizedBox.shrink());
        baselineApi.dio.close();
        SharedPreferences.setMockInitialValues(
            {'cna_semester_start': '2026-08-31'});
        final api = notes ? _notesApi() : _scheduleApi();
        await _mount(tester, page(api), dark: dark, scale: 2);
        final content = notes
            ? tester.getRect(find.byType(TextField))
            : tester.getRect(find.byType(ScheduleAnchorView));
        expect(content, reference, reason: '完整真实页面几何必须与无Dock时一致');
        if (notes) {
          expect(content.left, 100, reason: '840居中正文在1000窗宽使用原20边距');
        } else {
          expect(content.left, 0);
          expect(content.width, 1000);
        }
        final shell = tester.getRect(_shell);
        final overlay = await _capture(tester, '$prefix-closed');
        _sameExterior(baseline, overlay, shell, size);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(800, 40));
        await mouse.moveTo(shell.center);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.pump(const Duration(milliseconds: 110));
        expect(
            notes
                ? tester.getRect(find.byType(TextField))
                : tester.getRect(find.byType(ScheduleAnchorView)),
            reference);
        await tester.pumpAndSettle();
        final expanded = tester.getRect(_shell);
        expect(expanded.width, greaterThan(shell.width));
        final hover = await _capture(tester, '$prefix-hover');
        _sameExterior(baseline, hover, expanded, size);
        await mouse.moveTo(const Offset(800, 40));
        await tester.pumpAndSettle();
        await mouse.removePointer();
        if (notes) {
          final field = find.byType(TextField);
          final target = tester.getRect(field).topLeft + const Offset(180, 24);
          expect(tester.getRect(_shell).contains(target), isFalse);
          await tester.tapAt(target);
          await tester.enterText(field, '工程力学');
          await tester.pumpAndSettle();
          expect(find.text('最近笔记 · 10'), findsOneWidget);
        } else {
          final day = _key('schedule-anchor-day-4');
          expect(
              tester.getRect(_shell).contains(tester.getCenter(day)), isFalse);
          await tester.tap(day);
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<ScheduleAnchorView>(find.byType(ScheduleAnchorView))
                  .selectedDay,
              4);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        api.dio.close();
        debugDisableShadows = oldShadow;
      });
    }
  }

  testWidgets('独立命中：外侧/透明圆角穿透，胶囊内部空白阻挡', (tester) async {
    var taps = 0;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await _mount(
        tester,
        GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const ColoredBox(
                color: Color(0xff274c73), child: SizedBox.expand())));
    final shell = tester.getRect(_shell);
    for (final p in [
      Offset(2, shell.center.dy),
      Offset(shell.center.dx, shell.top - 25),
      Offset(shell.center.dx, shell.bottom + 25),
      shell.topLeft + const Offset(1, 1)
    ]) {
      await tester.tapAt(p);
      await tester.pump();
    }
    expect(taps, 4);
    await tester.tapAt(shell.topCenter + const Offset(0, 5));
    await tester.pump();
    expect(taps, 4, reason: '胶囊本体允许覆盖，不能向后误触');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('独立整页 ${scale}x 窄宽与快速反向每16ms及490终点zero-pump稳定', (tester) async {
      final oldShadow = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() {
        debugDisableShadows = oldShadow;
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final api = _scheduleApi();
      await _mount(tester,
          SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
          scale: scale);
      final state = tester
          .state<ScheduleAnchorViewState>(find.byType(ScheduleAnchorView));
      final element = tester.element(_key('schedule-anchor-course-anchor'));
      for (final width in [800.0, 1000.0, 820.0, 1000.0]) {
        final before = _scheduleRects(tester);
        final visible = {for (final s in before.keys) s: _painted(tester, s)};
        tester.view.physicalSize = Size(width, 900);
        await tester.pump();
        _sameRects({
          for (final s in before.keys)
            if (visible[s]!) s: before[s]!
        }, _scheduleRects(tester), 'resize command width=$width',
            responsiveCommand: true);
        final titleSize = tester.getSize(_key('anchor-title-anchor'));
        await _zeroStable(tester, 'command width=$width');
        var elapsed = 0;
        while (elapsed < 491) {
          final step = (elapsed < 480 ? 16 : 1);
          await tester.pump(Duration(milliseconds: step));
          elapsed += step;
          await _zeroStable(tester, '$elapsed ms width=$width');
          expect(tester.getSize(_key('anchor-title-anchor')), titleSize);
          if (elapsed == 240 || elapsed == 490) {
            await _capture(
                tester, 'resize-${scale}x-${width.toInt()}-$elapsed');
          }
        }
        expect(state.debugProgress, width < 850 ? 0 : 1);
        expect(tester.element(_key('schedule-anchor-course-anchor')),
            same(element));
      }
      for (final width in [800.0, 1000.0, 820.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await _zeroStable(tester, 'rapid reversal $width');
      }
      await tester.pumpAndSettle();
      expect(state.debugProgress, 0);
      expect(state.debugIsAnimating, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
      debugDisableShadows = oldShadow;
    });
  }

  testWidgets('独立详情短窗200%：卡内滚动使末端操作可达且不扩成整高分隔栏', (tester) async {
    final oldShadow = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final api = _scheduleApi();
    await _mount(tester,
        SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
        dark: true, scale: 2, size: const Size(1200, 600));
    await tester.tapAt(
        tester.getRect(_key('schedule-anchor-course-anchor')).topLeft +
            const Offset(100, 30));
    await tester.pumpAndSettle();
    final floating = _key('schedule-floating-details');
    expect(floating, findsOneWidget);
    final viewport = tester.getRect(find.byType(ScheduleAnchorView));
    expect(tester.getRect(floating).height,
        lessThanOrEqualTo(viewport.height - 24));
    final scroll = tester.state<ScrollableState>(
        find.descendant(of: floating, matching: find.byType(Scrollable)));
    expect(scroll.position.maxScrollExtent, greaterThan(100));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final action =
        find.descendant(of: floating, matching: find.text('这门课自动录音'));
    expect(tester.getRect(floating).contains(tester.getCenter(action)), isTrue);
    expect(action.hitTestable(), findsOneWidget);
    await _capture(tester, 'detail-short-200-scrolled');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
    debugDisableShadows = oldShadow;
  });

  for (final config in [(false, 1.0), (true, 2.0)]) {
    testWidgets('独立浮动详情 ${config.$2}x：无常驻栏、按内容圆角、外部切课、关闭/减动', (tester) async {
      final oldShadow = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() {
        debugDisableShadows = oldShadow;
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final api = _scheduleApi();
      await _mount(tester,
          SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
          dark: config.$1, scale: config.$2, size: const Size(1200, 1040));
      final floating = _key('schedule-floating-details');
      expect(floating, findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      final viewport = tester.getRect(find.byType(ScheduleAnchorView));
      expect(viewport.left, 0);
      expect(viewport.width, 1200);
      final geometry = _scheduleRects(tester);
      await tester.tap(_key('schedule-anchor-course-anchor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      await _capture(tester, 'detail-${config.$2}x-enter-middle');
      await tester.pumpAndSettle();
      expect(floating, findsOneWidget);
      _sameRects(geometry, _scheduleRects(tester),
          'open floating detail must not reserve a right column');
      final panel = tester.getRect(floating);
      expect(panel.right, closeTo(viewport.right - 12, .01));
      expect(panel.top, closeTo(viewport.top + 12, .01));
      expect(panel.bottom, lessThanOrEqualTo(viewport.bottom - 12));
      if (config.$2 == 1) {
        expect(panel.height, lessThan(viewport.height - 80),
            reason: '普通字号详情必须按实际内容收高，不能又成为整高侧栏');
      }
      final material = tester.widget<Material>(floating);
      expect(material.shape, isA<RoundedRectangleBorder>());
      expect((material.shape! as RoundedRectangleBorder).borderRadius,
          isNot(BorderRadius.zero));
      expect(material.clipBehavior, Clip.antiAlias);
      await _capture(tester, 'detail-${config.$2}x-open');
      // With seven columns fitted, Friday's later course center can be below
      // the viewport or behind the legitimate floating card. Monday is visible
      // outside both surfaces and still exercises real background course input.
      final next = _key('schedule-anchor-course-monday');
      final target = tester.getCenter(next);
      expect(viewport.contains(target), isTrue);
      expect(panel.contains(target), isFalse);
      expect(tester.getRect(_shell).contains(target), isFalse);
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();
      expect(find.descendant(of: floating, matching: find.text('普通物理课程')),
          findsOneWidget,
          reason: '浮卡外的真实后方课程须单击切换详情，不能被整列/遮罩拦截');
      _sameRects(geometry, _scheduleRects(tester), 'switch course');
      await tester.tap(_key('schedule-close-details'));
      await tester.pumpAndSettle();
      expect(floating, findsNothing);
      _sameRects(geometry, _scheduleRects(tester), 'close floating detail');
      await tester.tap(_key('schedule-anchor-course-anchor'));
      await tester.pumpAndSettle();
      final blank = Offset(viewport.center.dx, viewport.bottom - 30);
      expect(tester.getRect(floating).contains(blank), isFalse);
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      expect(floating, findsNothing, reason: '卡片外点击关闭但不永久拦截背景');
      await tester.tap(_key('schedule-anchor-course-anchor'));
      await tester.pumpAndSettle();
      final closeIcon = find.descendant(
          of: _key('schedule-close-details'), matching: find.byType(Icon));
      Focus.of(tester.element(closeIcon)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(floating, findsNothing, reason: '课程详情有键盘焦点时Escape必须关闭');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.setMockInitialValues(
          {'cna_semester_start': '2026-08-31'});
      await _mount(tester,
          SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)),
          dark: config.$1,
          scale: config.$2,
          size: const Size(1200, 1040),
          reduce: true);
      await tester.tap(_key('schedule-anchor-course-anchor'));
      await tester.pump();
      expect(floating, findsOneWidget);
      await tester.tap(_key('schedule-close-details'));
      await tester.pump();
      expect(floating, findsNothing, reason: '减少动态效果下浮卡立即关闭');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
      debugDisableShadows = oldShadow;
    });
  }
}
