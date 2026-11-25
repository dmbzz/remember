import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
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
final shell = find.byKey(const ValueKey('touch-orientation-capsule'));
final lens = find.byKey(const ValueKey('navigation-lens'));
Finder item(int i) => find.byKey(ValueKey('capsule-item-$i'));
final captureKey = GlobalKey();
final samples = <Map<String, Object?>>[];

Future<void> mount(WidgetTester tester,
    {TargetPlatform platform = TargetPlatform.windows,
    Size size = const Size(1100, 740),
    double scale = 1,
    Brightness brightness = Brightness.light,
    bool reduce = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  var selected = 2;
  await tester.pumpWidget(MaterialApp(
      theme: (brightness == Brightness.light
              ? AppTheme.lightTheme
              : AppTheme.darkTheme)
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale), disableAnimations: reduce),
          child: child!),
      home: StatefulBuilder(
          builder: (context, update) => RepaintBoundary(
              key: captureKey,
              child: StudyNavigationLayout(
                  destinations: destinations,
                  selectedIndex: selected,
                  onSelected: (i) => update(() => selected = i),
                  content: const ColoredBox(color: AppTheme.canvas))))));
  await tester.pumpAndSettle();
}

Future<TestGesture> mouseOverShell(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(700, 300));
  await mouse.moveTo(
      Offset(tester.getRect(shell).center.dx, tester.getRect(shell).top + 3));
  await tester.pump(const Duration(milliseconds: 71));
  await tester.pumpAndSettle();
  return mouse;
}

// These strips are inside the visible stadium, above/below its text and icon.
// A real hover/press/focus layer must have one flat fill up to the same contour;
// comparing the output at +3 and +10 exposes an inset second pill directly.
Future<void> checkFill(WidgetTester tester, String name,
    {int tolerance = 3}) async {
  final rect = tester.getRect(lens);
  final image = await tester.runAsync(() =>
      (tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)))
          .toImage(pixelRatio: 1));
  final raw = (await tester
      .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  List<int> rgb(double x, double y) {
    final offset = (y.floor() * image!.width + x.floor()) * 4;
    return [
      raw.getUint8(offset),
      raw.getUint8(offset + 1),
      raw.getUint8(offset + 2)
    ];
  }

  var difference = 0;
  for (var dx = -4; dx <= 4; dx++) {
    for (final bottom in [false, true]) {
      final near =
          rgb(rect.center.dx + dx, bottom ? rect.bottom - 4 : rect.top + 3);
      final inside =
          rgb(rect.center.dx + dx, bottom ? rect.bottom - 11 : rect.top + 10);
      for (var c = 0; c < 3; c++) {
        difference = math.max(difference, (near[c] - inside[c]).abs());
      }
    }
  }
  final folder = Platform.environment['DOCK_LENS_EVIDENCE'];
  samples.add({
    'frame': name,
    'fill_max_channel_delta': difference,
    'lens': [rect.left, rect.top, rect.width, rect.height],
    'top_rgb': rgb(rect.center.dx, rect.top + 3),
    'interior_rgb': rgb(rect.center.dx, rect.top + 10)
  });
  if (folder != null) {
    Directory(folder).createSync(recursive: true);
    final png = await tester
        .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    File('$folder/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    File('$folder/samples.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(samples));
  }
  image!.dispose();
  expect(difference, lessThanOrEqualTo(tolerance),
      reason:
          '$name: feedback must fill the visible capsule through its top/bottom interior; a nested inset pill is visible');
  expect(tester.takeException(), isNull);
}

void visualTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = oldShadows;
    }
  });
}

void main() {
  setUpAll(loadFonts);
  visualTest('独立像素：Windows 展开悬停选中录音不出现内缩灰胶囊', (tester) async {
    await mount(tester);
    final mouse = await mouseOverShell(tester);
    await checkFill(tester, 'windows-open-idle');
    await mouse.moveTo(tester.getCenter(item(2)));
    await tester.pumpAndSettle();
    await checkFill(tester, 'windows-open-hover');
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  visualTest('独立像素：按下与键盘焦点使用同一可见胶囊轮廓', (tester) async {
    await mount(tester);
    final mouse = await mouseOverShell(tester);
    await mouse.moveTo(tester.getCenter(item(2)));
    await mouse.down(tester.getCenter(item(2)));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 200));
    await checkFill(tester, 'windows-open-pressed');
    await mouse.up();
    await mouse.moveTo(
        Offset(tester.getRect(shell).center.dx, tester.getRect(shell).top + 3));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final focus = tester.widget<InkResponse>(find.descendant(
        of: item(2),
        matching: find.byWidgetPredicate((w) => w is InkResponse)));
    expect(focus.focusNode!.hasFocus, isTrue);
    await checkFill(tester, 'windows-open-keyboard-focus');
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  visualTest('独立像素：已有悬停层在收起到展开每帧跟随当前胶囊宽度', (tester) async {
    await mount(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 300));
    await mouse.moveTo(tester.getCenter(item(2)));
    await tester.pump(const Duration(milliseconds: 60));
    await checkFill(tester, 'windows-hover-before-expand');
    for (final ms in [30, 50, 70, 80]) {
      await tester.pump(Duration(milliseconds: ms));
      await checkFill(tester, 'windows-hover-expand-$ms');
    }
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  visualTest('独立像素：200% 字号深色悬停与缩放不截断反馈层', (tester) async {
    await mount(tester, scale: 2, brightness: Brightness.dark);
    final mouse = await mouseOverShell(tester);
    await mouse.moveTo(tester.getCenter(item(2)));
    await tester.pumpAndSettle();
    await checkFill(tester, 'windows-dark-large-hover');
    tester.view.physicalSize = const Size(1030, 780);
    await tester.pump();
    await tester.pumpAndSettle();
    await checkFill(tester, 'windows-dark-large-resize');
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  visualTest('独立像素：Android 横向胶囊按压边界一致且点击仍选择目标', (tester) async {
    await mount(tester,
        platform: TargetPlatform.android,
        size: const Size(900, 480),
        reduce: true);
    final touch = await tester.startGesture(tester.getCenter(item(2)));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 200));
    await checkFill(tester, 'android-landscape-pressed');
    await touch.up();
    await tester.pumpAndSettle();
    await tester.tap(item(1));
    await tester.pumpAndSettle();
    expect(tester.getCenter(lens), tester.getCenter(item(1)));
    expect(tester.takeException(), isNull);
  });
}
