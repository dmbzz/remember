import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/recording_files_page.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/main.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

const destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];
final shell = find.byKey(const ValueKey('touch-orientation-capsule'));
final root = GlobalKey();

ApiClient apiFixture() {
  final api = ApiClient(baseUrl: 'http://judge-dock.invalid');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
    Object data = <String, dynamic>{};
    if (request.path.contains('recordings')) {
      data = [for (var i = 0; i < 10; i++) {
        'id': 'received-$i', 'course_id': 'mechanics',
        'course_name': '工程力学 $i', 'class_date': '2026-10-18',
        'original_name': '工程力学_2026-10-18_08-15.m4a',
        'upload_status': 'uploaded', 'size_bytes': 1200,
        'file_path': 'D:/QA/工程力学_2026-10-18.m4a',
      }];
    } else if (request.path.contains('courses')) {
      data = [{'id': 'mechanics', 'name': '工程力学'}];
    } else if (request.path.contains('schedule')) {
      data = [];
    } else if (request.path.contains('paths')) {
      data = {'obsidian_root': 'D:/QA/笔记', 'recordings_root': 'D:/QA/录音'};
    } else if (request.path.contains('version')) {
      data = {'has_update': false, 'version': '0.1.32', 'version_code': 33};
    }
    handler.resolve(Response(requestOptions: request, statusCode: 200,
        data: {'code': 0, 'message': 'ok', 'data': data}));
  }));
  return api;
}

Future<void> mount(WidgetTester tester, String page,
    {Size size = const Size(1000, 720), double scale = 1,
    bool mobile = false, bool reduce = false, double keyboard = 0}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.runAsync(loadFonts);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final api = apiFixture();
  final queue = UploadQueue(apiClient: api);
  addTearDown(() { queue.dispose(); api.dio.close(force: true); });
  final content = switch (page) {
    'settings' => SettingsPage(apiClient: api, recordingBridge: StubRecordingBridge()),
    'files' => RecordingFilesPage(apiClient: api, uploadQueue: queue),
    _ => RecordingPage(apiClient: api, uploadQueue: queue, recordingBridge: StubRecordingBridge()),
  };
  await tester.pumpWidget(RepaintBoundary(key: root, child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme.copyWith(platform: mobile ? TargetPlatform.android : TargetPlatform.windows),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale), disableAnimations: reduce,
        viewInsets: EdgeInsets.only(bottom: keyboard)), child: child!),
    home: StudyNavigationLayout(content: content, destinations: destinations,
        selectedIndex: page == 'settings' ? 3 : 2, onSelected: (_) {}),
  )));
  await tester.pumpAndSettle();
}

void noOptionsCovered(WidgetTester tester) {
  final capsule = tester.getRect(shell);
  for (final element in find.byType(ListTile).evaluate()) {
    final control = tester.getRect(find.byElementPredicate((candidate) => candidate == element));
    final intersection = control.intersect(capsule);
    expect(intersection.width <= .01 || intersection.height <= .01, isTrue,
        reason: 'ListTile $control must not be hidden by Dock $capsule');
  }
}

Future<void> capture(WidgetTester tester, String name) async {
  final previous = debugDisableShadows;
  debugDisableShadows = false;
  try {
    for (final render in tester.allRenderObjects) { render.markNeedsPaint(); }
    await tester.pump();
    await tester.runAsync(() async {
    final image = await (root.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('../judge-frames')..createSync(recursive: true);
    File('${directory.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    });
  } finally {
    debugDisableShadows = previous;
    for (final render in tester.allRenderObjects) { render.markNeedsPaint(); }
    await tester.pump();
  }
}

void main() {
  for (final page in ['settings', 'files']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('独立真实$page ${scale}x 收起展开均不遮挡选项且hover不推内容', (tester) async {
        await mount(tester, page, scale: scale);
        expect(tester.takeException(), isNull);
        noOptionsCovered(tester);
        final scroll = find.byType(Scrollable).first;
        final initial = tester.getRect(find.byType(Card).first);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(950, 20));
        await mouse.moveTo(tester.getCenter(shell));
        await tester.pump(const Duration(milliseconds: 70));
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          noOptionsCovered(tester);
          expect(tester.getRect(find.byType(Card).first), initial);
        }
        await capture(tester, '$page-${scale}x-open');
        final state = tester.state<ScrollableState>(scroll);
        state.position.jumpTo(state.position.maxScrollExtent);
        await tester.pumpAndSettle();
        noOptionsCovered(tester);
        expect(tester.takeException(), isNull);
        await capture(tester, '$page-${scale}x-tail');
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for (final page in ['settings', 'files']) {
    testWidgets('独立真实$page 窄宽转换减动终态仍可操作', (tester) async {
      await mount(tester, page, size: const Size(700, 650), reduce: true, scale: 2);
      expect(tester.takeException(), isNull);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      noOptionsCovered(tester);
      tester.view.physicalSize = const Size(1000, 650);
      await tester.pumpAndSettle();
      noOptionsCovered(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('独立手机录音竖横屏无布局错误，底部有可滚动余量', (tester) async {
    await mount(tester, 'phone', mobile: true, size: const Size(390, 844), scale: 2);
    expect(tester.takeException(), isNull);
    var scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await capture(tester, 'phone-recording-tail');
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await capture(tester, 'phone-recording-landscape');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('独立设置短窗320%和键盘弹出编辑无Dock拦截', (tester) async {
    await mount(tester, 'settings', size: const Size(1000, 420), scale: 3.2);
    expect(tester.takeException(), isNull);
    noOptionsCovered(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, 'settings', size: const Size(700, 760), keyboard: 260);
    final option = find.widgetWithText(ListTile, '后端服务器地址');
    await tester.scrollUntilVisible(option, 150, scrollable: find.byType(Scrollable).first);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(find.text('修改后端服务地址'), findsOneWidget);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    await capture(tester, 'settings-keyboard-dialog');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('修改后端服务地址'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('独立真实设置宽窄正反动画保留页状态和滚动，无末帧跳变', (tester) async {
    await mount(tester, 'settings', size: const Size(1000, 720));
    final pageState = tester.state(find.byType(SettingsPage));
    final body = tester.state<ScrollableState>(find.byType(Scrollable).first);
    body.position.jumpTo(180);
    await tester.pumpAndSettle();
    await capture(tester, 'settings-side-start');
    tester.view.physicalSize = const Size(700, 720);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await capture(tester, 'settings-to-bottom-mid');
    await tester.pump(const Duration(milliseconds: 219));
    final before = tester.getTopLeft(find.byType(Card).first);
    await tester.pump(const Duration(milliseconds: 1));
    final after = tester.getTopLeft(find.byType(Card).first);
    expect((before - after).distance, lessThan(1));
    await tester.pumpAndSettle();
    await capture(tester, 'settings-bottom-end');
    expect(identical(pageState, tester.state(find.byType(SettingsPage))), isTrue);
    expect(identical(body, tester.state(find.byType(Scrollable).first)), isTrue);
    expect(body.position.pixels, 180);
    tester.view.physicalSize = const Size(1000, 720);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await capture(tester, 'settings-to-side-mid');
    await tester.pumpAndSettle();
    noOptionsCovered(tester);
    await capture(tester, 'settings-side-end');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
