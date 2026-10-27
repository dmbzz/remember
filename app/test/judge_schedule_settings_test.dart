import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_preferences.dart';
import 'package:class_notes_assistant/features/schedule/schedule_settings_page.dart';
import 'package:class_notes_assistant/features/schedule/schedule_store.dart';
import 'package:class_notes_assistant/features/schedule/timetable_layout.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

const _boundary = ValueKey('judge-settings-boundary');
ScheduleSnapshot _snapshot(
        {bool offline = false,
        List<Map<String, dynamic>>? entries,
        int weeks = 16}) =>
    ScheduleSnapshot(
        entries: entries ?? [],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '大二上',
        offline: offline,
        revision: 7,
        configured: true,
        preferences: SchedulePreferences(semesterWeeks: weeks));

class _Server {
  _Server(this.snapshot,
      {this.failSettings = false,
      this.rejectWrites = false,
      List<Map<String, dynamic>>? courses}) {
    this.courses = courses ??
        [
          {'id': 'known', 'name': '工程力学', 'auto_record': false}
        ];
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      dynamic data;
      if (options.path == '/api/schedule/snapshot') {
        if (failSettings) {
          _reject(options, handler);
          return;
        }
        data = {
          'entries': snapshot.entries,
          'courses': this.courses,
          'preferences': {
            'configured': snapshot.configured,
            'revision': snapshot.revision,
            'settings': {
              ...snapshot.preferences.toJson(),
              'semester_start':
                  snapshot.semesterStart.toIso8601String().substring(0, 10),
              'term_label': snapshot.termLabel
            }
          }
        };
      } else if (options.path == '/api/schedule/settings') {
        if (options.method == 'PUT') {
          settingsWrites.add((options.data as Map).cast<String, dynamic>());
          if (rejectWrites) {
            _reject(options, handler);
            return;
          }
          final saved =
              (options.data['settings'] as Map).cast<String, dynamic>();
          snapshot = ScheduleSnapshot(
              entries: snapshot.entries,
              semesterStart: DateTime.parse(saved['semester_start']),
              updatedAt: DateTime(2026, 10, 17),
              termLabel: saved['term_label'],
              preferences: SchedulePreferences.fromJson(saved),
              configured: true,
              revision: snapshot.revision + 1);
          data = {'revision': snapshot.revision, 'updated_entries': 0};
        } else {
          if (failSettings) {
            _reject(options, handler);
            return;
          }
          data = {
            'configured': snapshot.configured,
            'revision': snapshot.revision,
            'settings': {
              ...snapshot.preferences.toJson(),
              'semester_start':
                  snapshot.semesterStart.toIso8601String().substring(0, 10),
              'term_label': snapshot.termLabel
            }
          };
        }
      } else if (options.path == '/api/schedule/manual') {
        manualWrites.add((options.data as Map).cast<String, dynamic>());
        if (rejectWrites) {
          _reject(options, handler);
          return;
        }
        data = {'revision': snapshot.revision + 1};
      } else if (options.path == '/api/courses') {
        data = this.courses;
      } else if (options.path == '/api/schedule') {
        data = snapshot.entries;
      } else {
        data = <String, dynamic>{};
      }
      handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'code': 0, 'message': 'ok', 'data': data}));
    }));
  }
  final api = ApiClient(baseUrl: 'http://judge-settings.test');
  ScheduleSnapshot snapshot;
  late List<Map<String, dynamic>> courses;
  final bool failSettings;
  bool rejectWrites;
  final settingsWrites = <Map<String, dynamic>>[];
  final manualWrites = <Map<String, dynamic>>[];
  void _reject(RequestOptions options, RequestInterceptorHandler handler) =>
      handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 409, data: {
            'code': 4090,
            'data': null,
            'message': '评审服务器拒绝写入，请重新同步'
          })));
}

Future<void> _mount(WidgetTester tester, _Server server,
    {Size size = const Size(1000, 800),
    double scale = 1,
    bool dark = false,
    bool mobile = false,
    double keyboard = 0,
    bool schedule = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme).copyWith(
              platform:
                  mobile ? TargetPlatform.android : TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: EdgeInsets.only(bottom: keyboard)),
              child: child!),
          home: schedule
              ? SchedulePage(
                  apiClient: server.api, referenceDate: DateTime(2026, 10, 9))
              : ScheduleSettingsPage(
                  api: server.api, snapshot: server.snapshot))));
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 250,
      scrollable: find
          .descendant(
              of: find.byType(ListView).last, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 80);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);
Future<void> _drop(WidgetTester tester, String label, String option) async {
  final finder = find
      .ancestor(of: find.text(label), matching: find.byType(InputDecorator))
      .first;
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
  final item = find.text(option).last;
  if (item.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(item, 150,
        scrollable: find.byType(Scrollable).last, maxScrolls: 30);
    await tester.pumpAndSettle();
  }
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_boundary))
        .toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../review-frames/settings-$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _editor(WidgetTester tester) async {
  await tester.tap(find.text('课程安排'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('新增排课'));
  await tester.pumpAndSettle();
  expect(find.text('新增排课'), findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('独立已同步设置不被旧本机prefs覆盖、12节离线完整恢复', () async {
    const custom = SchedulePreferences(
        semesterWeeks: 20,
        firstWeekOdd: false,
        slots: [
          ...schoolSlots,
          LessonSlot(11, '21:15', '22:00'),
          LessonSlot(12, '22:10', '22:55')
        ]);
    final saved = ScheduleSnapshot(
        entries: [],
        semesterStart: DateTime(2026, 9, 7),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '新学期',
        preferences: custom,
        revision: 10,
        configured: true);
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(saved.toJson()),
      'cna_semester_start': '2026-08-31',
      'cna_widget_term_label': '旧名称'
    });
    final cached = (await ScheduleStore.cached())!;
    expect(cached.semesterStart, DateTime(2026, 9, 7));
    expect(cached.termLabel, '新学期');
    expect(cached.preferences.slots.length, 12);
    expect(cached.preferences.semesterWeeks, 20);
    expect(cached.preferences.firstWeekOdd, isFalse);
    expect(cached.offline, isTrue);
  });

  test('独立settings部分失败不能把新课与旧设置拼成完整在线快照', () async {
    final old = _snapshot();
    SharedPreferences.setMockInitialValues({
      ScheduleStore.cacheKey: jsonEncode(old.toJson()),
      'cna_semester_start': '2026-08-31',
      'cna_widget_term_label': '大二上'
    });
    final server = _Server(
        _snapshot(entries: [
          {
            'id': 'new',
            'weekday': 1,
            'course_id': 'known',
            'start_time': '22:10',
            'end_time': '22:55',
            'weeks': [1]
          }
        ]),
        failSettings: true);
    final result = await ScheduleStore.load(server.api);
    expect(result.offline || result.error != null, isTrue,
        reason: '局部设置失败不能伪装完整新快照并用于提醒重排');
    server.api.dio.close();
  });

  testWidgets('独立10改12保存真实起止/规则/revision，正式字体可见', (tester) async {
    final server = _Server(_snapshot());
    await _mount(tester, server);
    await _drop(tester, '每天的节次数量', '每天 12 节');
    final save = find.byKey(const ValueKey('save-timetable-settings'));
    await _show(tester, save);
    await _capture(tester, 'desktop-save-12');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.settingsWrites.length, 1);
    final written = server.settingsWrites.single;
    expect(written['revision'], 7);
    final settings = written['settings'] as Map;
    expect((settings['slots'] as List).length, 12);
    expect(
        (settings['slots'] as List).last, {'start': '22:10', 'end': '22:55'});
    expect(settings['semester_start'], '2026-08-31');
    expect(settings['semester_weeks'], 16);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  for (final reject in [false, true]) {
    testWidgets('独立390/200%键盘下${reject ? '服务器失败' : '验证失败'}可见并保留draft',
        (tester) async {
      final server = _Server(_snapshot(), rejectWrites: reject);
      await _mount(tester, server,
          size: const Size(390, 844),
          scale: 2,
          mobile: true,
          dark: reject,
          keyboard: 240);
      await tester.enterText(_field('课表名称'), reject ? '我改过的课表' : '');
      final save = find.byKey(const ValueKey('save-timetable-settings'));
      await _show(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final error =
          reject ? find.textContaining('评审服务器拒绝写入') : find.text('请填写课表名称');
      expect(error.hitTestable(), findsWidgets, reason: '底部保存失败后必须看到具体原因');
      await _capture(
          tester, reject ? 'mobile-error-server' : 'mobile-error-validation');
      expect(find.byType(ScheduleSettingsPage), findsOneWidget);
      expect(server.settingsWrites.length, reject ? 1 : 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      server.api.dio.close();
    });
  }

  testWidgets('独立新增排课双周发送明确周次集合', (tester) async {
    final server = _Server(_snapshot(weeks: 4));
    await _mount(tester, server);
    await _editor(tester);
    await _drop(tester, '上课周次规则', '双周');
    final save = find.byKey(const ValueKey('save-manual-schedule'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.manualWrites.single['weeks'], [2, 4]);
    expect(server.manualWrites.single['course_id'], 'known');
    expect(server.manualWrites.single['start_slot'], 1);
    expect(server.manualWrites.single['end_slot'], 1);
    expect(server.manualWrites.single.containsKey('start_time'), isFalse);
    expect(find.byType(ScheduleSettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立编辑缺失course_id不得默认换成另一门课', (tester) async {
    final server = _Server(_snapshot(entries: [
      {
        'id': 'legacy',
        'course_id': 'missing',
        'course_name': '原工程力学',
        'weekday': 1,
        'start_time': '08:15',
        'end_time': '09:00',
        'location': '教学楼4-402',
        'weeks': [1, 3]
      }
    ]));
    await _mount(tester, server);
    await tester.tap(find.text('课程安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原工程力学'));
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('save-manual-schedule'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.manualWrites.any((w) => w['course_id'] == 'known'), isFalse,
        reason: '原ID不可用时不能静默默认到第一门不相干课程');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立离线只看缓存，保存按钮不伪装可写', (tester) async {
    final server = _Server(_snapshot(offline: true));
    await _mount(tester, server);
    final save = find.byKey(const ValueKey('save-timetable-settings'));
    await _show(tester, save);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(server.settingsWrites, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立自选周清空不变每周、错误可见且不提交', (tester) async {
    final server = _Server(_snapshot(weeks: 4));
    await _mount(tester, server);
    await _editor(tester);
    for (var week = 1; week <= 4; week++) {
      final chip = find.widgetWithText(FilterChip, '第 $week 周');
      await _show(tester, chip);
      expect(tester.widget<FilterChip>(chip).selected, isTrue);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    final save = find.byKey(const ValueKey('save-manual-schedule'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.manualWrites, isEmpty);
    expect(find.text('请至少选择一个本学期内的有效周次').hitTestable(), findsWidgets);
    await _capture(tester, 'empty-custom-weeks');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立实际课表12行与第12节课程七列范围不丢失', (tester) async {
    final custom = [
      ...schoolSlots,
      const LessonSlot(11, '21:15', '22:00'),
      const LessonSlot(12, '22:10', '22:55')
    ];
    final snap = ScheduleSnapshot(
        entries: [
          for (var i = 1; i <= 7; i++)
            {
              'id': 'day-$i',
              'course_id': 'known',
              'course_name': '第$i天晚课',
              'weekday': i,
              'period': 12,
              'start_time': '22:10',
              'end_time': '22:55',
              'weeks': [6],
              'confirmed': true,
              'location': '实验楼2-408'
            }
        ],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '12节课表',
        preferences: SchedulePreferences(slots: custom, semesterWeeks: 16),
        configured: true,
        revision: 7);
    final server = _Server(snap);
    await _mount(tester, server, schedule: true, scale: 2, dark: true);
    final view = tester.getRect(find.byType(ScheduleAnchorView));
    final text =
        tester.widget<Text>(find.byKey(const ValueKey('anchor-slot-time-11')));
    expect(text.data, contains('12\n22:10\n22:55'));
    expect(find.byKey(const ValueKey('anchor-slot-time-12')), findsNothing);
    for (var day = 1; day <= 7; day++) {
      final card = tester
          .getRect(find.byKey(ValueKey('schedule-anchor-course-day-$day')));
      expect(card.left, greaterThanOrEqualTo(view.left));
      expect(card.right, lessThanOrEqualTo(view.right));
    }
    final vertical = tester
        .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('schedule-anchor-vertical')))
        .controller!;
    vertical.jumpTo(vertical.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await _capture(tester, 'desktop-200-12th-lesson');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立日周动画中10↔12节安全重排不索引旧行', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(loadFonts);
    late StateSetter update;
    var day = false;
    List<LessonSlot> slots = schoolSlots;
    final state = GlobalKey<ScheduleAnchorViewState>();
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: StatefulBuilder(builder: (context, set) {
          update = set;
          return Scaffold(
              body: ScheduleAnchorView(
                  key: state,
                  entries: const [
                    {
                      'id': 'active',
                      'weekday': 5,
                      'course_name': '工程力学',
                      'location': '教学楼4-402',
                      'start_time': '08:15',
                      'end_time': '09:50'
                    }
                  ],
                  weekStart: DateTime(2026, 10, 5),
                  today: DateTime(2026, 10, 9),
                  selectedDay: 5,
                  dayMode: day,
                  slots: slots,
                  onSelectDay: (_) {},
                  onOpen: (_) {}));
        })));
    await tester.pumpAndSettle();
    update(() => day = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.currentState!.debugIsAnimating, isTrue);
    update(() => slots = [
          ...schoolSlots,
          const LessonSlot(11, '21:15', '22:00'),
          const LessonSlot(12, '22:10', '22:55')
        ]);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('anchor-slot-time-11'), skipOffstage: false),
        findsOneWidget);
    update(() => day = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    update(() => slots = schoolSlots);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('anchor-slot-time-11'), skipOffstage: false),
        findsNothing);
    expect(state.currentState!.debugProgress, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立409后本页刷新保留草稿并使用新revision重试', (tester) async {
    final server = _Server(_snapshot(), rejectWrites: true);
    await _mount(tester, server);
    await tester.enterText(_field('课表名称'), '保留这份草稿');
    await _drop(tester, '每天的节次数量', '每天 12 节');
    final save = find.byKey(const ValueKey('save-timetable-settings'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.settingsWrites.length, 1);
    server.snapshot = ScheduleSnapshot(
        entries: [],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '另一台设备的名称',
        preferences: const SchedulePreferences(semesterWeeks: 16),
        revision: 9,
        configured: true);
    server.rejectWrites = false;
    final scrolling = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(ListView).last, matching: find.byType(Scrollable))
        .first);
    scrolling.position.jumpTo(0);
    await tester.pumpAndSettle();
    final refresh = find.text('重新同步课表');
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_field('课表名称')).controller!.text, '保留这份草稿');
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.settingsWrites.length, 2);
    expect(server.settingsWrites.last['revision'], 9);
    final settings = server.settingsWrites.last['settings'] as Map;
    expect(settings['term_label'], '保留这份草稿');
    expect((settings['slots'] as List).length, 12);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立首周按双周时单周文案与生成周集一致', (tester) async {
    final snap = ScheduleSnapshot(
        entries: [
          {
            'id': 'parity',
            'course_id': 'known',
            'course_name': '工程力学',
            'weekday': 1,
            'start_time': '08:15',
            'end_time': '09:00',
            'weeks': [2, 4],
            'location': '教学楼4-402'
          }
        ],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '反置单双周',
        revision: 7,
        configured: true,
        preferences: const SchedulePreferences(
            semesterWeeks: 4, firstWeekOdd: false, defaultRule: 'odd'));
    final server = _Server(snap);
    await _mount(tester, server);
    await tester.tap(find.text('课程安排'));
    await tester.pumpAndSettle();
    expect(find.textContaining('单周 2-4'), findsOneWidget);
    await _capture(tester, 'parity-list');
    await _editor(tester);
    final save = find.byKey(const ValueKey('save-manual-schedule'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.manualWrites.single['weeks'], [2, 4]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });

  testWidgets('独立新课程11-12节切自定时间不退回08:15', (tester) async {
    final custom = [
      ...schoolSlots,
      const LessonSlot(11, '21:15', '22:00'),
      const LessonSlot(12, '22:10', '22:55')
    ];
    final snap = ScheduleSnapshot(
        entries: [],
        semesterStart: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 10, 17),
        termLabel: '12节课表',
        revision: 7,
        configured: true,
        preferences: SchedulePreferences(slots: custom, semesterWeeks: 4));
    final server = _Server(snap);
    await _mount(tester, server);
    await _editor(tester);
    await tester.tap(find.text('新建课程'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('课程名称'), '实验物理');
    await _drop(tester, '上课星期', '星期五');
    await _drop(tester, '开始节次', '11');
    await _drop(tester, '结束节次', '12');
    final customSwitch = find.widgetWithText(SwitchListTile, '单独设置本课时间');
    await _show(tester, customSwitch);
    await tester.tap(customSwitch);
    await tester.pumpAndSettle();
    expect(find.text('开始 21:15'), findsOneWidget,
        reason: '启用独立时间应沿用当前所选节次，不应静默改成第1节08:15');
    expect(find.text('结束 22:55'), findsOneWidget);
    await _show(tester, _field('教室 / 地点'));
    await tester.enterText(_field('教室 / 地点'), '实验楼4-402');
    await _drop(tester, '上课周次规则', '单周');
    final save = find.byKey(const ValueKey('save-manual-schedule'));
    await _show(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final sent = server.manualWrites.single;
    expect(sent['course_name'], '实验物理');
    expect(sent.containsKey('course_id'), isFalse);
    expect(sent['weekday'], 5);
    expect(sent['start_slot'], 11);
    expect(sent['end_slot'], 12);
    expect(sent['start_time'], '21:15');
    expect(sent['end_time'], '22:55');
    expect(sent['weeks'], [1, 3]);
    expect(sent['location'], '实验楼4-402');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    server.api.dio.close();
  });
}
