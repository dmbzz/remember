import 'dart:ui' show SemanticsAction;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/motion.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置')
];

void _view(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('独立评审：语义按钮能通过真正tap action切换目的地', (tester) async {
    _view(tester, const Size(390, 844));
    final semantics = tester.ensureSemantics();
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.android),
        home: StatefulBuilder(builder: (context, update) {
          return StudyNavigationLayout(
              content: const Text('背景内容'),
              destinations: _destinations,
              selectedIndex: selected,
              onSelected: (i) => update(() => selected = i));
        })));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp('^${_destinations[i].$3}\$')));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
          reason: '语义按钮${_destinations[i].$3}不能只是标签和button标志');
      tester.binding.pipelineOwner.semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(selected, i);
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('独立评审：透明圆角点击穿透，壳内空白不误点背景', (tester) async {
    _view(tester, const Size(390, 844));
    var backgroundTaps = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.android),
        home: StudyNavigationLayout(
            content: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
                child: const SizedBox.expand()),
            destinations: _destinations,
            selectedIndex: 1,
            onSelected: (_) {})));
    await tester.pumpAndSettle();
    final shell = tester.getRect(
        find.byKey(const ValueKey('touch-orientation-capsule')));
    await tester.tapAt(shell.topLeft + const Offset(1, 1));
    await tester.pump();
    expect(backgroundTaps, 1, reason: '外壳圆角包围盒中的透明角应穿透');
    await tester.tapAt(shell.topCenter + const Offset(0, 5));
    await tester.pump();
    expect(backgroundTaps, 1, reason: '外壳可见空白应拦住背后内容点击');
  });

  testWidgets('独立评审：选择动画中开启系统减少动画，同帧停到正确目的地', (tester) async {
    _view(tester, const Size(844, 390));
    var selected = 0, reduce = false;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.android),
        home: StatefulBuilder(builder: (context, set) {
          update = set;
          return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: StudyNavigationLayout(
                  content: const Text('内容'),
                  destinations: _destinations,
                  selectedIndex: selected,
                  onSelected: (i) => set(() => selected = i)));
        })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    update(() => reduce = true);
    await tester.pump();
    final lens = tester.getCenter(find.byKey(const ValueKey('navigation-lens')));
    final item = tester.getCenter(find.byKey(const ValueKey('capsule-item-3')));
    expect((lens - item).distance, lessThan(.01));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立评审：320%矮横屏键盘可到达并激活设置', (tester) async {
    _view(tester, const Size(960, 230));
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme.copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(3.2),
                disableAnimations: true),
            child: child!),
        home: StatefulBuilder(builder: (context, update) {
          return StudyNavigationLayout(
              content: const Text('内容'),
              destinations: _destinations,
              selectedIndex: selected,
              onSelected: (i) => update(() => selected = i));
        })));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 3);
    final shell = tester.getRect(
        find.byKey(const ValueKey('touch-orientation-capsule')));
    final last = tester.getRect(find.byKey(const ValueKey('capsule-item-3')));
    expect(shell.contains(last.center), isTrue,
        reason: '焦点到最后入口时，滚动应将入口带进可见壳体');
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立评审：当前已选设置进入320%矮横屏后自动保持可见', (tester) async {
    _view(tester, const Size(960, 230));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme.copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(3.2),
                disableAnimations: true),
            child: child!),
        home: StudyNavigationLayout(
            content: const Text('设置内容'),
            destinations: _destinations,
            selectedIndex: 3,
            onSelected: (_) {})));
    await tester.pumpAndSettle();
    final shell = tester.getRect(
        find.byKey(const ValueKey('touch-orientation-capsule')));
    final item = tester.getRect(find.byKey(const ValueKey('capsule-item-3')));
    expect(shell.contains(item.center), isTrue,
        reason: '大字滚动回退也应在进入时显示真实当前目的地，不能只从第一个显示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立评审：真实NotesPage旋转和切页后保留查询/滚动且不重新请求', (tester) async {
    _view(tester, const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(loadFonts);
    final api = ApiClient(baseUrl: 'http://notes-review.test');
    var requests = 0, selected = 1;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (req, handler) {
      requests++;
      handler.resolve(Response(requestOptions: req, statusCode: 200, data: {
        'code': 0,
        'data': {
          'items': List.generate(36, (i) => {
                'note_id': 'judge-$i',
                'topic': '测试课堂笔记 $i',
                'course_name': '工程力学',
                'class_date': '2026-10-15'
              }),
          'total': 36
        },
        'message': 'ok'
      }));
    }));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.android),
        home: StatefulBuilder(builder: (context, update) {
          return StudyNavigationLayout(
              destinations: _destinations,
              selectedIndex: selected,
              onSelected: (i) => update(() => selected = i),
              content: StudyTabDeck(index: selected, children: [
                const Text('课表示例'),
                NotesPage(apiClient: api),
                const Text('录音示例'),
                const Text('设置示例')
              ]));
        })));
    await tester.pumpAndSettle();
    final notes = tester.state(find.byType(NotesPage));
    await tester.enterText(find.byType(TextField), '测试');
    await tester.pumpAndSettle();
    final list = find.descendant(
        of: find.byType(NotesPage), matching: find.byType(ListView));
    // Keep the editable field mounted while still checking a real nonzero
    // scroll position, rather than asking a lazily disposed field for its text.
    await tester.drag(list, const Offset(0, -100));
    await tester.pumpAndSettle();
    final scroller = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    final state = tester.state<ScrollableState>(scroller);
    final pixels = state.position.pixels;
    final count = requests;
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capsule-item-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capsule-item-1')));
    await tester.pumpAndSettle();
    expect(identical(notes, tester.state(find.byType(NotesPage))), isTrue);
    final newScroller = find.descendant(
        of: find.descendant(of: find.byType(NotesPage), matching: find.byType(ListView)),
        matching: find.byType(Scrollable)).first;
    expect(identical(state, tester.state<ScrollableState>(newScroller)), isTrue);
    expect(state.position.pixels, closeTo(pixels, .01));
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text ??
        tester.state<EditableTextState>(find.byType(EditableText)).widget.controller.text,
        '测试');
    expect(requests, count);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
