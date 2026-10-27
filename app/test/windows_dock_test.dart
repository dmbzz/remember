import 'fixtures/legacy_windows_dock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];

Finder get _surface => find.byKey(const ValueKey('windows-dock-surface'));
Finder _icon(int i) => find.byKey(ValueKey('windows-dock-icon-$i'));
Finder _labelOpacity(int i) =>
    find.byKey(ValueKey('windows-dock-label-opacity-$i'));
double _width(WidgetTester tester) => tester.getSize(_surface).width;

Future<void> _mount(WidgetTester tester,
    {double scale = 1,
    double height = 480,
    bool reduceMotion = false,
    FocusNode? afterFocus,
    ValueChanged<int>? onSelected}) async {
  var selected = 0;
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion),
        child: Scaffold(
          body: SizedBox(
            height: height,
            child: Row(children: [
              StatefulBuilder(
                builder: (context, update) => WindowsHoverDock(
                    destinations: _destinations,
                    selectedIndex: selected,
                    onSelected: (index) {
                      update(() => selected = index);
                      onSelected?.call(index);
                    }),
              ),
              Expanded(
                child: Center(
                  child: TextButton(
                      focusNode: afterFocus,
                      onPressed: () {},
                      child: const Text('正文')),
                ),
              ),
            ]),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<TestGesture> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(500, 400));
  await mouse.moveTo(tester.getCenter(_surface));
  await tester.pump();
  return mouse;
}

void main() {
  testWidgets('悬停延迟展开；固定图标与正文，不移动、不重新排版', (tester) async {
    await _mount(tester);
    final initialWidth = _width(tester);
    final initialIcon = tester.getTopLeft(_icon(0));
    final pagePosition = tester.getTopLeft(find.text('正文'));
    final hostWidth =
        tester.getSize(find.byKey(const ValueKey('windows-dock-host'))).width;
    final mouse = await _hover(tester);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_width(tester), initialWidth);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_width(tester), greaterThan(initialWidth));
    expect(_width(tester), lessThan(hostWidth - 24));
    expect(tester.getTopLeft(_icon(0)), initialIcon);
    expect(tester.getTopLeft(find.text('正文')), pagePosition);
    final movement = tester.widget<Transform>(
        find.byKey(const ValueKey('windows-dock-label-offset-0')));
    expect(movement.transform.storage[12], inExclusiveRange(-8.0, 0.0));
    await tester.pumpAndSettle();
    expect(_width(tester), hostWidth - 24);
    expect(tester.widget<Opacity>(_labelOpacity(0)).opacity, 1);
    await mouse.moveTo(const Offset(500, 400));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_width(tester), hostWidth - 24);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect(_width(tester), initialWidth);
    expect(tester.getTopLeft(_icon(0)), initialIcon);
    expect(tester.getTopLeft(find.text('正文')), pagePosition);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鼠标点击导航后离开仍收回，不因鼠标焦点锁定', (tester) async {
    var selected = 0;
    await _mount(tester, onSelected: (value) => selected = value);
    final closed = _width(tester);
    final mouse = await _hover(tester);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(_icon(1)));
    await mouse.down(tester.getCenter(_icon(1)));
    await mouse.up();
    await tester.pump();
    expect(selected, 1);
    await mouse.moveTo(const Offset(500, 400));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(_width(tester), closed);
    expect(tester.widget<Opacity>(_labelOpacity(1)).opacity, 0);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('键盘进入保持文字可见，方向键和 Enter 可用，焦点离开收回', (tester) async {
    var selected = -1;
    final after = FocusNode();
    await _mount(tester,
        afterFocus: after, onSelected: (value) => selected = value);
    final closed = _width(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_width(tester), greaterThan(closed));
    expect(tester.widget<Opacity>(_labelOpacity(0)).opacity, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<Opacity>(_labelOpacity(1)).opacity, 1);
    after.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(_width(tester), closed);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    after.dispose();
  });

  testWidgets('动画中快速改变方向从当前位置返回，不跳回起点', (tester) async {
    await _mount(tester);
    final closed = _width(tester);
    final mouse = await _hover(tester);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(milliseconds: 90));
    final openingWidth = _width(tester);
    await mouse.moveTo(const Offset(500, 400));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 40));
    final closingWidth = _width(tester);
    expect(closingWidth, lessThan(openingWidth));
    expect(closingWidth, greaterThan(closed));
    await mouse.moveTo(tester.getCenter(_surface));
    await tester.pump(const Duration(milliseconds: 70));
    final turnWidth = _width(tester);
    expect(turnWidth, greaterThanOrEqualTo(closed));
    await tester.pump(const Duration(milliseconds: 25));
    expect(_width(tester), greaterThan(turnWidth));
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(_labelOpacity(0)).opacity, 1);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('外壳使用 R28，选中项从圆形展开为横向胶囊，同一路径裁切', (tester) async {
    await _mount(tester);
    final physical = tester.widget<PhysicalShape>(_surface);
    final outerClipper = physical.clipper as ShapeBorderClipper;
    expect(outerClipper.shape, isA<RoundedRectangleBorder>());
    expect((outerClipper.shape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(28));
    final decoration = tester
        .widgetList<DecoratedBox>(
            find.descendant(of: _surface, matching: find.byType(DecoratedBox)))
        .map((widget) => widget.decoration)
        .whereType<ShapeDecoration>()
        .first;
    expect(identical(decoration.shape, outerClipper.shape), isTrue);
    final row = find.byKey(const ValueKey('windows-dock-item-0'));
    final closedSize = tester.getSize(row);
    expect(closedSize.width, closedSize.height);
    final mouse = await _hover(tester);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    final rowShape =
        tester.widget<PhysicalShape>(row).clipper as ShapeBorderClipper;
    expect(rowShape.shape, isA<StadiumBorder>());
    final material = tester.widget<Material>(
        find.descendant(of: row, matching: find.byType(Material)));
    final ink = tester.widget<InkWell>(
        find.descendant(of: row, matching: find.byType(InkWell)));
    expect(identical(material.shape, rowShape.shape), isTrue);
    expect(identical(ink.customBorder, rowShape.shape), isTrue);
    final openSize = tester.getSize(row);
    expect(openSize.width, greaterThan(openSize.height));
    final path = rowShape.getClip(openSize);
    expect(path.contains(const Offset(2, 2)), isFalse);
    expect(path.contains(Offset(openSize.height / 2, 2)), isTrue);
    expect(physical.color, Colors.transparent);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('两倍字号矮窗保持可滚动；减少动画立即开合', (tester) async {
    await _mount(tester, scale: 2, height: 180, reduceMotion: true);
    final closed = _width(tester);
    expect(tester.getSize(_surface).height, 156);
    expect(tester.getTopLeft(_surface).dy, 12);
    final mouse = await _hover(tester);
    await tester.pump();
    expect(_width(tester), greaterThan(closed));
    expect(tester.widget<Opacity>(_labelOpacity(0)).opacity, 1);
    final scroll = find.descendant(
        of: _surface, matching: find.byType(SingleChildScrollView));
    await tester.drag(scroll, const Offset(0, -250));
    await tester.pumpAndSettle();
    final node = find.byKey(const ValueKey('windows-dock-item-3'));
    expect(tester.getCenter(node).dy, lessThan(180));
    await mouse.moveTo(const Offset(500, 400));
    await tester.pump();
    expect(_width(tester), closed);
    expect(tester.widget<Opacity>(_labelOpacity(3)).opacity, 0);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final reduce in [false, true]) {
    testWidgets('两倍字号矮窗键盘 End 自动滚到设置并可点击 $reduce', (tester) async {
      var selected = -1;
      await _mount(tester,
          scale: 2,
          height: 180,
          reduceMotion: reduce,
          onSelected: (index) => selected = index);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      final surfaceRect = tester.getRect(_surface);
      final settingRect = tester.getRect(_icon(3));
      expect(settingRect.top, greaterThanOrEqualTo(surfaceRect.top + 8));
      expect(settingRect.bottom, lessThanOrEqualTo(surfaceRect.bottom - 8));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 3);
      selected = -1;
      await tester.tap(_icon(3));
      await tester.pumpAndSettle();
      expect(selected, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
