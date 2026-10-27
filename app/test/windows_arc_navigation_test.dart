import 'dart:io';
import 'dart:ui' as ui;
import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/motion.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'note_rendering_test.dart' show loadFonts;

const destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置')
];
final capsule = find.byKey(const ValueKey('touch-orientation-capsule'));
Finder item(int i) => find.byKey(ValueKey('capsule-item-$i'));
Finder icon(int i) => find.descendant(of: item(i), matching: find.byType(Icon));

void main() {
  Future<void> mount(WidgetTester tester,
      {Size size = const Size(800, 700),
      double scale = 1,
      bool reduce = false,
      int initial = 1,
      ValueChanged<int>? onSelected,
      Key? captureKey}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var selected = initial;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduce),
            child: child!),
        home: StatefulBuilder(
            builder: (context, update) => RepaintBoundary(
                key: captureKey,
                child: StudyNavigationLayout(
                    destinations: destinations,
                    selectedIndex: selected,
                    onSelected: (i) {
                      update(() => selected = i);
                      onSelected?.call(i);
                    },
                    content: StudyTabDeck(index: selected, children: [
                      const Text('课表内容'),
                      ListView.builder(
                          key: const ValueKey('notes-list'),
                          itemCount: 80,
                          itemExtent: 72,
                          itemBuilder: (_, i) =>
                              Card(child: ListTile(title: Text('课堂笔记 $i')))),
                      const Text('录音内容'),
                      const Text('设置内容')
                    ]))))));
    await tester.pumpAndSettle();
  }

  testWidgets('Windows跨900阈值是真实中间帧，同壳同文字且滚动保活', (tester) async {
    await mount(tester);
    final shellElement = tester.element(capsule);
    final words =
        destinations.map((d) => tester.element(find.text(d.$3))).toList();
    final list = find.descendant(
        of: find.byKey(const ValueKey('notes-list'), skipOffstage: false),
        matching: find.byType(Scrollable, skipOffstage: false),
        skipOffstage: false);
    await tester.drag(
        find.byKey(const ValueKey('notes-list')), const Offset(0, -350));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(list),
        offset = tester.state<ScrollableState>(list).position.pixels;
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pump();
    final start = tester.getRect(capsule);
    await tester.pump(const Duration(milliseconds: 220));
    final mid = tester.getRect(capsule);
    await tester.pumpAndSettle();
    final end = tester.getRect(capsule);
    expect(mid, start != end ? isNot(equals(start)) : equals(start));
    expect(mid, isNot(end));
    expect(end.left, lessThan(25));
    expect(start.center.dx, greaterThan(end.center.dx + 200));
    expect(identical(shellElement, tester.element(capsule)), isTrue);
    for (var i = 0; i < 4; i++) {
      expect(identical(words[i], tester.element(find.text(destinations[i].$3))),
          isTrue);
    }
    expect(identical(scroll, tester.state<ScrollableState>(list)), isTrue);
    expect(scroll.position.pixels, offset);
    for (final width in [899.0, 901.0, 899.0, 901.0]) {
      tester.view.physicalSize = Size(width, 700);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
    }
    await tester.pumpAndSettle();
    expect(identical(shellElement, tester.element(capsule)), isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Windows悬停仍短程展开，图标和正文不移动', (tester) async {
    await mount(tester, size: const Size(1000, 700));
    final closed = tester.getSize(capsule).width,
        iconStart = tester.getCenter(icon(0)),
        body = tester.getTopLeft(find.byKey(const ValueKey('notes-list')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(capsule));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(milliseconds: 90));
    final mid = tester.getSize(capsule).width;
    expect(mid, greaterThan(closed));
    expect(mid, lessThan(136.1));
    expect((tester.getCenter(icon(0)) - iconStart).distance, lessThan(.01));
    expect(tester.getTopLeft(find.byKey(const ValueKey('notes-list'))), body);
    await tester.pumpAndSettle();
    expect(tester.getSize(capsule).width, inInclusiveRange(136.0,150.0));
    await mouse.moveTo(const Offset(700, 500));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(tester.getSize(capsule).width, closeTo(closed, .01));
    expect((tester.getCenter(icon(0)) - iconStart).distance, lessThan(.01));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets('Windows宽而高窗口也用侧栏，按可用宽度而非方向', (tester) async {
    await mount(tester, size: const Size(1000, 1400));
    expect(tester.getRect(capsule).left, lessThan(25));
    expect(tester.getRect(capsule).height,
        greaterThan(tester.getRect(capsule).width));
  });
  testWidgets('Windows减动立即切布局，320%短屏键盘可达', (tester) async {
    var selected = -1;
    await mount(tester,
        size: const Size(1000, 230),
        scale: 3.2,
        reduce: true,
        initial: 0,
        onSelected: (i) => selected = i);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(tester.getRect(capsule).contains(tester.getCenter(icon(3))), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 3);
    tester.view.physicalSize = const Size(800, 700);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.getRect(capsule).center.dy, greaterThan(550));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Windows正式字体和真实阴影的实际窗口帧', (tester) async {
    await tester.runAsync(loadFonts);
    final shadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = shadows);
    const frameKey = ValueKey('windows-frame');
    await mount(tester, captureKey: frameKey);
    Future<void> capture(String name) async {
      await tester.pump();
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(frameKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        File('../windows-frames/$name.png')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    await capture('narrow');
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pump();
    await capture('start');
    await tester.pump(const Duration(milliseconds: 110));
    await capture('quarter');
    await tester.pump(const Duration(milliseconds: 110));
    await capture('middle');
    await tester.pump(const Duration(milliseconds: 110));
    await capture('three-quarter');
    await tester.pumpAndSettle();
    await capture('wide');
    tester.view.physicalSize = const Size(800, 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await capture('return-middle');
    await tester.pumpAndSettle();
    await capture('returned');
    debugDisableShadows = shadows;
    expect(tester.takeException(), isNull);
  });
}
