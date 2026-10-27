import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:class_notes_assistant/features/notes/note_detail_page.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'note_rendering_test.dart' show loadFonts;

void main() {
  testWidgets('真实冲突文件长标题在矮屏两倍字号可读，加载完成不换标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const title =
        '电路的基本概念与基尔霍夫定律_2026-09-03.sync-conflict-20261007-212932-2MMFICR';
    const id = 'vault-long-fixture';
    final api = ApiClient(baseUrl: 'http://note.test');
    VoidCallback? completeContent;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path.endsWith('/content')) {
        completeContent = () => handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: {
              'code': 0,
              'data': {'markdown': '# 演示正文\n\n已成功加载内容。'},
              'message': 'ok'
            }));
      } else {
        handler
            .resolve(Response(requestOptions: request, statusCode: 200, data: {
          'code': 0,
          'data': {
            'items': [
              {
                'note_id': id,
                'topic': title,
                'course_name': '电工电子',
                'class_date': '2026-09-03'
              }
            ],
            'total': 1
          },
          'message': 'ok'
        }));
      }
    }));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: NotesPage(apiClient: api)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pump(const Duration(milliseconds: 141));
    await tester.pump(const Duration(milliseconds: 60));
    final flyingTitle = find.byKey(const ValueKey('note-opening-title:$id'));
    expect(flyingTitle, findsOneWidget);
    final element = tester.element(flyingTitle);
    await tester.pump(const Duration(milliseconds: 350));
    expect(identical(element, tester.element(flyingTitle)), isTrue);
    expect(find.byType(NoteDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(completeContent, isNotNull);
    completeContent!();
    await tester.pumpAndSettle();
    expect(identical(element, tester.element(flyingTitle)), isTrue);
    final titleText = tester.widget<Text>(flyingTitle);
    expect(titleText.maxLines, inInclusiveRange(1, 3));
    expect(titleText.overflow, TextOverflow.ellipsis);
    final body = find.descendant(
        of: find.byType(NoteDetailPage), matching: find.byType(ListView));
    expect(tester.getSize(body).height, greaterThan(150));
    expect(find.byType(NoteMarkdown), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsNothing);
    expect(find.text(title), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dio.close();
  });
}
