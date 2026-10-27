import 'package:class_notes_assistant/core/glass_navigation.dart';
import 'package:class_notes_assistant/core/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];

void main() {
  for (final desktop in [false, true]) {
    testWidgets('选中胶囊连续移动，快速反向点击能正确归位 $desktop', (tester) async {
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(
          width: desktop ? 218 : 360,
          child: StatefulBuilder(
              builder: (context, update) => GlassNavigationGroup(
                  destinations: destinations,
                  selectedIndex: selected,
                  desktop: desktop,
                  onSelected: (index) => update(() => selected = index))),
        ),
      ))));
      final lens = find.byKey(const ValueKey('navigation-lens'));
      final start = tester.getTopLeft(lens);
      await tester.tap(find.text('笔记'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final midway = tester.getTopLeft(lens);
      expect(desktop ? midway.dy : midway.dx,
          greaterThan(desktop ? start.dy : start.dx));
      expect(desktop ? midway.dy - start.dy : midway.dx - start.dx,
          lessThan(desktop ? 64 : 90));
      await tester.tap(find.text('设置'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('课表'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(lens), start);
      expect(selected, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换保留笔记滚动位置和页面状态，并隔离隐藏页交互', (tester) async {
    var selected = 0;
    var created = 0;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
      builder: (context, update) => Scaffold(
        body: StudyTabDeck(index: selected, children: [
          _RememberedPage(onCreated: () => created++),
          const Center(child: Text('第二页')),
        ]),
        bottomNavigationBar: TextButton(
            onPressed: () => update(() => selected = 1 - selected),
            child: const Text('切换')),
      ),
    )));
    expect(created, 1);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    await tester.tap(find.text('切换'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('第二页'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    final transform = tester.widget<Transform>(find
        .descendant(
            of: find.byType(StudyTabDeck), matching: find.byType(Transform))
        .first);
    expect(transform.transform.storage[12], greaterThan(0));
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        position);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画时胶囊和页面立即到位，大字深色导航不溢出', (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                highContrast: true,
                textScaler: const TextScaler.linear(2)),
            child: StatefulBuilder(
                builder: (context, update) => Scaffold(
                      body: StudyTabDeck(index: selected, children: const [
                        Text('第一页'),
                        Text('第二页'),
                        SizedBox(),
                        SizedBox(),
                      ]),
                      bottomNavigationBar: GlassNavigationGroup(
                          destinations: destinations,
                          selectedIndex: selected,
                          onSelected: (index) =>
                              update(() => selected = index)),
                    )),
          ),
        )));
    await tester.tap(find.text('笔记'));
    await tester.pump();
    expect(find.text('第二页'), findsOneWidget);
    final positioning = tester.widget<AnimatedPositioned>(
        find.byKey(const ValueKey('navigation-lens-position')));
    expect(positioning.duration, Duration.zero);
    final transform = tester.widget<Transform>(find
        .descendant(
            of: find.byType(StudyTabDeck), matching: find.byType(Transform))
        .first);
    expect(transform.transform.storage[12], 0);
    expect(tester.takeException(), isNull);
  });
}

class _RememberedPage extends StatefulWidget {
  const _RememberedPage({required this.onCreated});
  final VoidCallback onCreated;
  @override
  State<_RememberedPage> createState() => _RememberedPageState();
}

class _RememberedPageState extends State<_RememberedPage> {
  @override
  void initState() {
    super.initState();
    widget.onCreated();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
      itemCount: 60,
      itemExtent: 60,
      itemBuilder: (context, index) => Text('笔记 $index'));
}
