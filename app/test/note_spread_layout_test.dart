import 'dart:io';
import 'dart:ui' as ui;
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/core/shapes.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:class_notes_assistant/features/notes/note_detail_page.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'note_rendering_test.dart' show loadFonts;

void main() {
  for (final setting in [
    (390.0, 844.0, 1.0),
    (1200.0, 844.0, 1.0),
    (844.0, 390.0, 2.0)
  ]) {
    final (width, height, scale) = setting;
    testWidgets('卡片舒展${width.toInt()}宽：正文提前挂载且标题/段内排版不变', (tester) async {
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        SharedPreferences.setMockInitialValues({'cna_reading_font_size': 18.0});
        await tester.runAsync(loadFonts);
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const id = 'spread-fixture';
        const title = '正弦交流电的相量表示、叠加与易错点';
        const paragraph =
            '排版稳定检查：同频率正弦量的相量可以直接相加。先明确有效值与最大值，再用初相位描述相位差，不能将相量直接当作瞬时值。';
        final api = ApiClient(baseUrl: 'http://note.test');
        api.dio.interceptors
            .add(InterceptorsWrapper(onRequest: (request, handler) {
          handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: {
            'code': 0,
            'data': request.path.endsWith('/content')
                ? {
                    'markdown':
                        '## 核心概念\n\n$paragraph\n\n${List.generate(50, (i) => '## 后续$i\n\n$paragraph').join('\n\n')}'
                  }
                : {
                    'items': [
                      {
                        'note_id': id,
                        'topic': title,
                        'course_name': '电工电子技术',
                        'class_date': '2026-10-14'
                      }
                    ],
                    'total': 1
                  },
            'message': 'ok'
          }));
        }));
        final boundary = GlobalKey();
        Future<void> capture(String suffix) async {
          final output = Platform.environment['CNA_MOTION_CAPTURE'];
          if (output == null) return;
          await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            File('$output/${width.toInt()}-$suffix.png')
                .writeAsBytesSync(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.pumpWidget(RepaintBoundary(
            key: boundary,
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: scale == 2 ? AppTheme.darkTheme : AppTheme.lightTheme,
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: NotesPage(apiClient: api))));
        await tester.pumpAndSettle();
        if (find.text(title).evaluate().isEmpty) {
          await tester.scrollUntilVisible(find.text(title), 200,
              scrollable: find.byType(Scrollable).first);
        }
        await tester.ensureVisible(find.text(title));
        final sourceTitle = tester.widget<Text>(find.text(title));
        final sourceLines = sourceTitle.maxLines;
        final sourceStyle = sourceTitle.style;
        await capture('source');
        await tester.tap(find.text(title));
        await tester.pump(const Duration(milliseconds: 141));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 70));
        final detail = find.byType(NoteDetailPage);
        expect(detail, findsOneWidget);
        final route = ModalRoute.of(tester.element(detail))!;
        expect(route.animation!.value, lessThan(1));
        expect(find.byType(NoteMarkdown), findsWidgets, reason: '正文不能等结束帧才挂载');
        expect(find.byType(NoteMarkdown).evaluate().length, lessThan(10),
            reason: '保持长笔记懒构建');
        final heading = find.byKey(const ValueKey('note-opening-title:$id'));
        final titleElement = tester.element(heading);
        final titleWidth = tester.getSize(heading).width;
        final titleStyle = tester.widget<Text>(heading).style;
        expect(tester.widget<Text>(heading).maxLines, sourceLines,
            reason: '进入阅读不能突然改变标题行数与省略号');
        expect(titleStyle?.fontSize, sourceStyle?.fontSize);
        expect(titleStyle?.height, sourceStyle?.height);
        final text = find
            .byWidgetPredicate((w) =>
                w is RichText && w.text.toPlainText().startsWith('排版稳定检查：'))
            .first;
        final render = tester.renderObject<RenderParagraph>(text);
        final textWidth = render.size.width;
        final glyphs = render.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: paragraph.length));
        final bodyElement =
            tester.element(find.byKey(const ValueKey('note-body-ready')));
        await capture('early');
        for (final duration in [60, 100, 100, 100, 140, 16]) {
          await tester.pump(Duration(milliseconds: duration));
          expect(tester.element(heading), same(titleElement));
          expect(tester.getSize(heading).width, closeTo(titleWidth, .01));
          expect(tester.widget<Text>(heading).style, titleStyle);
          expect(render.size.width, closeTo(textWidth, .01));
          expect(
              render.getBoxesForSelection(const TextSelection(
                  baseOffset: 0, extentOffset: paragraph.length)),
              glyphs);
          expect(tester.element(find.byKey(const ValueKey('note-body-ready'))),
              same(bodyElement));
          expect(tester.takeException(), isNull);
          if (duration == 100) {
            await capture(
                'progress-${route.animation!.value.toStringAsFixed(2)}');
          }
        }
        await capture('reading');
        final surfaceFinder =
            find.byKey(const ValueKey('note-opening-surface:$id'));
        final surface = tester.widget<PhysicalShape>(surfaceFinder);
        final path = surface.clipper!.getClip(tester.getSize(surfaceFinder));
        final rect = path.getBounds();
        expect(rect.left, closeTo(StudyShapes.readerInset, .01));
        expect(rect.top, closeTo(StudyShapes.readerInset, .01));
        expect(rect.right, closeTo(width - StudyShapes.readerInset, .01));
        expect(rect.bottom, closeTo(height - StudyShapes.readerInset, .01));
        expect(path.contains(const Offset(11, 11)), isFalse,
            reason: '终态左上角必须仍有真实裁切，不能退回直角');
        expect(path.contains(const Offset(34, 12)), isTrue);
        expect(surface.clipBehavior, Clip.antiAlias);
        expect(surface.elevation, greaterThan(0));
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byTooltip('刷新笔记'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expect(find.descendant(of: detail, matching: find.byType(Scrollbar)),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 140));
        await capture('reverse');
        await tester.pumpAndSettle();
        expect(find.byType(NoteDetailPage), findsNothing);
        expect(find.text(title), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        api.dio.close();
      } finally {
        debugDisableShadows = oldShadows;
      }
    });
  }
}
