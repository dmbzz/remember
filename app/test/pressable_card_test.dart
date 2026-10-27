import 'package:class_notes_assistant/core/pressable_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('快速点击先显示整卡反馈，再打开目标', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Center(
              child: SizedBox(
        width: 320,
        child: PressableCard(
          onTap: () => opened++,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Text('笔记标题'),
          ),
        ),
      ))),
    ));
    await tester.tap(find.text('笔记标题'));
    await tester.pump();
    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(PressableCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((animated.decoration as BoxDecoration).color,
        isNot(Colors.transparent));
    expect(opened, 0);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('减少动画时无需等待按下过渡', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Scaffold(
                    body: PressableCard(
                  onTap: () => opened++,
                  child: const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('打开笔记'),
                  ),
                )),
              )),
    ));
    await tester.tap(find.text('打开笔记'));
    await tester.pump();
    expect(opened, 1);
  });
}
