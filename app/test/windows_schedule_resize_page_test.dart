import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/schedule/schedule_anchor_view.dart';
import 'package:class_notes_assistant/features/schedule/schedule_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;
import 'schedule_test.dart' show entry, mockApi;

void main() {
  testWidgets('Windows缩窄自动当天、放宽自动整周，手选在当前宽度内有效', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'cna_semester_start': '2026-08-31'});
    await tester.runAsync(loadFonts);
    final api = mockApi([
      {
        ...entry(start: '08:15', end: '09:50', weeks: [6]),
        'id': 'resize-a',
        'weekday': 5,
        'course_name': '工程力学'
      },
      {
        ...entry(start: '10:05', end: '11:40', weeks: [6]),
        'id': 'resize-b',
        'weekday': 3,
        'course_name': '普通物理'
      },
    ]);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: SchedulePage(
            apiClient: api, referenceDate: DateTime(2026, 10, 9))));
    await tester.pumpAndSettle();
    final view = find.byType(ScheduleAnchorView);
    final state = tester.state<ScheduleAnchorViewState>(view);
    final card = find.byKey(const ValueKey('schedule-anchor-course-resize-a'));
    final original = tester.element(card);
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isFalse);
    await tester.tap(find.text('当天'));
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isTrue);
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isTrue,
        reason: '同一个宽度区域内尊重手动选择');
    tester.view.physicalSize = const Size(680, 900);
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isTrue);
    await tester.tap(find.text('整周'));
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isFalse);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isFalse);
    tester.view.physicalSize = const Size(680, 900);
    await tester.pump();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isTrue);
    expect(state.debugProgress, 1, reason: '缩窄命令从实际整周状态开始');
    await tester.pump(const Duration(milliseconds: 170));
    expect(state.debugProgress, inExclusiveRange(0, 1));
    expect(tester.element(card), same(original));
    final p = state.debugProgress;
    final v = state.debugVelocity;
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    expect(state.debugProgress, p);
    expect(state.debugVelocity, closeTo(v, .001));
    await tester.pumpAndSettle();
    expect(tester.widget<ScheduleAnchorView>(view).dayMode, isFalse);
    expect(state.debugProgress, 1);
    expect(tester.element(card), same(original));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
