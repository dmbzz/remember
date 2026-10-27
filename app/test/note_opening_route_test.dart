import 'package:class_notes_assistant/core/note_opening_route.dart';
import 'package:class_notes_assistant/core/shapes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<
          ({
            NoteOpeningRoute<void> route,
            ValueNotifier<bool> hidden,
            GlobalKey card,
            GlobalKey heading,
            ValueNotifier<double> position,
            List<int> builds,
            List<int> sourceReads
          })>
      openReader(WidgetTester tester,
          {bool reduceMotion = false,
          String title = '同一份标题',
          int? maxLines,
          TextScaler scaler = TextScaler.noScaling}) async {
    final card = GlobalKey();
    final heading = GlobalKey();
    final hidden = ValueNotifier(false);
    final position = ValueNotifier(180.0);
    final builds = <int>[];
    final sourceReads = <int>[];
    late NoteOpeningRoute<void> route;
    Rect? rect(GlobalKey key) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        return box.localToGlobal(Offset.zero) & box.size;
      }
      return null;
    }

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child!),
      home: MediaQuery(
        data: MediaQueryData(
            size: const Size(800, 600),
            disableAnimations: reduceMotion,
            textScaler: scaler),
        child: Scaffold(
            body: Builder(
          builder: (context) => ValueListenableBuilder<double>(
            valueListenable: position,
            builder: (context, top, child) => Stack(children: [
              Positioned(
                top: top,
                left: 40,
                width: 360,
                child: Material(
                    key: card,
                    child: ListTile(
                      title: ValueListenableBuilder<bool>(
                        valueListenable: hidden,
                        builder: (context, isHidden, child) => Opacity(
                            opacity: isHidden ? 0 : 1,
                            child: Text(title,
                                key: heading,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17))),
                      ),
                      onTap: () {
                        route = NoteOpeningRoute<void>(
                          sourceContext: context,
                          noteId: 'stable-note-id',
                          title: title,
                          sourceTitleHidden: hidden,
                          sourceCardRect: () {
                            sourceReads.add(1);
                            return rect(card);
                          },
                          sourceTitleRect: () => rect(heading),
                          sourceTitleStyle: const TextStyle(fontSize: 17),
                          builder: (_) => Builder(builder: (context) {
                            builds.add(1);
                            return Scaffold(
                              appBar: AppBar(title: const Text('阅读')),
                              body: Column(children: [
                                Padding(
                                    padding: const EdgeInsets.all(32),
                                    child: NoteOpeningTitleAnchor(
                                        noteId: 'stable-note-id',
                                        title: title,
                                        maxLines: maxLines,
                                        style: const TextStyle(
                                            fontSize: 26, height: 1.25))),
                                const Expanded(
                                    child: Center(child: Text('正文'))),
                              ]),
                            );
                          }),
                        );
                        Navigator.of(context).push(route);
                      },
                    )),
              ),
            ]),
          ),
        )),
      ),
    ));
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump();
    return (
      route: route,
      hidden: hidden,
      card: card,
      heading: heading,
      position: position,
      builds: builds,
      sourceReads: sourceReads
    );
  }

  testWidgets('标题始终由同一覆盖层绘制，动画不会反复构建长正文', (tester) async {
    final fixture = await openReader(tester);
    const key = ValueKey('note-opening-title:stable-note-id');
    final element = find.byKey(key).evaluate().single;
    expect(fixture.hidden.value, isTrue);
    final initialBuilds = fixture.builds.length;
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(key).evaluate().single, same(element));
      expect(tester.takeException(), isNull);
    }
    expect(fixture.builds.length, initialBuilds);
    expect(fixture.route.animation!.status, AnimationStatus.completed);
    expect(find.byKey(key), findsOneWidget);
    expect(find.byType(NoteOpeningTitleAnchor), findsOneWidget);
    final surfaceFinder =
        find.byKey(const ValueKey('note-opening-surface:stable-note-id'));
    final surface = tester.widget<PhysicalShape>(surfaceFinder);
    final path = surface.clipper!.getClip(tester.getSize(surfaceFinder));
    expect(path.getBounds().left, StudyShapes.readerInset);
    expect(path.contains(const Offset(11, 11)), isFalse);
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.hidden.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回时重新读取同一笔记实际位置；来源消失时立即退出', (tester) async {
    final fixture = await openReader(tester);
    await tester.pumpAndSettle();
    fixture.position.value = -1000;
    await tester.pump();
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.sourceReads.length, 2);
    expect(fixture.route.reverseTransitionDuration, Duration.zero);
    expect(fixture.hidden.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果即时打开，独立阅读页标题仍正常绘制', (tester) async {
    final fixture = await openReader(tester, reduceMotion: true);
    await tester.pumpAndSettle();
    expect(fixture.route.transitionDuration, Duration.zero);
    expect(fixture.route.reverseTransitionDuration, Duration.zero);
    final surfaceFinder =
        find.byKey(const ValueKey('note-opening-surface:stable-note-id'));
    final surface = tester.widget<PhysicalShape>(surfaceFinder);
    final path = surface.clipper!.getClip(tester.getSize(surfaceFinder));
    expect(path.getBounds().top, StudyShapes.readerInset);
    expect(path.contains(const Offset(11, 11)), isFalse,
        reason: '减少动态效果也不能退回直角页面');
    expect(find.byKey(const ValueKey('note-opening-title:stable-note-id')),
        findsOneWidget);
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: NoteOpeningTitleAnchor(
                noteId: 'plain-note',
                title: '独立标题',
                style: TextStyle(fontSize: 26)))));
    expect(find.text('独立标题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅读稳定后窗口变宽，标题仍贴合目标；快速返回不留隐藏标题', (tester) async {
    final fixture = await openReader(tester);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    final actual = tester.getRect(
        find.byKey(const ValueKey('note-opening-title:stable-note-id')));
    final anchor = tester.getRect(find.byType(NoteOpeningTitleAnchor));
    expect(actual.left, closeTo(anchor.left, .01));
    expect(actual.top, closeTo(anchor.top, .01));
    expect(actual.width, closeTo(anchor.width, .01));
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.hidden.value, isFalse);
    final second = await openReader(tester);
    await tester.pump(const Duration(milliseconds: 100));
    second.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(second.hidden.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏两倍字号长标题布局稳定并保持唯一标题 Element', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await openReader(tester,
        title: '工程力学中平面任意力系与摩擦问题的课堂整理及详细推导',
        scaler: const TextScaler.linear(2));
    final heading =
        find.byKey(const ValueKey('note-opening-title:stable-note-id'));
    final element = heading.evaluate().single;
    await tester.pumpAndSettle();
    expect(heading.evaluate().single, same(element));
    final titleRect = tester.getRect(heading);
    final anchorRect = tester.getRect(find.byType(NoteOpeningTitleAnchor));
    expect(titleRect.top, closeTo(anchorRect.top, .01));
    expect(titleRect.width, closeTo(anchorRect.width, .01));
    expect(titleRect.height, closeTo(anchorRect.height, .01));
    expect(tester.takeException(), isNull);
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.hidden.value, isFalse);
  });

  testWidgets('真实冲突文件长标题在390x600两倍字号限两行，不盖住正文', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await openReader(tester,
        title:
            '电路的基本概念与基尔霍夫定律_2026-09-03.sync-conflict-20261007-212932-2MMFICR',
        maxLines: 2,
        scaler: const TextScaler.linear(2));
    final heading =
        find.byKey(const ValueKey('note-opening-title:stable-note-id'));
    final element = heading.evaluate().single;
    final anchor = find.byType(NoteOpeningTitleAnchor);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(heading.evaluate().single, same(element));
      expect(tester.widget<Text>(heading).maxLines, 2);
      expect(tester.getRect(heading).height,
          lessThanOrEqualTo(tester.getRect(anchor).height + .01));
      expect(tester.takeException(), isNull);
    }
    final text = tester.widget<Text>(heading);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.getRect(heading).height,
        closeTo(tester.getRect(anchor).height, .01));
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.hidden.value, isFalse);
  });

  testWidgets('来源两行到目标三行的标题按插值框裁剪，不涂到卡片元信息', (tester) async {
    final fixture = await openReader(tester,
        title:
            '电路的基本概念与基尔霍夫定律_2026-09-03.sync-conflict-20261007-212932-2MMFICR',
        maxLines: 3);
    final heading =
        find.byKey(const ValueKey('note-opening-title:stable-note-id'));
    final element = heading.evaluate().single;
    final sourceHeight = tester.getRect(find.byKey(fixture.heading)).height;
    final layoutWidth = tester.getRect(heading).width;
    final layoutHeight = tester.getRect(heading).height;
    final clip =
        find.ancestor(of: heading, matching: find.byType(ClipRect)).first;
    expect(tester.getRect(clip).height, closeTo(sourceHeight, .01));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(heading).width, closeTo(layoutWidth, .01));
    expect(tester.getRect(heading).height, closeTo(layoutHeight, .01));
    await tester.pumpAndSettle();
    expect(heading.evaluate().single, same(element));
    expect(
        tester.getRect(heading).height,
        closeTo(
            tester.getRect(find.byType(NoteOpeningTitleAnchor)).height, .01));
    fixture.route.navigator!.pop();
    await tester.pumpAndSettle();
    expect(fixture.hidden.value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
