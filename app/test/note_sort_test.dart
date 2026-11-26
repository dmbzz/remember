import 'dart:io';
import 'dart:ui' as ui;

import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/note_sort.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_rendering_test.dart' show loadFonts;

ApiClient _mockNotesApi(List<Map<String, dynamic>> notes) {
  final api = ApiClient(baseUrl: 'http://notes-sort-test.local');
  api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (options.path == '/api/notes') {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'code': 0,
          'data': {'items': notes, 'total': notes.length},
          'message': 'ok',
        },
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

List<Map<String, dynamic>> _sampleNotes() => [
      {
        'note_id': 'n_old',
        'course_name': '工程力学',
        'topic': '工程力学导论与静力学',
        'class_date': '2026-09-01',
        'lesson': 1,
        'updated_at': '2026-11-25T20:00:00Z',
      },
      {
        'note_id': 'n_undated',
        'course_name': '普通物理1',
        'topic': '普通物理1作业清单',
        'class_date': null,
        'updated_at': '2026-11-25T23:00:00Z',
      },
      {
        'note_id': 'n_mid',
        'course_name': '线性代数',
        'topic': '2026年10月15日 向量空间',
        'class_date': null,
        'relative_path': '线性代数/2026年10月15日 向量空间.md',
        'updated_at': '2026-10-15T12:00:00Z',
      },
      {
        'note_id': 'n_new',
        'course_name': '工程力学',
        'topic': '圆轴扭转',
        'class_date': '2026-11-24',
        'lesson': 18,
        'updated_at': '2026-11-24T12:00:00Z',
      },
    ];

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

  test('extractNoteDateFromText 兼容多种日期时间格式并过滤非法数字', () {
    expect(extractNoteDateFromText('圆轴扭转_2026-11-24'), DateTime.utc(2026, 11, 24));
    expect(extractNoteDateFromText('2026-09-05_周报'), DateTime.utc(2026, 9, 5));
    expect(extractNoteDateFromText('实验_2026.10.14'), DateTime.utc(2026, 10, 14));
    expect(extractNoteDateFromText('2026/09/18 电路'), DateTime.utc(2026, 9, 18));
    expect(extractNoteDateFromText('2026年9月1日 导论'), DateTime.utc(2026, 9, 1));
    expect(extractNoteDateFromText('20261015 线性代数'), DateTime.utc(2026, 10, 15));
    expect(
      extractNoteDateFromText('复盘 2026-10-14 14:30'),
      DateTime.utc(2026, 10, 14, 14, 30),
    );
    expect(extractNoteDateFromText('编号_2026-02-30'), isNull);
    expect(extractNoteDateFromText('普通物理1作业清单'), isNull);
  });

  test('sortNotesByTitleTime 忽略 updated_at 并把无日期笔记放在末尾', () {
    final items = _sampleNotes();
    final desc = sortNotesByTitleTime(items, NoteSortOrder.newestFirst);
    expect(
      desc.map((e) => e['note_id']).toList(),
      ['n_new', 'n_mid', 'n_old', 'n_undated'],
    );

    final asc = sortNotesByTitleTime(items, NoteSortOrder.oldestFirst);
    expect(
      asc.map((e) => e['note_id']).toList(),
      ['n_old', 'n_mid', 'n_new', 'n_undated'],
    );
  });

  testWidgets('NotesPage 默认按标题时间最新优先，一键切换从早到晚并持久化偏好',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _mockNotesApi(_sampleNotes());
    addTearDown(api.dio.close);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: NotesPage(apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('最近笔记 · 4'), findsOneWidget);
    expect(find.text('最新优先'), findsOneWidget);

    double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(topOf('圆轴扭转'), lessThan(topOf('2026年10月15日 向量空间')));
    expect(topOf('2026年10月15日 向量空间'), lessThan(topOf('工程力学导论与静力学')));
    expect(topOf('工程力学导论与静力学'), lessThan(topOf('普通物理1作业清单')));

    // 点击切换为从早到晚
    await tester.tap(find.byKey(const Key('notes-sort-order-button')));
    await tester.pumpAndSettle();

    expect(find.text('早期笔记 · 4'), findsOneWidget);
    expect(find.text('从早到晚'), findsOneWidget);
    expect(topOf('工程力学导论与静力学'), lessThan(topOf('2026年10月15日 向量空间')));
    expect(topOf('2026年10月15日 向量空间'), lessThan(topOf('圆轴扭转')));
    expect(topOf('圆轴扭转'), lessThan(topOf('普通物理1作业清单')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(NoteSortOrder.prefKey), 'oldest_first');

    // 重新进入页面应记住上次选择的「从早到晚」
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: NotesPage(apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(find.text('从早到晚'), findsOneWidget);
    expect(topOf('工程力学导论与静力学'), lessThan(topOf('圆轴扭转')));

    // 筛选课程后仍按标题时间排序
    await tester.tap(find.text('工程力学').first);
    await tester.pumpAndSettle();
    expect(find.text('早期笔记 · 2'), findsOneWidget);
    expect(topOf('工程力学导论与静力学'), lessThan(topOf('圆轴扭转')));
  });

  testWidgets('无障碍语义与减动模式即时切换正常', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _mockNotesApi(_sampleNotes());
    addTearDown(api.dio.close);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: NotesPage(apiClient: api),
      ));
      await tester.pumpAndSettle();

      final btn = find.byKey(const Key('notes-sort-order-button'));
      final node = tester.getSemantics(btn);
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(node.label, contains('最新优先'));

      await tester.tap(btn);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('从早到晚'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('多尺寸/深浅色/高对比/200%字号/横竖屏桌面端无溢出并导出评审截图',
      (tester) async {
    final output = Platform.environment['CNA_NOTE_SORT_UI_OUTPUT'];
    await tester.runAsync(loadFonts);

    final scenarios = [
      (
        name: 'portrait-390-1x-light-desc',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        order: NoteSortOrder.newestFirst,
      ),
      (
        name: 'portrait-390-1x-light-asc',
        size: const Size(390, 900),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        order: NoteSortOrder.oldestFirst,
      ),
      (
        name: 'portrait-360-2x-dark-desc',
        size: const Size(360, 900),
        scale: 2.0,
        dark: true,
        highContrast: false,
        reduceMotion: true,
        order: NoteSortOrder.newestFirst,
      ),
      (
        name: 'portrait-360-2x-highcontrast-asc',
        size: const Size(360, 900),
        scale: 2.0,
        dark: false,
        highContrast: true,
        reduceMotion: true,
        order: NoteSortOrder.oldestFirst,
      ),
      (
        name: 'landscape-844-1x-dark-desc',
        size: const Size(844, 390),
        scale: 1.0,
        dark: true,
        highContrast: false,
        reduceMotion: false,
        order: NoteSortOrder.newestFirst,
      ),
      (
        name: 'desktop-1280-1x-light-desc',
        size: const Size(1280, 800),
        scale: 1.0,
        dark: false,
        highContrast: false,
        reduceMotion: false,
        order: NoteSortOrder.newestFirst,
      ),
    ];

    for (final s in scenarios) {
      SharedPreferences.setMockInitialValues({
        NoteSortOrder.prefKey: s.order.wireValue,
      });
      tester.view.physicalSize = s.size;
      tester.view.devicePixelRatio = 1;
      final api = _mockNotesApi(_sampleNotes());
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
          home: NotesPage(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: s.name);
      expect(find.byKey(const Key('notes-sort-order-button')), findsOneWidget);

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
