import 'dart:io';
import 'dart:ui' as ui;
import 'package:class_notes_assistant/core/theme.dart';
import 'fixtures/legacy_windows_dock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'note_rendering_test.dart' show loadFonts;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('实际字体下展开侧栏对齐预览 $scale', (tester) async {
      await tester.runAsync(loadFonts);
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 240,
                    height: 360,
                    child: WindowsHoverDock(destinations: const [
                      (
                        Icons.calendar_today_outlined,
                        Icons.calendar_today,
                        '课表'
                      ),
                      (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
                      (Icons.mic_none, Icons.mic, '录音'),
                      (Icons.settings_outlined, Icons.settings, '设置'),
                    ], selectedIndex: 0, onSelected: (_) {}),
                  )))));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 400));
      await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('windows-dock-surface'))));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        final iconCenter =
            tester.getCenter(find.byKey(ValueKey('windows-dock-icon-$i')));
        final labelCenter =
            tester.getCenter(find.byKey(ValueKey('windows-dock-label-$i')));
        expect(labelCenter.dy, closeTo(iconCenter.dy, .01));
        expect(
            tester
                .getSize(find.byKey(ValueKey('windows-dock-label-$i')))
                .height,
            lessThan(scale == 1 ? 56 : 66));
      }
      final output = Platform.environment['CNA_DOCK_CAPTURE'];
      if (output != null && scale == 1) {
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 3);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(output).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
