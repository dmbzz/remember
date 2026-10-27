import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

Map<String, dynamic> _entry(String id,
        {int day = 4,
        String start = '08:15',
        String end = '09:50',
        String name = '工程力学',
        String room = '教学楼4-402'}) =>
    {
      ...entry(start: start, end: end, weeks: [6, 7]),
      'id': id,
      'weekday': day,
      'course_name': name,
      'location': room
    };
Finder _card(String id, {bool hidden = false}) =>
    find.byKey(ValueKey('schedule-anchor-course-$id'), skipOffstage: !hidden);
Finder _field(String type, String id) =>
    find.byKey(ValueKey('anchor-$type-$id'));

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.entries});
  final List<Map<String, dynamic>> entries;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final anchor = GlobalKey<ScheduleAnchorViewState>();
  bool dayMode = true, reduce = false, tickers = true;
  double scale = 1;
  int day = 4;
  Map<String, dynamic>? opened;
  late List<Map<String, dynamic>> entries = widget.entries;
  void mode(bool value) => setState(() => dayMode = value);
  void change(VoidCallback callback) => setState(callback);
  @override
  Widget build(BuildContext context) => MaterialApp(
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale), disableAnimations: reduce),
          child: child!),
      home: Scaffold(
          body: TickerMode(
              enabled: tickers,
              child: ScheduleAnchorView(
                  key: anchor,
                  entries: entries,
                  weekStart: DateTime(2026, 10, 12),
                  today: DateTime(2026, 10, 15),
                  selectedDay: day,
                  dayMode: dayMode,
                  onSelectDay: (value) => setState(() => day = value),
                  onOpen: (value) => opened = value))));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<_HarnessState> mount(
      WidgetTester tester, List<Map<String, dynamic>> entries,
      {Size size = const Size(760, 650)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, entries: entries));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('独立：490ms双向端点与25/50/75%反向保留当帧和速度', (tester) async {
    final h = await mount(tester, [_entry('a'), _entry('other', day: 2)]);
    final state = h.anchor.currentState!;
    final start = tester.getRect(_card('a'));
    final titleElement = tester.element(_field('title', 'a'));
    for (final time in [122, 245, 367]) {
      h.mode(false);
      await tester.pump();
      await tester.pump(Duration(milliseconds: time));
      final p = state.debugProgress, v = state.debugVelocity;
      final rect = tester.getRect(_card('a'));
      h.mode(true);
      await tester.pump();
      expect(state.debugProgress, closeTo(p, 1e-9));
      expect(state.debugVelocity, closeTo(v, 1e-6));
      expect(tester.getRect(_card('a')), rect);
      await tester.pumpAndSettle();
      expect(tester.getRect(_card('a')), start);
    }
    h.mode(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 489));
    expect(state.debugIsAnimating, isTrue);
    expect(state.debugProgress, lessThan(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(state.debugProgress, 1);
    expect(state.debugIsAnimating, isFalse);
    await tester.pumpAndSettle();
    h.mode(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 489));
    expect(state.debugIsAnimating, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(state.debugProgress, 0);
    expect(state.debugIsAnimating, isFalse);
    await tester.pumpAndSettle();
    expect(tester.element(_field('title', 'a')), same(titleElement));
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立：字段逐帧不互盖，单卡文字节点/尺寸连续且不越卡', (tester) async {
    final h = await mount(
        tester,
        [
          _entry('a', name: '工程力学中的空间一般力系及其平衡条件专题', room: '机械楼第二实验中心4-402'),
          _entry('b', start: '10:05', end: '11:40'),
        ],
        size: const Size(500, 600));
    h.change(() => h.scale = 2);
    await tester.pumpAndSettle();
    final sizes = {
      for (final type in ['title', 'room', 'time'])
        type: tester.getSize(_field(type, 'a'))
    };
    for (final target in [false, true]) {
      h.mode(target);
      await tester.pump();
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 14));
        for (final id in ['a', 'b']) {
          final outer = tester.getRect(_card(id));
          final fields = [
            for (final type in ['title', 'room', 'time'])
              tester.getRect(_field(type, id))
          ];
          for (var a = 0; a < fields.length; a++) {
            expect(outer.inflate(.1).contains(fields[a].topLeft), isTrue);
            expect(outer.inflate(.1).contains(fields[a].bottomRight), isTrue);
            for (var b = a + 1; b < fields.length; b++) {
              expect(fields[a].overlaps(fields[b]), isFalse,
                  reason: '$id fields $a/$b frame $i');
            }
          }
        }
        for (final type in sizes.keys) {
          expect(tester.getSize(_field(type, 'a')), sizes[type]);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('独立：课内比例、14:15/19:30真实端点及重叠lane不虚构节次', (tester) async {
    final h = await mount(tester, [
      _entry('base'),
      _entry('fraction', start: '08:37', end: '09:23'),
      _entry('afternoon', start: '14:15', end: '15:50'),
      _entry('evening', start: '19:30', end: '21:05'),
      _entry('invalid', start: '待定', end: '待定'),
    ]);
    h.mode(false);
    await tester.pumpAndSettle();
    final r = h.anchor.currentState!.debugCourseRects;
    final row = (r['base']!.height + 8) / 2;
    expect(r['fraction']!.top - r['base']!.top, closeTo(row * 22 / 45, .01));
    expect(r['afternoon']!.top - r['base']!.top, closeTo(row * 4, .01));
    expect(r['evening']!.top - r['base']!.top, closeTo(row * 8, .01));
    expect(r['base']!.overlaps(r['fraction']!), isFalse);
    expect(_card('invalid'), findsNothing);
    h.mode(true);
    await tester.pumpAndSettle();
    expect(_card('invalid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立：隐藏课程排除焦点/语义，字号中断/减动/同id元数据更新可操作', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await mount(
        tester, [_entry('a'), _entry('hidden', day: 2, name: '不可见课程')]);
    expect(find.bySemanticsLabel(RegExp('不可见课程')), findsNothing);
    final hiddenInk = tester.widget<InkWell>(find.descendant(
        of: _card('hidden', hidden: true),
        matching: find.byType(InkWell, skipOffstage: false),
        skipOffstage: false));
    hiddenInk.focusNode!.requestFocus();
    await tester.pump();
    expect(hiddenInk.focusNode!.hasFocus, isFalse);
    h.mode(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    h.change(() => h.scale = 2);
    await tester.pumpAndSettle();
    expect(h.anchor.currentState!.debugProgress, 1);
    expect(h.anchor.currentState!.debugIsAnimating, isFalse);
    expect(find.bySemanticsLabel(RegExp('不可见课程')), findsOneWidget);
    h.mode(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    h.change(() => h.reduce = true);
    await tester.pumpAndSettle();
    expect(h.anchor.currentState!.debugProgress, 0);
    expect(h.anchor.currentState!.debugIsAnimating, isFalse);
    h.change(() => h.reduce = false);
    await tester.pump();
    h.mode(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    h.change(() => h.tickers = false);
    await tester.pumpAndSettle();
    expect(h.anchor.currentState!.debugProgress, 1);
    expect(h.anchor.currentState!.debugIsAnimating, isFalse);
    h.change(() => h.tickers = true);
    await tester.pump();
    expect(h.anchor.currentState!.debugProgress, 1);
    expect(h.anchor.currentState!.debugIsAnimating, isFalse);
    h.mode(true);
    await tester.pumpAndSettle();
    h.change(() => h.entries = [
          {..._entry('a'), 'auto_record': true},
          _entry('hidden', day: 2, name: '不可见课程')
        ]);
    await tester.pumpAndSettle();
    await tester.tap(_card('a'));
    expect(h.opened!['auto_record'], isTrue);
    h.change(() => h.day = 7);
    await tester.pumpAndSettle();
    expect(find.text('这一天没有课程，可切换整周查看。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('独立：真实page同步同id后悬浮详情和调课数据来自新snapshot', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    final entries = [_entry('refresh', day: 5, name: '刷新前课程', room: '旧教室')];
    final api = mockApi(entries);
    addTearDown(() => api.dio.close());
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: SchedulePage(
            apiClient: api, referenceDate: DateTime(2026, 10, 9))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当天'));
    await tester.pumpAndSettle();
    await tester.tap(_card('refresh'));
    await tester.pumpAndSettle();
    final detail = find.byKey(const ValueKey('schedule-floating-details'));
    final rect = tester.getRect(detail);
    entries[0] = _entry('refresh',
        day: 5, start: '14:15', end: '15:50', name: '刷新后课程', room: '新教室');
    await tester.tap(find.byTooltip('课表设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步课表'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: detail, matching: find.text('刷新后课程')),
        findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('新教室')),
        findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('14:15 — 15:50')),
        findsOneWidget);
    expect(find.text('刷新前课程'), findsNothing);
    expect(tester.getRect(detail), rect);
    await tester.tap(find.text('调课到…'));
    await tester.pumpAndSettle();
    expect(find.text('刷新后课程 · 2026年10月9日'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
