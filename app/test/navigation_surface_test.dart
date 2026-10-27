import 'package:class_notes_assistant/core/glass_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('Android 底栏实色填充、边框和阴影共用胶囊路径 $scale', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: Center(
                      child: SizedBox(
                width: 360,
                child: GlassNavigationSurface(
                    pill: true,
                    child: GlassNavigationGroup(destinations: const [
                      (
                        Icons.calendar_today_outlined,
                        Icons.calendar_today,
                        '课表'
                      ),
                      (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
                      (Icons.mic_none, Icons.mic, '录音'),
                      (Icons.settings_outlined, Icons.settings, '设置'),
                    ], selectedIndex: 0, onSelected: (_) {})),
              ))),
            ),
          )));
      final physicalFinder = find.descendant(
          of: find.byType(GlassNavigationSurface),
          matching: find.byType(PhysicalShape));
      final physical = tester.widget<PhysicalShape>(physicalFinder);
      final clipper = physical.clipper as ShapeBorderClipper;
      expect(clipper.shape, isA<StadiumBorder>());
      expect(physical.clipBehavior, Clip.antiAlias);
      final decoration = tester
          .widgetList<DecoratedBox>(find.descendant(
              of: find.byType(GlassNavigationSurface),
              matching: find.byType(DecoratedBox)))
          .map((widget) => widget.decoration)
          .whereType<ShapeDecoration>()
          .single;
      expect(identical(decoration.shape, clipper.shape), isTrue);
      final size = tester.getSize(physicalFinder);
      final path = clipper.getClip(size);
      expect(path.contains(const Offset(2, 2)), isFalse);
      expect(path.contains(Offset(size.height / 2, 2)), isTrue);
      expect(path.contains(Offset(2, size.height / 2)), isTrue);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
