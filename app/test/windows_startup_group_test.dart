import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/settings/windows_startup_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_rendering_test.dart' show loadFonts;

Future<void> mountGroup(WidgetTester tester, WindowsStartupGroup group,
    {Brightness brightness = Brightness.light,
    Size size = const Size(1000, 500),
    double scale = 1,
    GlobalKey? boundary}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme,
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: RepaintBoundary(
          key: boundary,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
                padding: EdgeInsets.fromLTRB(8, 0, 8, 8), child: Text('启动与通知')),
            group,
          ]),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('changing one setting keeps the other independent while saving',
      (tester) async {
    final saved = Completer<bool>();
    final changes = <String>[];
    await mountGroup(
        tester,
        WindowsStartupGroup(
          readStartup: () async => false,
          writeStartup: (value) {
            changes.add('startup:$value');
            return saved.future;
          },
          readNotifications: () async => true,
          writeNotifications: (value) async {
            changes.add('notifications:$value');
            return value;
          },
        ));
    await tester.tap(find.text('开机自启动'));
    await tester.pump();
    expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .first
            .onChanged,
        isNull);
    await tester.tap(find.text('ASR 转写通知'));
    await tester.pumpAndSettle();
    expect(changes, ['startup:true', 'notifications:false']);
    saved.complete(true);
    await tester.pumpAndSettle();
    final toggles =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(toggles.first.value, isTrue);
    expect(toggles.last.value, isFalse);
  });

  testWidgets('failed save preserves the last read state and offers reread',
      (tester) async {
    var reads = 0;
    await mountGroup(
        tester,
        WindowsStartupGroup(
          readStartup: () async => ++reads > 1,
          writeStartup: (_) async => throw StateError('save failed'),
          readNotifications: () async => false,
          writeNotifications: (value) async => value,
        ));
    await tester.tap(find.text('开机自启动'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试或重新读取当前状态'), findsOneWidget);
    expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .first
            .value,
        isFalse);
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('保存失败，请重试或重新读取当前状态'), findsNothing);
    expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .first
            .value,
        isTrue);
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('group remains readable ${dark ? 'dark' : 'light'} ${scale}x',
          (tester) async {
        final boundary = GlobalKey();
        await mountGroup(
            tester,
            WindowsStartupGroup(
              readStartup: () async => true,
              writeStartup: (value) async => value,
              readNotifications: () async => true,
              writeNotifications: (value) async => value,
            ),
            brightness: dark ? Brightness.dark : Brightness.light,
            size: scale == 1 ? const Size(1654, 360) : const Size(400, 900),
            scale: scale,
            boundary: boundary);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('ASR 转写通知'));
        expect(find.text('ASR 转写通知').hitTestable(), findsOneWidget);
        await tester.tap(find.text('ASR 转写通知'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widgetList<SwitchListTile>(find.byType(SwitchListTile))
                .last
                .value,
            isFalse);
        expect(tester.takeException(), isNull);

        final output = Platform.environment['REMEMBER_UI_EVIDENCE_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            Directory(output).createSync(recursive: true);
            File('$output/settings-group-${dark ? 'dark' : 'light'}-${scale}x.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
