import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.scale = 1, this.reduced = false});
  final double scale;
  final bool reduced;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final anchor = GlobalKey<ScheduleAnchorViewState>();
  final boundary = GlobalKey();
  bool day = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(widget.scale),
              disableAnimations: widget.reduced),
          child: child!),
      home: Scaffold(
          body: RepaintBoundary(
              key: boundary,
              child: ScheduleAnchorView(
                  key: anchor,
                  entries: [
                    for (final weekday in [1, 2, 3, 4, 5, 6, 7])
                      {
                        'id': 'course-$weekday',
                        'weekday': weekday,
                        'course_name': '马克思主义基本原理',
                        'location': '教学楼4-402',
                        'start_time': '08:15',
                        'end_time': '09:50',
                      }
                  ],
                  weekStart: DateTime(2026, 10, 12),
                  today: DateTime(2026, 10, 18),
                  selectedDay: 4,
                  dayMode: day,
                  onSelectDay: (_) {},
                  onOpen: (_) {}))));
}

Finder field(String type) => find.byKey(ValueKey('anchor-$type-course-4'));
Finder get card =>
    find.byKey(const ValueKey('schedule-anchor-course-course-4'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<GlobalKey<_HarnessState>> mount(WidgetTester tester, Size size,
      {double scale = 1, bool reduced = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, scale: scale, reduced: reduced));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> frame(
      WidgetTester tester, GlobalKey<_HarnessState> key, String name) async {
    await tester.runAsync(() async {
      final image = await (key.currentState!.boundary.currentContext!
              .findRenderObject() as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('../text-width-frames')
        ..createSync(recursive: true);
      File('${folder.path}/$name.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('窄窗扩为宽窗后恢复真实文字宽度，与直接宽窗相同 ${scale}x', (tester) async {
      final key = await mount(tester, const Size(420, 900), scale: scale);
      final element = tester.element(field('title'));
      final initialWidth = tester.getSize(field('title')).width;
      final initialCard = tester.getRect(card);
      tester.view.physicalSize = const Size(1900, 900);
      await tester.pump();
      final commandCard = tester.getRect(card);
      for (final pair in [
        (commandCard.left, initialCard.left),
        (commandCard.top, initialCard.top),
        (commandCard.width, initialCard.width),
        (commandCard.height, initialCard.height),
      ]) {
        expect(pair.$1, closeTo(pair.$2, 1e-6), reason: 'resize命令帧仍从当前卡片位置接续');
      }
      await tester.pumpAndSettle();
      final recovered = {
        for (final type in ['title', 'room', 'time'])
          type: tester.getSize(field(type)),
      };
      final recoveredCard = tester.getRect(card);
      await frame(tester, key, 'recovered-${scale}x');
      expect(tester.element(field('title')), same(element));
      expect(recovered['title']!.width, greaterThan(initialWidth * 2),
          reason: '卡片变宽后不能永久沿用窄窗的一字排版预算');
      expect(recovered['title']!.width, greaterThan(recoveredCard.width * .75));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final fresh = await mount(tester, const Size(1900, 900), scale: scale);
      expect(tester.getRect(card), recoveredCard, reason: '行高不应保留已无必要的四行窄字高度');
      for (final type in recovered.keys) {
        expect(tester.getSize(field(type)), recovered[type],
            reason: '$type 扩窗结果须等于直接打开宽窗的排版');
      }
      await frame(tester, fresh, 'fresh-${scale}x');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('同宽度日周切换保留同一文字节点与排版预算', (tester) async {
    final key = await mount(tester, const Size(1900, 900));
    final title = tester.element(field('title'));
    final size = tester.getSize(field('title'));
    for (final mode in [true, false, true, false]) {
      key.currentState!.setState(() => key.currentState!.day = mode);
      await tester.pump();
      for (var tick = 0; tick < 35; tick++) {
        await tester.pump(const Duration(milliseconds: 14));
        expect(tester.element(field('title')), same(title));
        expect(tester.getSize(field('title')), size);
      }
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('减动开启时反复缩窄放大同样释放旧窄预算', (tester) async {
    await mount(tester, const Size(1900, 900), reduced: true);
    final full = tester.getSize(field('title'));
    for (var round = 0; round < 3; round++) {
      tester.view.physicalSize = const Size(420, 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(field('title')).width, lessThan(full.width));
      tester.view.physicalSize = const Size(1900, 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(field('title')), full);
    }
    expect(tester.takeException(), isNull);
  });
}
