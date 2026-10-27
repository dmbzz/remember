import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

Map<String, dynamic> _course(String id,
        {int day = 4,
        String start = '14:15',
        String end = '15:50',
        String name = '工程力学空间力系及其平衡条件'}) =>
    {
      'id': id,
      'weekday': day,
      'course_name': name,
      'start_time': start,
      'end_time': end,
      'location': '教学楼4-402',
    };

Finder _card(String id) => find.byKey(ValueKey('schedule-anchor-course-$id'));
Finder _field(String type, String id) =>
    find.byKey(ValueKey('anchor-$type-$id'));

class _Harness extends StatefulWidget {
  const _Harness(
      {super.key, this.startDay, this.scale = 1, this.followClearance = false});
  final bool? startDay;
  final double scale;
  final bool followClearance;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final anchor = GlobalKey<ScheduleAnchorViewState>();
  final focus = FocusNode();
  late double scale = widget.scale;
  bool reduce = false;
  String? opened;
  void accessibility({double? textScale, bool? reduced}) => setState(() {
        scale = textScale ?? scale;
        reduce = reduced ?? reduce;
      });
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale), disableAnimations: reduce),
          child: child!),
      home: Scaffold(body: Builder(builder: (context) {
        final narrow = MediaQuery.sizeOf(context).width < 850;
        Widget schedule(double clearance) => Padding(
            padding: EdgeInsets.only(left: clearance),
            child: ScheduleAnchorView(
                key: anchor,
                // The real page computes a new visible-list snapshot on each
                // build. Preserve geometry while rebinding those entry maps.
                entries: [
                  _course('anchor'),
                  _course('early', start: '08:15', end: '09:50'),
                  _course('late', start: '19:00', end: '20:35'),
                  _course('next', day: 5),
                ],
                weekStart: DateTime(2026, 10, 12),
                today: DateTime(2026, 10, 15),
                selectedDay: 4,
                dayMode: widget.startDay ?? narrow,
                viewportOriginX: clearance,
                onSelectDay: (_) {},
                onOpen: (entry) => opened = '${entry['id']}'));
        return Column(children: [
          SizedBox(height: 48, child: TextField(focusNode: focus)),
          Expanded(
              child: widget.followClearance
                  ? TweenAnimationBuilder<double>(
                      tween: Tween(end: narrow ? 0 : 160),
                      duration: const Duration(milliseconds: 440),
                      curve: Curves.easeInOut,
                      builder: (context, value, _) => schedule(value))
                  : schedule(0))
        ]);
      })));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<_HarnessState> mount(WidgetTester tester,
      {Size size = const Size(1020, 640),
      bool? day,
      double scale = 1,
      bool followClearance = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(
        key: key,
        startDay: day,
        scale: scale,
        followClearance: followClearance));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  ScrollController scroll(WidgetTester tester, String axis) => tester
      .widget<SingleChildScrollView>(
          find.byKey(ValueKey('schedule-anchor-$axis')))
      .controller!;

  testWidgets('自动跨断点从已滚动的同卡同日期接续，连续resize及反向保持p和速度', (tester) async {
    final h = await mount(tester), state = h.anchor.currentState!;
    scroll(tester, 'horizontal').jumpTo(scroll(tester, 'horizontal')
        .position
        .maxScrollExtent
        .clamp(0.0, 100.0));
    scroll(tester, 'vertical').jumpTo(200);
    h.focus.requestFocus();
    await tester.pump();
    final element = tester.element(_card('anchor'));
    final title = tester.element(_field('title', 'anchor'));
    final titleSize = tester.getSize(_field('title', 'anchor'));
    final source = tester.getRect(_card('anchor'));
    final date = find.byKey(const ValueKey('schedule-anchor-day-4'));
    final sourceDate = tester.getRect(date);
    tester.view.physicalSize = const Size(840, 640);
    await tester.pump();
    expect(identical(state, h.anchor.currentState), isTrue);
    expect(state.debugProgress, 1);
    expect(state.debugIsAnimating, isTrue);
    expect(tester.getRect(_card('anchor')), source);
    expect(tester.getRect(date), sourceDate);
    expect(h.focus.hasFocus, isTrue);
    await tester.pump(const Duration(milliseconds: 220));
    expect(state.debugProgress, inExclusiveRange(0, 1));
    expect(tester.getRect(_card('anchor')), isNot(source));
    final rect = tester.getRect(_card('anchor'));
    final p = state.debugProgress, velocity = state.debugVelocity;
    tester.view.physicalSize = const Size(820, 640);
    await tester.pump();
    expect(state.debugProgress, closeTo(p, 1e-9));
    expect(state.debugVelocity, closeTo(velocity, 1e-6));
    expect(tester.getRect(_card('anchor')), rect);
    final currentDate = tester.getRect(date);
    tester.view.physicalSize = const Size(870, 640);
    await tester.pump();
    expect(state.debugProgress, closeTo(p, 1e-9));
    expect(state.debugVelocity, closeTo(velocity, 1e-6));
    expect(tester.getRect(_card('anchor')), rect);
    expect(tester.getRect(date), currentDate);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(state.debugIsAnimating, isFalse);
    expect(identical(element, tester.element(_card('anchor'))), isTrue);
    expect(identical(title, tester.element(_field('title', 'anchor'))), isTrue);
    expect(tester.getSize(_field('title', 'anchor')).width,
        lessThanOrEqualTo(titleSize.width + .01));
    expect(state.debugWeekOffset, const Offset(0, 200));
    expect(h.focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同模式resize平滑重排且字段预算收敛到七列可用宽度', (tester) async {
    final h = await mount(tester, size: const Size(760, 640), day: true),
        state = h.anchor.currentState!;
    final sizes = {
      for (final type in ['title', 'room', 'time'])
        type: tester.getSize(_field(type, 'anchor'))
    };
    final source = tester.getRect(_card('anchor'));
    tester.view.physicalSize = const Size(600, 640);
    await tester.pump();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isTrue);
    expect(tester.getRect(_card('anchor')), source);
    await tester.pump(const Duration(milliseconds: 150));
    final middle = tester.getRect(_card('anchor'));
    expect(middle.width, lessThan(source.width));
    expect(middle.width, greaterThan(600 - 36));
    tester.view.physicalSize = const Size(620, 640);
    await tester.pump();
    expect(tester.getRect(_card('anchor')), middle);
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(const Duration(milliseconds: 70));
      for (final entry in sizes.entries) {
        expect(tester.getSize(_field(entry.key, 'anchor')).width,
            lessThanOrEqualTo(entry.value.width + .01));
      }
    }
    await tester.pumpAndSettle();
    expect(tester.getRect(_card('anchor')).width, closeTo(620 - 36, .01));
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生size媒体依赖不终止动效，大字安全终态，减动立即停止重排', (tester) async {
    final h = await mount(tester), state = h.anchor.currentState!;
    tester.view.physicalSize = const Size(840, 640);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final p = state.debugProgress;
    tester.view.physicalSize = const Size(830, 620);
    await tester.pump();
    expect(state.debugProgress, closeTo(p, 1e-9));
    expect(state.debugIsAnimating, isTrue);
    h.accessibility(textScale: 2);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    final titleSize = tester.getSize(_field('title', 'anchor'));
    tester.view.physicalSize = const Size(1000, 620);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.debugProgress, inExclusiveRange(0, 1));
    expect(tester.getSize(_field('title', 'anchor')).width,
        lessThanOrEqualTo(titleSize.width + .01));
    h.accessibility(reduced: true);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 1);
    expect(state.debugIsAnimating, isFalse);
    expect(tester.getSize(_field('title', 'anchor')).width,
        lessThanOrEqualTo(titleSize.width + .01));
    tester.view.physicalSize = const Size(800, 620);
    await tester.pumpAndSettle();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('440ms导航逐帧改变父Padding时全局来源连续，490ms同步完整到位', (tester) async {
    final h = await mount(tester,
            size: const Size(1000, 900), followClearance: true),
        state = h.anchor.currentState!;
    final element = tester.element(_card('anchor'));
    final title = tester.element(_field('title', 'anchor'));
    final titleSize = tester.getSize(_field('title', 'anchor'));
    final source = tester.getRect(_card('anchor'));
    tester.view.physicalSize = const Size(840, 900);
    await tester.pump();
    expect(tester.getRect(_card('anchor')), source);
    for (var elapsed = 16; elapsed <= 480; elapsed += 16) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(_card('anchor')).left, greaterThanOrEqualTo(0),
          reason: 'card at ${elapsed}ms');
      expect(tester.getRect(_field('time', 'anchor')).left,
          greaterThanOrEqualTo(0),
          reason: 'time at ${elapsed}ms');
      expect(tester.getSize(_field('title', 'anchor')).width,
          lessThanOrEqualTo(titleSize.width + .01));
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    final end = tester.getRect(_card('anchor'));
    expect(end.left, closeTo(18, .01));
    expect(end.width, closeTo(840 - 36, .01));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getRect(_card('anchor')), end);
    expect(identical(element, tester.element(_card('anchor'))), isTrue);
    expect(identical(title, tester.element(_field('title', 'anchor'))), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('整周扩大到无横向滚动时从原可见位置接续，并保留真实网格和字段', (tester) async {
    final h = await mount(tester, size: const Size(1000, 640), day: false),
        state = h.anchor.currentState!;
    scroll(tester, 'horizontal').jumpTo(scroll(tester, 'horizontal')
        .position
        .maxScrollExtent
        .clamp(0.0, 100.0));
    scroll(tester, 'vertical').jumpTo(150);
    await tester.pump();
    final source = tester.getRect(_card('anchor'));
    final title = tester.element(_field('title', 'anchor'));
    final titleSize = tester.getSize(_field('title', 'anchor'));
    tester.view.physicalSize = const Size(1400, 640);
    await tester.pump();
    expect(tester.getRect(_card('anchor')), source);
    expect(state.debugProgress, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(_card('anchor')), isNot(source));
    await tester.pumpAndSettle();
    expect(state.debugWeekOffset, const Offset(0, 150));
    expect(scroll(tester, 'horizontal').offset, 0);
    expect(tester.getRect(_card('anchor')).left,
        closeTo(60 + 3 * ((1400 - 60) / 7) + 4, .01));
    expect(identical(title, tester.element(_field('title', 'anchor'))), isTrue);
    final expandedTitle = tester.getSize(_field('title', 'anchor'));
    expect(expandedTitle.width, greaterThan(titleSize.width));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await mount(tester, size: const Size(1400, 640), day: false);
    expect(tester.getSize(_field('title', 'anchor')), expandedTitle,
        reason: '扩窗文字预算须等于同尺寸冷启动，不能固化最窄历史宽度');
    expect(tester.takeException(), isNull);
  });
}
