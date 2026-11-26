import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/note_check_controller.dart';
import 'package:class_notes_assistant/features/notes/note_detail_page.dart';
import 'package:class_notes_assistant/features/notes/note_image_view.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:class_notes_assistant/features/notes/note_syntax.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

// 160x100 蓝底白交叉线有效 PNG，测试环境稳定解码与截图可视化
final Uint8List _samplePngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAABkCAIAAACO1KzYAAAC9UlEQVR4nO3dS27jMBREUa2Hm+vl'
  '9HLdAyINI5YlknqfesUy7iQ/m6yDABnFx+vn0f78VUx11uP19kg/k7Lqv+nx/oGYCfqleZx+Nv2U'
  'aq1Px+P6y6pK3+yO8W9VmF17nQDf/ozC6VbqHHjwh1VigzpXwOPPooIbd7kBnn065d2sxRDw2lMr'
  '29b2nwBefg31vOXl54AfvpiKX3sF+PmrqrCdF4GtXl55b/sI2PYoymNPA2DzM+2c+ZI2wE6H2yqn'
  '9SyB/U5Jn99uxsDex+XLeysX4JijVy9mH0fgsDtULGwZX+Dgy5QoeI0I4PhbwRa/QxBw1vVwyrp7'
  'KHDuVbPKvW8CcPqdt7ppDjDI5Xe4XSYwzgrE90oGRpuD7y4QwJjTcJwfCBh2o9InxwIGH6viaRGB'
  '8VcrdE5QYPz5kM/2HjQw5pRo57muADDUpjgnGawGMMK45Wh7lYATVy6q28oBx89dl7ZXEjhm+uq0'
  'vcLArgYcuq06sAcGDW2PAbjZqZDpNhrg3hMePtoeFXBvloqVtkcI3GbMuHUbK3DvGo+etscM3L4r'
  'bqLb6IF7r++P9LN5twVwbzfa3i7Ae/76th2AP1G3YiYH1h9ZtMAjhDswEwLPsnEzswGvaREb8wA/'
  'R6JkJgG2suEzLg/sQcLEXBjYm4GDuSpwzPoExvWA40cvzVwMOGvrusZlgBEmRjjDbAWA0WZFO891'
  '6MCYa2Ke6jRcYPwR8U/YYIFLbFfinHDA+JPVOjMQMPJMdc+PAoy5DsEt8oEBR2G6kf4ZKfm90oBx'
  'JuC+o/7jO/l9o4F3002/dRzwnrTpC+htdUKL38EdWLS5m+i9C9OK2ccLWLogK9kDixZqMb1BNER+'
  'u5kBixZzQwNg0dpmu+dTYOl6ZLjqOrBovTNZeBFYujE933kaWLTxPdl8Ali0ua3tPwosXYQWFO6B'
  'RYvWlMgNsHQxG3f5Cixa/EaMToBFW6trr9/A0q3Yhdox8k2qRKeCx8XXVLk+HQ/R8vUO+g9edSUe'
  'Sf8cCAAAAABJRU5ErkJggg==',
);

ApiClient _mockNoteWithImagesApi({bool Function()? shouldFailImage}) {
  final api = ApiClient(baseUrl: 'http://note-image-test.local');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (options.path.endsWith('/content')) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'code': 0,
          'data': {
            'markdown': '''# 受力图辨析

## 课堂例图
下面展示两张课堂常见图片语法：

![[工程力学_习题1-4.png|240]]

![教材配图|180](_图/工程力学_图1-8.png)

非图片嵌入保留原文：![[某篇普通笔记]]
''',
          },
          'message': 'ok',
        },
      ));
      return;
    }
    if (options.path == '/api/notes/asset') {
      if (shouldFailImage?.call() ?? false) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: '离线测试',
        ));
        return;
      }
      handler.resolve(Response<List<int>>(
        requestOptions: options,
        statusCode: 200,
        data: _samplePngBytes,
      ));
      return;
    }
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: {'code': 0, 'data': {}, 'message': 'ok'},
    ));
  }));
  return api;
}

Future<void> _settleWithImages(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

Future<void> _exportPng(
  WidgetTester tester,
  GlobalKey key,
  String outputDir,
  String name,
) async {
  await tester.runAsync(() async {
    Directory(outputDir).createSync(recursive: true);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$outputDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parseObsidianImageTarget 与 parseMarkdownImage 正确解析路径、说明与宽度', () {
    final p1 = parseObsidianImageTarget('工程力学_习题7-8.png');
    expect(p1, isNotNull);
    expect(p1!.src, '工程力学_习题7-8.png');
    expect(p1.width, isNull);

    final p2 = parseObsidianImageTarget('工程力学_习题7-8.png|420');
    expect(p2!.src, '工程力学_习题7-8.png');
    expect(p2.width, 420);

    final p3 = parseObsidianImageTarget('_图/图1.png|受力分析|320x240');
    expect(p3!.src, '_图/图1.png');
    expect(p3.alt, '受力分析');
    expect(p3.width, 320);

    expect(parseObsidianImageTarget('普通笔记链接'), isNull);

    final m1 = parseMarkdownImage('教材配图|260', '_图/a.webp');
    expect(m1.src, '_图/a.webp');
    expect(m1.alt, '教材配图');
    expect(m1.width, 260);
  });

  test('NoteCheckController.validatedItems 放行图片附件且 NotesPage 过滤图片条目', () {
    final items = NoteCheckController.validatedItems([
      {
        'relative_path': '工程力学/受力图_2026-09-08.md',
        'sha256': 'a' * 64,
      },
      {
        'relative_path': '工程力学/_图/工程力学_习题1-4.png',
        'sha256': 'b' * 64,
      },
      {
        'relative_path': '工程力学/_图/图2.webp',
        'sha256': 'c' * 64,
      },
    ]);
    expect(items.length, 3);
    expect(
      NoteCheckController.isMarkdownNoteEntry(
          {'kind': 'image', 'relative_path': '工程力学/_图/工程力学_习题1-4.png'}),
      isFalse,
    );
    expect(
      NoteCheckController.isMarkdownNoteEntry(
          {'kind': 'note', 'relative_path': '工程力学/受力图_2026-09-08.md'}),
      isTrue,
    );
    expect(
      () => NoteCheckController.validatedItems([
        {'relative_path': '工程力学/非法.txt', 'sha256': 'd' * 64},
      ]),
      throwsFormatException,
    );
  });

  testWidgets('NoteDetailPage 渲染 Obsidian 与标准 Markdown 图片并支持点击放大与关闭',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _mockNoteWithImagesApi();
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: NoteDetailPage(
        noteId: 'vault_img_demo',
        title: '受力图辨析',
        course: '工程力学',
        apiClient: api,
      ),
    ));
    await _settleWithImages(tester);

    expect(find.byType(Image), findsNWidgets(2));
    expect(find.textContaining('无法解码'), findsNothing);
    expect(find.textContaining('%E5'), findsNothing);
    expect(find.text('教材配图'), findsOneWidget);
    expect(find.textContaining('某篇普通笔记'), findsOneWidget);

    // 点击第一张图进入全屏缩放预览
    await tester.tap(find.byKey(const ValueKey('note-image-card:工程力学_习题1-4.png')));
    await _settleWithImages(tester);

    expect(find.byType(NoteImageLightbox), findsOneWidget);
    expect(find.byKey(const Key('note-image-lightbox-viewer')), findsOneWidget);
    expect(find.textContaining('无法预览'), findsNothing);

    // 点击还原按钮与 Escape 键关闭大图回到正文
    await tester.tap(find.byKey(const Key('note-image-lightbox-reset')));
    await _settleWithImages(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleWithImages(tester);
    expect(find.byType(NoteImageLightbox), findsNothing);
  });

  testWidgets('NoteDetailPage 单图失败后清理缓存，重连点击重试可恢复显示',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var shouldFail = true;
    final api = _mockNoteWithImagesApi(shouldFailImage: () => shouldFail);
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: NoteDetailPage(
        noteId: 'vault_img_retry',
        title: '受力图辨析',
        course: '工程力学',
        apiClient: api,
      ),
    ));
    await _settleWithImages(tester);

    expect(
      find.byKey(const ValueKey('note-image-fallback:工程力学_习题1-4.png')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);

    shouldFail = false;
    await tester.tap(find.text('重试').first);
    await _settleWithImages(tester);

    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('图片加载失败时展示友好提示卡片，重连后点击重试可恢复显示',
      (tester) async {
    var shouldFail = true;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: NoteMarkdown(
            data: '![[缺失图.png|240]]',
            imageLoader: (_) async => shouldFail ? null : _samplePngBytes,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('note-image-fallback:缺失图.png')),
        findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.text('重试'));
    await _settleWithImages(tester);

    expect(find.byKey(const ValueKey('note-image-card:缺失图.png')),
        findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('多尺寸/深浅色/高对比/200%字号/全屏放大无溢出并导出评审截图',
      (tester) async {
    final output = Platform.environment['CNA_NOTE_IMAGE_UI_OUTPUT'];
    await tester.runAsync(loadFonts);

    final scenarios = [
      (
        name: 'portrait-390-1x-light-images',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        failImage: false,
        openLightbox: false,
      ),
      (
        name: 'portrait-390-1x-lightbox',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: true,
        failImage: false,
        openLightbox: true,
      ),
      (
        name: 'portrait-360-2x-dark-images',
        size: const Size(360, 900),
        scale: 2.0,
        dark: true,
        highContrast: false,
        reduceMotion: true,
        failImage: false,
        openLightbox: false,
      ),
      (
        name: 'portrait-360-2x-highcontrast-fallback',
        size: const Size(360, 900),
        scale: 2.0,
        dark: false,
        highContrast: true,
        reduceMotion: true,
        failImage: true,
        openLightbox: false,
      ),
      (
        name: 'landscape-844-1x-dark-images',
        size: const Size(844, 390),
        scale: 1.0,
        dark: true,
        highContrast: false,
        reduceMotion: false,
        failImage: false,
        openLightbox: false,
      ),
      (
        name: 'landscape-844-1x-lightbox',
        size: const Size(844, 390),
        scale: 1.0,
        dark: true,
        highContrast: false,
        reduceMotion: true,
        failImage: false,
        openLightbox: true,
      ),
      (
        name: 'desktop-1280-1x-light-images',
        size: const Size(1280, 800),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        failImage: false,
        openLightbox: false,
      ),
    ];

    for (final s in scenarios) {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = s.size;
      tester.view.devicePixelRatio = 1;
      final api = _mockNoteWithImagesApi(shouldFailImage: () => s.failImage);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: s.dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(s.scale),
              disableAnimations: s.reduceMotion,
              highContrast: s.highContrast,
            ),
            child: child!,
          ),
          home: NoteDetailPage(
            noteId: 'vault_img_demo',
            title: '受力图辨析',
            course: '工程力学',
            apiClient: api,
          ),
        ),
      ));
      await _settleWithImages(tester);

      if (s.openLightbox) {
        final cardFinder =
            find.byKey(const ValueKey('note-image-card:工程力学_习题1-4.png'));
        await tester.ensureVisible(cardFinder);
        await tester.pump();
        await tester.tap(cardFinder);
        await _settleWithImages(tester);
        expect(find.byType(NoteImageLightbox), findsOneWidget);
      }

      expect(tester.takeException(), isNull, reason: s.name);

      if (output != null && output.isNotEmpty) {
        await _exportPng(tester, boundaryKey, output, s.name);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      api.dio.close();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
