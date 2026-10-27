import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

Map<String, dynamic> course(String id,
        {int day = 4,
        String name = '工程力学',
        String start = '08:15',
        String end = '09:50'}) =>
    {
      'id': id,
      'weekday': day,
      'course_name': name,
      'start_time': start,
      'end_time': end,
      'location': '教学楼4-402'
    };

Finder card(String id, {bool offstage = false}) =>
    find.byKey(ValueKey('schedule-anchor-course-$id'), skipOffstage: !offstage);

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.entries, this.scale = 1});
  final List<Map<String, dynamic>> entries;
  final double scale;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool dayMode = true, reduce = false;
  int day = 4;
  String? selected, opened, secondary;
  late List<Map<String, dynamic>> entries = widget.entries;
  final anchor = GlobalKey<ScheduleAnchorViewState>();
  void mode(bool value) => setState(() => dayMode = value);
  void setReduce(bool value) => setState(() => reduce = value);
  void replaceEntries(List<Map<String, dynamic>> value) =>
      setState(() => entries = value);
  void selectDay(int value) => setState(() => day = value);
  @override
  Widget build(BuildContext context) => MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(widget.scale),
              disableAnimations: reduce),
          child: child!),
      home: Scaffold(
          body: ScheduleAnchorView(
              key: anchor,
              entries: entries,
              weekStart: DateTime(2026, 10, 12),
              today: DateTime(2026, 10, 15),
              selectedDay: day,
              selectedEntryId: selected,
              dayMode: dayMode,
              onSelectDay: (value) => setState(() => day = value),
              onOpen: (entry) =>
                  setState(() => selected = opened = '${entry['id']}'),
              onSecondaryTap: (entry, offset) =>
                  secondary = '${entry['id']}')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<_HarnessState> mount(WidgetTester tester,
      {List<Map<String, dynamic>>? entries,
      double scale = 1,
      Size size = const Size(850, 500)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(
        key: key,
        scale: scale,
        entries: entries ??
            [
              course('a'),
              course('b', name: '线性代数', start: '10:05', end: '11:40'),
              course('next', day: 5, name: '普通物理'),
            ]));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('同一课程与三个文字节点贯穿中间帧和当前速度反向', (tester) async {
    final h = await mount(tester), state = h.anchor.currentState!;
    final courseElement = tester.element(card('a'));
    final title = find.byKey(const ValueKey('anchor-title-a'));
    final titleElement = tester.element(title),
        titleSize = tester.getSize(title);
    final start = tester.getRect(card('a'));
    expect(card('next'), findsNothing);
    expect(card('next', offstage: true), findsOneWidget);
    h.mode(false);
    await tester.pump();
    expect(tester.getRect(card('a')), start);
    await tester.pump(const Duration(milliseconds: 140));
    final mid = tester.getRect(card('a'));
    expect(mid, isNot(start));
    final p = state.debugProgress, v = state.debugVelocity;
    h.mode(true);
    await tester.pump();
    expect(state.debugProgress, closeTo(p, 1e-9));
    expect(state.debugVelocity, closeTo(v, 1e-6));
    expect(tester.getRect(card('a')), mid);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(tester.getRect(card('a')), start);
    expect(identical(courseElement, tester.element(card('a'))), isTrue);
    expect(identical(titleElement, tester.element(title)), isTrue);
    expect(tester.getSize(title), titleSize);
    h.mode(false);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(card('next'), findsOneWidget);
    expect(identical(titleElement, tester.element(title)), isTrue);
    expect(tester.getSize(title), titleSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('日周各自实际滚动位置保存，返回从滚动后的来源接续', (tester) async {
    final h = await mount(tester,
        entries: [
          for (var i = 0; i < 7; i++)
            course('item-$i',
                start: i.isEven ? '08:15' : '14:15',
                end: i.isEven ? '09:50' : '15:50'),
          course('next', day: 5),
        ],
        size: const Size(760, 380));
    final state = h.anchor.currentState!;
    ScrollController controller(String axis) => tester
        .widget<SingleChildScrollView>(
            find.byKey(ValueKey('schedule-anchor-$axis')))
        .controller!;
    controller('vertical').jumpTo(260);
    await tester.pump();
    expect(state.debugDayOffset.dy, 260);
    final source = state.debugCourseRects['item-0'];
    h.mode(false);
    await tester.pump();
    expect(state.debugCourseRects['item-0'], source);
    await tester.pumpAndSettle();
    controller('vertical').jumpTo(350);
    controller('horizontal').jumpTo(240);
    await tester.pump();
    final week = state.debugWeekOffset;
    h.mode(true);
    await tester.pumpAndSettle();
    expect(state.debugDayOffset.dy, 260);
    expect(controller('vertical').offset, 260);
    h.mode(false);
    await tester.pumpAndSettle();
    expect(state.debugWeekOffset, week);
    expect(controller('horizontal').offset, week.dx);
    expect(controller('vertical').offset, week.dy);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减动中途开启立即到正确目标并停ticker，重排不伪造旧来源', (tester) async {
    final h = await mount(tester), state = h.anchor.currentState!;
    h.mode(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(state.debugProgress, inExclusiveRange(0, 1));
    h.setReduce(true);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(state.debugIsAnimating, isFalse);
    h.setReduce(false);
    await tester.pump();
    h.mode(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    tester.view.physicalSize = const Size(500, 400);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    h.mode(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    h.replaceEntries([course('replacement')]);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(card('replacement'), findsOneWidget);
    expect(card('a', offstage: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长标题200%窄窗保持字段metrics，重叠课程各有真实lane', (tester) async {
    final h =
        await mount(tester, scale: 2, size: const Size(390, 600), entries: [
      course('long', name: '工程力学中的空间一般力系及其平衡条件专题'),
      course('overlap', start: '09:05', end: '10:50'),
      course('other', day: 2),
    ]);
    final title = find.byKey(const ValueKey('anchor-title-long'));
    final element = tester.element(title), size = tester.getSize(title);
    h.mode(false);
    await tester.pump();
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.getSize(title), size);
      expect(identical(element, tester.element(title)), isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    final rects = h.anchor.currentState!.debugCourseRects;
    expect(rects['long']!.overlaps(rects['overlap']!), isFalse);
    final material = tester.widget<Material>(find
        .descendant(of: card('long'), matching: find.byType(Material))
        .first);
    expect(material.clipBehavior, Clip.antiAlias);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, const BorderRadius.all(Radius.circular(16)));
  });

  testWidgets('同名课程按实体id选中，右键/键盘可用，invalid只在当天可见', (tester) async {
    final h = await mount(tester, entries: [
      course('first'),
      course('second', start: '10:05', end: '11:40'),
      course('invalid', start: '待定', end: '待定'),
      course('other', day: 5)
    ]);
    await tester.tap(card('first'));
    await tester.pump();
    expect(h.opened, 'first');
    final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.down(tester.getCenter(card('first')));
    await mouse.up();
    expect(h.secondary, 'first');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(h.opened, 'first');
    final invalidElement = tester.element(card('invalid'));
    h.mode(false);
    await tester.pumpAndSettle();
    expect(card('invalid'), findsNothing);
    expect(
        identical(
            invalidElement, tester.element(card('invalid', offstage: true))),
        isTrue);
    h.mode(true);
    await tester.pumpAndSettle();
    expect(card('invalid'), findsOneWidget);
    h.selectDay(7);
    await tester.pumpAndSettle();
    expect(find.text('这一天没有课程，可切换整周查看。'), findsOneWidget);
    expect(card('first'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
