import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:class_notes_assistant/main.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/core/pressable_card.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/notes/note_detail_page.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'note_rendering_test.dart' show loadFonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshotPath = Platform.environment['CNA_UI_SNAPSHOT'];
  final schedulePath = Platform.environment['CNA_SCHEDULE_SNAPSHOT'];
  final coursesPath = Platform.environment['CNA_COURSES_SNAPSHOT'];
  if (snapshotPath == null) return;
  for (final setting in [
    (390.0, false, 1.0),
    (1200.0, false, 1.0),
    (960.0, false, 1.0),
    (390.0, true, 2.0),
  ]) {
    testWidgets('实际导航及资料库预览 $setting', (tester) async {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        SharedPreferences.setMockInitialValues({});
        final (width, dark, textScale) = setting;
        tester.view.physicalSize = Size(width, width == 960 ? 390 : 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(loadFonts);
        final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
        final snapshot = jsonDecode(
            File(snapshotPath).readAsStringSync().replaceFirst('\uFEFF', ''));
        final firstNoteTitle = ((snapshot['data']['items'] as List).first
            as Map)['topic'] as String;
        final schedule = schedulePath == null
            ? null
            : jsonDecode(File(schedulePath).readAsStringSync());
        final courses = coursesPath == null
            ? null
            : jsonDecode(File(coursesPath).readAsStringSync());
        api.dio.interceptors
            .add(InterceptorsWrapper(onRequest: (request, handler) {
          handler.resolve(Response(
              requestOptions: request,
              statusCode: 200,
              data: request.path == '/api/notes'
                  ? snapshot
                  : request.path.startsWith('/api/notes/') &&
                          request.path.endsWith('/content')
                      ? {
                          'code': 0,
                          'data': {'markdown': '# 测试正文内容\n\n笔记已成功打开。'},
                          'message': 'ok'
                        }
                      : request.path == '/api/schedule' && schedule != null
                          ? schedule
                          : request.path == '/api/courses' && courses != null
                              ? courses
                              : {'code': 0, 'data': [], 'message': 'ok'}));
        }));
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme).copyWith(
                  platform: width != 1200
                      ? TargetPlatform.android
                      : TargetPlatform.windows),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!),
              home: MainNavigationScaffold(
                  apiClient: api,
                  recordingBridge: StubRecordingBridge(),
                  uploadQueue: UploadQueue(apiClient: api)),
            )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
            width < 900);
        expect(find.text('导入课表'), findsWidgets);
        expect(find.text('搜题'), findsNothing);
        final output = Platform.environment['CNA_UI_OUTPUT'];
        Future<void> capture(String name) async {
          if (output == null) return;
          await tester.runAsync(() async {
            final boundary = boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File('$output/$name-${width.toInt()}${dark ? '-深色-2x' : ''}.png')
                .writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('课表');
        await tester.tap(width == 1200
            ? find.byKey(const ValueKey('windows-dock-icon-1'))
            : find.text('笔记').last);
        await tester.pump();
        await capture('切换-000');
        await tester.pump(const Duration(milliseconds: 70));
        await capture('切换-070');
        await tester.pump(const Duration(milliseconds: 90));
        await capture('切换-160');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('课堂笔记'), findsOneWidget);
        await capture('笔记');
        final noteInk = find
            .ancestor(
              of: find.text(firstNoteTitle),
              matching: find.byType(InkWell),
            )
            .first;
        final noteButton = tester.widget<InkWell>(noteInk);
        expect(noteButton.splashFactory, NoSplash.splashFactory);
        expect(find.ancestor(of: noteInk, matching: find.byType(PressableCard)),
            findsOneWidget);
        final press = await tester.startGesture(tester.getCenter(noteInk));
        await tester.pump(const Duration(milliseconds: 280));
        await tester.pump(const Duration(milliseconds: 180));
        await capture('笔记按下');
        await press.cancel();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(firstNoteTitle));
        await tester.pumpAndSettle();
        await tester.tap(find.text(firstNoteTitle));
        await tester.pumpAndSettle();
        expect(find.byType(NoteDetailPage), findsOneWidget);
        expect(
            tester.widget<NoteMarkdown>(find.byType(NoteMarkdown).first).data,
            contains('测试正文内容'));
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(width == 1200
            ? find.byKey(const ValueKey('windows-dock-icon-3'))
            : find.text('设置').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('极速免下载更新模式'), findsNothing);
        if (width == 1200) {
          final serviceTile = find.text('后端服务器地址');
          await tester.ensureVisible(serviceTile);
          await tester.pumpAndSettle();
          final mouse =
              await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
          final point = tester.getCenter(serviceTile);
          await mouse.addPointer(location: point);
          await mouse.moveTo(point);
          await tester.pumpAndSettle();
          final card = tester.widget<Card>(find
              .ancestor(of: serviceTile, matching: find.byType(Card))
              .first);
          expect(
              card.clipBehavior ??
                  Theme.of(tester.element(serviceTile)).cardTheme.clipBehavior,
              Clip.antiAlias);
          await capture('设置悬停');
          await mouse.removePointer();
          final press =
              await tester.startGesture(tester.getCenter(serviceTile));
          await tester.pump(const Duration(milliseconds: 250));
          await capture('设置按下');
          await press.cancel();
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        api.dio.close();
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}
