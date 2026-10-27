import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/motion.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置')
];
final _capsule = find.byKey(const ValueKey('touch-orientation-capsule'));
Finder _item(int i) => find.byKey(ValueKey('capsule-item-$i'));

void _view(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('独立Windows：待悬停计时期间开启减动立即采用hover目标', (tester) async {
    _view(tester, const Size(1000, 700));
    var reduce = false;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: StatefulBuilder(builder: (context, set) {
          update = set;
          return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: StudyNavigationLayout(
                  content: const Text('内容'),
                  destinations: _destinations,
                  selectedIndex: 1,
                  onSelected: (_) {}));
        })));
    await tester.pumpAndSettle();
    final closed = tester.getSize(_capsule).width;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 100));
    await mouse.moveTo(tester.getCenter(_capsule));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.getSize(_capsule).width, closed);
    update(() => reduce = true);
    await tester.pump();
    expect(tester.getSize(_capsule).width, greaterThan(closed),
        reason: '系统减动切换不应保留旧70ms等待计时器');
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(700, 100));
    await tester.pump();
    expect(tester.getSize(_capsule).width, closeTo(closed, .01));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立Windows：透明圆角不触发hover，鼠标点后离开收回', (tester) async {
    _view(tester, const Size(1000, 700));
    var selected = 0, backgroundTaps = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: StatefulBuilder(builder: (context, update) {
          return StudyNavigationLayout(
              content: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => backgroundTaps++,
                  child: const SizedBox.expand()),
              destinations: _destinations,
              selectedIndex: selected,
              onSelected: (i) => update(() => selected = i));
        })));
    await tester.pumpAndSettle();
    final closed = tester.getSize(_capsule).width;
    final shell = tester.getRect(_capsule);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 100));
    await mouse.moveTo(shell.topLeft + const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(_capsule).width, closed,
        reason: '透明圆角不是hover矩形的一部分');
    await mouse.moveTo(tester.getCenter(_capsule));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    expect(tester.getSize(_capsule).width, greaterThan(closed));
    await mouse.moveTo(tester.getCenter(_item(1)));
    await mouse.down(tester.getCenter(_item(1)));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    await mouse.moveTo(const Offset(700, 100));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(tester.getSize(_capsule).width, closeTo(closed, .01),
        reason: '鼠标焦点不得像键盘焦点一样把Dock永久钉开');
    expect(backgroundTaps, 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立Windows：真实NotesPage跨899/901保留查询滚动且不重取', (tester) async {
    _view(tester, const Size(899, 700));
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(loadFonts);
    final api = ApiClient(baseUrl: 'http://windows-notes-review.test');
    var requests = 0, selected = 1;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (req, handler) {
      requests++;
      handler.resolve(Response(requestOptions: req, statusCode: 200, data: {
        'code': 0,
        'data': {
          'items': List.generate(36, (i) => {
                'note_id': 'windows-judge-$i',
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
        theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
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
    final list = find.descendant(of: find.byType(NotesPage), matching: find.byType(ListView));
    await tester.drag(list, const Offset(0, -100));
    await tester.pumpAndSettle();
    final scrollFinder = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    final scroller = tester.state<ScrollableState>(scrollFinder), pixels = tester.state<ScrollableState>(scrollFinder).position.pixels;
    final shellElement = tester.element(_capsule);
    final navLabel = find.descendant(of: _capsule, matching: find.text('笔记'));
    final labelElement = tester.element(navLabel);
    final requestCount = requests;
    for (final width in [901.0, 899.0, 901.0, 899.0, 901.0]) {
      tester.view.physicalSize = Size(width, 700);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    expect(identical(notes, tester.state(find.byType(NotesPage))), isTrue);
    expect(identical(scroller, tester.state<ScrollableState>(scrollFinder)), isTrue);
    expect(scroller.position.pixels, closeTo(pixels, .01));
    expect(identical(shellElement, tester.element(_capsule)), isTrue);
    expect(identical(labelElement, tester.element(navLabel)), isTrue);
    expect(tester.state<EditableTextState>(find.byType(EditableText)).widget.controller.text, '测试');
    expect(requests, requestCount);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
