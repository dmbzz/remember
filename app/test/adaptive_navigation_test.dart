import 'dart:io';
import 'dart:ui' as ui;
import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/motion.dart';
import 'package:class_notes_assistant/core/orientation_capsule.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'fixtures/legacy_windows_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'note_rendering_test.dart' show loadFonts;

const destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置')
];

void main() {
  for (final width in [844.0, 960.0]) {
    testWidgets('旋转同壳同文字，保留页面State/滚动，并能中途切页 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.android),
          home: StatefulBuilder(
              builder: (context, update) => StudyNavigationLayout(
                  destinations: destinations,
                  selectedIndex: selected,
                  onSelected: (i) => update(() => selected = i),
                  content: StudyTabDeck(index: selected, children: [
                    const Text('课表内容'),
                    ListView.builder(
                        key: const ValueKey('note-list'),
                        itemCount: 100,
                        itemExtent: 60,
                        itemBuilder: (_, i) => Text('笔记内容 $i')),
                    const Text('录音内容'),
                    const Text('设置内容')
                  ])))));
      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      await tester.drag(
          find.byKey(const ValueKey('note-list')), const Offset(0, -360));
      await tester.pumpAndSettle();
      final list = find.descendant(
          of: find.byKey(const ValueKey('note-list'), skipOffstage: false),
          matching: find.byType(Scrollable, skipOffstage: false),
          skipOffstage: false);
      final state = tester.state<ScrollableState>(list),
          scroll = tester.state<ScrollableState>(list).position.pixels;
      final shell = tester
          .element(find.byKey(const ValueKey('touch-orientation-capsule')));
      final texts =
          destinations.map((d) => tester.element(find.text(d.$3))).toList();
      tester.view.physicalSize = Size(width, 390);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(
          identical(
              shell,
              tester.element(
                  find.byKey(const ValueKey('touch-orientation-capsule')))),
          isTrue);
      for (var i = 0; i < 4; i++) {
        expect(
            identical(texts[i], tester.element(find.text(destinations[i].$3))),
            isTrue);
      }
      final before = tester
          .getRect(find.byKey(const ValueKey('touch-orientation-capsule')));
      await tester.tap(find.text('录音'));
      await tester.pump();
      expect(
          tester
              .getRect(find.byKey(const ValueKey('touch-orientation-capsule'))),
          before);
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(find.byType(WindowsHoverDock), findsNothing);
      expect(identical(state, tester.state<ScrollableState>(list)), isTrue);
      expect(state.position.pixels, scroll);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      tester.view.physicalSize = Size(width, 390);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
          identical(
              shell,
              tester.element(
                  find.byKey(const ValueKey('touch-orientation-capsule')))),
          isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  for (final scale in [2.0, 3.2]) {
    testWidgets('大字号短横屏四项仍可达，减动即时 $scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 230);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme.copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(scale)),
              child: child!),
          home: StatefulBuilder(
              builder: (context, update) => StudyNavigationLayout(
                  content: const Text('内容'),
                  destinations: destinations,
                  selectedIndex: selected,
                  onSelected: (i) => update(() => selected = i)))));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('capsule-vertical-scroll')),
          const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pump();
      expect(selected, 3);
      // ensureVisible may request one layout frame; reduced motion must not
      // keep an animation ticker running while the scroll position updates.
      expect(await tester.pumpAndSettle(),lessThanOrEqualTo(3));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
  test('中断模型保留当帧位置与速度，440ms到位', () {
    for (final t in [.11, .22, .33]) {
      final first = CapsuleOrientationSimulation(0, 1, 0);
      final reverse = CapsuleOrientationSimulation(first.x(t), 0, first.dx(t));
      expect(reverse.x(0), closeTo(first.x(t), 1e-10));
      expect(reverse.dx(0), closeTo(first.dx(t), 1e-10));
      expect(reverse.x(reverse.seconds), 0);
      expect(reverse.dx(reverse.seconds), 0);
    }
    expect(CapsuleOrientationSimulation(0, 1, 0).seconds, .44);
  });
  test('逐帧完整外壳与触摸目标，无重叠，普通横屏不靠滚动隐藏', () {
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(320, 720)
    ]) {
      for (final scale in [1.0, 2.0, 3.2]) {
        for (var n = 0; n <= 100; n++) {
          final g = ArcCapsuleGeometry.calculate(
              viewport: size,
              safe: const EdgeInsets.only(top: 24, bottom: 20),
              progress: n / 100,
              label: Size(24 * scale, 18 * scale),
              count: 4);
          expect(g.shell.left, greaterThanOrEqualTo(0));
          expect(g.shell.right, lessThanOrEqualTo(size.width));
          expect(g.shell.top, greaterThanOrEqualTo(24));
          expect(g.shell.bottom, lessThanOrEqualTo(size.height - 20));
          expect(g.lensSize.width, greaterThanOrEqualTo(g.lensSize.height));
          for (var i = 0; i < 4; i++) {
            expect(g.itemSize.width, greaterThanOrEqualTo(48));
            expect(g.itemSize.height, greaterThanOrEqualTo(48));
            final one = Rect.fromCenter(
                center: g.centers[i],
                width: g.itemSize.width,
                height: g.itemSize.height);
            for (var j = i + 1; j < 4; j++) {
              final other = Rect.fromCenter(
                  center: g.centers[j],
                  width: g.itemSize.width,
                  height: g.itemSize.height);
              expect(one.overlaps(other), isFalse,
                  reason: '$size/$scale/$n/$i/$j');
            }
          }
          if (scale == 1 && size == const Size(844, 390)) {
            expect(g.scrolls, isFalse, reason: 'normal frame $n');
          }
        }
      }
    }
  });
  testWidgets('正式字体阴影帧：进入、中间、终态、返回及深色大字', (tester) async {
    final shadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = shadows);
    await tester.runAsync(loadFonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const key = ValueKey('orientation-frame');
    var scale = 1.0, dark = false, selected = 1;
    late StateSetter update;
    await tester
        .pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, set) {
      update = set;
      return Theme(
          data: (dark ? AppTheme.darkTheme : AppTheme.lightTheme)
              .copyWith(platform: TargetPlatform.android),
          child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(
                  key: key,
                  child: StudyNavigationLayout(
                      destinations: destinations,
                      selectedIndex: selected,
                      onSelected: (i) => set(() => selected = i),
                      content: ListView(
                          padding: const EdgeInsets.all(24),
                          children: [
                            const Text('笔记',
                                style: TextStyle(
                                    fontSize: 30, fontWeight: FontWeight.w600)),
                            for (final label in ['摩擦与空间力系', '电场强度', '矩阵的秩'])
                              Card(
                                  child: ListTile(
                                      title: Text(label),
                                      subtitle: const Text('课堂资料'))),
                          ])))));
    })));
    Future<void> frame(String name) async {
      await tester.pump();
      final render =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        File('../frames/$name.png')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await tester.pumpAndSettle();
    await frame('portrait');
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump();
    await frame('start');
    await tester.pump(const Duration(milliseconds: 110));
    await frame('quarter');
    await tester.pump(const Duration(milliseconds: 110));
    await frame('middle');
    await tester.pump(const Duration(milliseconds: 110));
    await frame('three-quarter');
    await tester.pumpAndSettle();
    await frame('landscape');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await frame('return-middle');
    await tester.pumpAndSettle();
    await frame('returned');
    tester.view.physicalSize = const Size(844, 390);
    update(() {
      scale = 2;
      dark = true;
    });
    await tester.pumpAndSettle();
    await frame('dark-200-landscape');
    tester.view.physicalSize = const Size(960, 230);
    update(() => scale = 3.2);
    await tester.pumpAndSettle();
    await frame('dark-320-short');
    debugDisableShadows = shadows;
    expect(tester.takeException(), isNull);
  });
}
