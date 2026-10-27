import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];
const _contentKey = ValueKey('full-width-content');
const _captureKey = ValueKey('dock-transparency-capture');
const _contentColor = Color(0xff278c79);
final _capsule = find.byKey(const ValueKey('touch-orientation-capsule'));
Finder _item(int i) => find.byKey(ValueKey('capsule-item-$i'));
Finder _icon(int i) =>
    find.descendant(of: _item(i), matching: find.byType(Icon));

Future<void> _mount(WidgetTester tester,
    {Size size = const Size(1000, 700),
    double scale = 1,
    bool dark = false,
    bool reduce = false,
    TargetPlatform platform = TargetPlatform.windows,
    EdgeInsets safe = EdgeInsets.zero,
    Widget? content,
    VoidCallback? onBackgroundTap,
    ValueChanged<int>? onSelected}) async {
  await tester.runAsync(loadFonts);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  var selected = 0;
  await tester.pumpWidget(MaterialApp(
      theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme)
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              padding: safe,
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduce),
          child: child!),
      home: RepaintBoundary(
          key: _captureKey,
          child: StatefulBuilder(builder: (context, update) {
            return StudyNavigationLayout(
                content: content ??
                    GestureDetector(
                        onTap: onBackgroundTap,
                        behavior: HitTestBehavior.opaque,
                        child: const SizedBox.expand(
                            key: _contentKey,
                            child: ColoredBox(color: _contentColor))),
                destinations: _destinations,
                selectedIndex: selected,
                onSelected: (index) {
                  update(() => selected = index);
                  onSelected?.call(index);
                });
          }))));
  await tester.pumpAndSettle();
}

Future<void> _expectContentPixels(WidgetTester tester, List<Offset> points,
    {String? frame}) async {
  final render =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 1);
    final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (final p in points) {
      final i = (p.dy.floor() * image.width + p.dx.floor()) * 4;
      final expected = [
        _contentColor.red,
        _contentColor.green,
        _contentColor.blue,
      ];
      for (var channel = 0; channel < 3; channel++) {
        // A real elevation-3 shadow may tint a pixel just outside the capsule.
        expect(raw.getUint8(i + channel), closeTo(expected[channel], 2),
            reason: '真实内容应绘制在Dock外部 $p，不能只是透明的空白占位');
      }
      expect(raw.getUint8(i + 3), 255);
    }
    if (frame != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('../dock-frames/$frame.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    }
    image.dispose();
  });
}

void main() {
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Windows $scale：正文真实绘制到Dock上方/下方/左侧', (tester) async {
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        await _mount(tester, scale: scale, dark: scale > 1);
        final content = tester.getRect(find.byKey(_contentKey));
        final shell = tester.getRect(_capsule);
        expect(content, const Rect.fromLTWH(0, 0, 1000, 700));
        await _expectContentPixels(
            tester,
            [
              Offset(shell.center.dx, 32),
              Offset(shell.center.dx, 668),
              Offset(2, shell.center.dy),
            ],
            frame: 'windows-exterior-$scale');
      } finally {
        debugDisableShadows = oldShadows;
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows：Dock外部及透明圆角点击正文，壳内空白拦截', (tester) async {
    var backgroundTaps = 0, selected = -1;
    await _mount(tester,
        onBackgroundTap: () => backgroundTaps++,
        onSelected: (value) => selected = value);
    final shell = tester.getRect(_capsule);
    for (final p in [
      Offset(shell.center.dx, shell.top - 20),
      Offset(shell.center.dx, shell.bottom + 20),
      Offset(shell.left - 4, shell.center.dy),
      shell.topLeft + const Offset(1, 1),
    ]) {
      await tester.tapAt(p);
      await tester.pump();
    }
    expect(backgroundTaps, 4, reason: '正文须真的覆盖原左侧band，圆角包围盒外也不能吞点');
    await tester.tapAt(shell.topCenter + const Offset(0, 5));
    await tester.pump();
    expect(backgroundTaps, 4, reason: '胶囊可见内部的空白仍应挡住正文');
    await tester.tapAt(tester.getCenter(_icon(1)));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(backgroundTaps, 4);
  });

  testWidgets('Windows：悬停只展开Dock，正文/图标不位移，展开外部仍能点击', (tester) async {
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = oldShadows);
    var backgroundTaps = 0;
    await _mount(tester, onBackgroundTap: () => backgroundTaps++);
    final bodyRect = tester.getRect(find.byKey(_contentKey));
    final iconCenter = tester.getCenter(_icon(0));
    final closedWidth = tester.getSize(_capsule).width;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 20));
    await mouse.moveTo(tester.getCenter(_capsule));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(_capsule).width, greaterThan(closedWidth));
    expect(tester.getRect(find.byKey(_contentKey)), bodyRect);
    expect((tester.getCenter(_icon(0)) - iconCenter).distance, lessThan(.01));
    await tester.pumpAndSettle();
    final expanded = tester.getRect(_capsule);
    await tester.tapAt(expanded.topLeft + const Offset(1, 1));
    await tester.pump();
    expect(backgroundTaps, 1);
    await _expectContentPixels(
        tester,
        [
          Offset(expanded.center.dx, expanded.top - 24),
          Offset(expanded.center.dx, expanded.bottom + 24),
        ],
        frame: 'windows-hover-exterior');
    await mouse.moveTo(const Offset(800, 20));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(tester.getSize(_capsule).width, closeTo(closedWidth, .01));
    expect(tester.getRect(find.byKey(_contentKey)), bodyRect);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    debugDisableShadows = oldShadows;
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows：宽窄反向过程中持续全文宽，正文和滚动State保留', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester,
        size: const Size(800, 700),
        content: ListView.builder(
            key: _contentKey,
            controller: controller,
            itemExtent: 60,
            itemCount: 100,
            itemBuilder: (_, i) => Text('可滚动课堂内容 $i')));
    controller.jumpTo(320);
    await tester.pumpAndSettle();
    final bodyElement = tester.element(find.byKey(_contentKey));
    final shellElement = tester.element(_capsule);
    final scrollFinder = find.descendant(
        of: find.byKey(_contentKey), matching: find.byType(Scrollable));
    final scrollState = tester.state<ScrollableState>(scrollFinder);
    for (final width in [1000.0, 800.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 700);
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.getRect(find.byKey(_contentKey)),
            Rect.fromLTWH(0, 0, width, 700));
        expect(identical(bodyElement, tester.element(find.byKey(_contentKey))),
            isTrue);
        expect(identical(shellElement, tester.element(_capsule)), isTrue);
        expect(
            identical(scrollState, tester.state<ScrollableState>(scrollFinder)),
            isTrue);
        expect(controller.offset, 320);
      }
    }
    await tester.pumpAndSettle();
    expect(tester.getRect(_capsule).left, lessThan(25));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows 320%短窗：穿透正文后仍可键盘到末项并执行语义tap', (tester) async {
    var selected = -1, backgroundTaps = 0;
    await _mount(tester,
        size: const Size(1000, 230),
        scale: 3.2,
        reduce: true,
        onBackgroundTap: () => backgroundTaps++,
        onSelected: (value) => selected = value);
    final semantics = tester.ensureSemantics();
    await tester.tapAt(const Offset(2, 115));
    await tester.pump();
    expect(backgroundTaps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(
        tester.getRect(_capsule).contains(tester.getCenter(_icon(3))), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 3);
    final node = tester.getSemantics(find.bySemanticsLabel('设置'));
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    tester.binding.rootPipelineOwner.semanticsOwner!
        .performAction(node.id, ui.SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(selected, 3);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('手机200%：底栏外侧仍透明可点，安全尾部使最后按钮可达', (tester) async {
    var lastTaps = 0, backgroundTaps = 0;
    await _mount(tester,
        size: const Size(390, 844),
        scale: 2,
        platform: TargetPlatform.android,
        safe: const EdgeInsets.only(top: 24, bottom: 34),
        content: Builder(builder: (context) {
      return GestureDetector(
          onTap: () => backgroundTaps++,
          child: ColoredBox(
              color: _contentColor,
              child: ListView(
                  key: _contentKey,
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom + 12),
                  children: [
                    const SizedBox(height: 1100),
                    SizedBox(
                        height: 56,
                        child: TextButton(
                            key: const ValueKey('last-content-action'),
                            onPressed: () => lastTaps++,
                            child: const Text('最后操作'))),
                  ])));
    }));
    final shell = tester.getRect(_capsule);
    await tester.tapAt(Offset(2, shell.center.dy));
    await tester.pump();
    expect(backgroundTaps, 1);
    await _expectContentPixels(tester, [Offset(2, shell.center.dy)]);
    final scroll = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(_contentKey), matching: find.byType(Scrollable)));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('last-content-action'));
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(shell.top));
    await tester.tap(last);
    await tester.pump();
    expect(lastTaps, 1);
    expect(tester.takeException(), isNull);
  });
}
