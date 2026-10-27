import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

const _root = ValueKey('judge-dock-scrollbar-root');
final _shell = find.byKey(const ValueKey('touch-orientation-capsule'));
const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];
final _expectedBars =
    int.tryParse(Platform.environment['CNA_EXPECT_AUTOSCROLLBARS'] ?? '') ?? 0;
final _prefix = _expectedBars == 0 ? 'after' : 'before';

Future<void> _mount(WidgetTester tester,
    {Size size = const Size(1000, 800),
    double scale = 1,
    bool reduce = false,
    bool dark = false,
    Widget? content,
    ValueChanged<int>? selected}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(RepaintBoundary(
      key: _root,
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
            content: content ??
                const ColoredBox(
                    color: Color(0xff467263), child: SizedBox.expand()),
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: selected ?? (_) {}),
      )));
  await tester.pumpAndSettle();
}

void _bars() => expect(
    find.descendant(of: _shell, matching: find.byType(Scrollbar)),
    findsNWidgets(_expectedBars),
    reason: '导航内Windows自动注入的竖滚动条应局部禁用');

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_root))
        .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/scrollbar-$_prefix-$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('独立导航自动Scrollbar数量、hover几何与轮廓 ${dark ? 'dark' : 'light'}',
        (tester) async {
      final oldShadow = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadow);
      await _mount(tester, dark: dark);
      _bars();
      final shell = tester.getRect(_shell);
      final icon = find.descendant(
          of: find.byKey(const ValueKey('capsule-item-0')),
          matching: find.byType(Icon));
      final beforeIcon = tester.getRect(icon);
      final shape = tester.renderObject<RenderPhysicalShape>(
          find.descendant(of: _shell, matching: find.byType(PhysicalShape)));
      expect(shape.clipBehavior, Clip.antiAlias);
      await _capture(tester, '${dark ? 'dark' : 'light'}-closed');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(800, 30));
      await mouse.moveTo(shell.center);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pump(const Duration(milliseconds: 110));
      _bars();
      await _capture(tester, '${dark ? 'dark' : 'light'}-hover-middle');
      await tester.pumpAndSettle();
      _bars();
      expect(tester.getRect(_shell).width, greaterThan(shell.width));
      expect((tester.getRect(icon).topLeft - beforeIcon.topLeft).distance,
          lessThan(.0001),
          reason: '去条纹不能推动图标或重做外壳');
      await _capture(tester, '${dark ? 'dark' : 'light'}-expanded');
      await mouse.moveTo(const Offset(800, 30));
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();
      expect(tester.getRect(_shell), shell);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDisableShadows = oldShadow;
    });
  }

  testWidgets('独立局部禁条不影响真实课表滚动条、七列与时间避让', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    final api = mockApi([
      for (var i = 1; i <= 7; i++)
        {
          ...entry(start: '08:15', end: '09:50'),
          'id': 'c$i',
          'weekday': i,
          'course_name': '工程力学$i',
        }
    ]);
    await _mount(tester,
        content:
            SchedulePage(apiClient: api, referenceDate: DateTime(2026, 10, 9)));
    _bars();
    final anchor = find.byType(ScheduleAnchorView);
    expect(find.descendant(of: anchor, matching: find.byType(Scrollbar)),
        findsNWidgets(3),
        reason: '真实课表原有3条Scrollbar保持原行为，配置不得泄露');
    final viewport = tester.getRect(anchor);
    for (var i = 1; i <= 7; i++) {
      final header =
          tester.getRect(find.byKey(ValueKey('schedule-anchor-day-$i')));
      expect(header.left, greaterThanOrEqualTo(viewport.left - .01));
      expect(header.right, lessThanOrEqualTo(viewport.right + .01));
    }
    final vertical = tester
        .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('schedule-anchor-vertical')))
        .controller!;
    expect(vertical.position.maxScrollExtent, greaterThan(0));
    vertical.jumpTo(100);
    await tester.pump();
    expect(vertical.offset, 100);
    final time = tester.renderObject<RenderParagraph>(
        find.byKey(const ValueKey('anchor-slot-time-1')));
    for (final box in time.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 13))) {
      final glyph = box.toRect().shift(time.localToGlobal(Offset.zero));
      expect(tester.getRect(_shell).overlaps(glyph), isFalse);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });

  testWidgets('独立320%短窗导航真实滚动、键盘末项与语义不丢失', (tester) async {
    var selected = -1;
    await _mount(tester,
        size: const Size(1000, 230),
        scale: 3.2,
        reduce: true,
        selected: (i) => selected = i);
    _bars();
    final vertical = tester.state<ScrollableState>(find
        .descendant(
            of: find.byKey(const ValueKey('capsule-vertical-scroll')),
            matching: find.byType(Scrollable))
        .first);
    expect(vertical.position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(vertical.position.pixels, greaterThan(0), reason: '键盘导航仍能真实滚动到末项');
    await _capture(tester, '320-short-scrolled');
    final lastIcon = find.descendant(
        of: find.byKey(const ValueKey('capsule-item-3')),
        matching: find.byType(Icon));
    expect(tester.getRect(_shell).contains(tester.getCenter(lastIcon)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 3);
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(find.bySemanticsLabel('设置'));
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    semantics.dispose();
    _bars();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
