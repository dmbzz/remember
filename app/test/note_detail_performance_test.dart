import 'dart:io';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/note_detail_page.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:class_notes_assistant/features/notes/note_syntax.dart';
import 'package:class_notes_assistant/platform/local_notes_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, int> specialBlockCounts(String source) {
  final document = md.Document(
    blockSyntaxes: [NoteMathBlockSyntax(), NoteMermaidSyntax()],
    inlineSyntaxes: [NoteMathInlineSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final counts = <String, int>{};
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (const {'note-math', 'note-equation', 'note-mindmap'}
        .contains(node.tag)) {
      counts[node.tag] = (counts[node.tag] ?? 0) + 1;
    }
    for (final child in node.children ?? <md.Node>[]) {
      visit(child);
    }
  }

  for (final node in document.parseLines(source.split('\n'))) {
    visit(node);
  }
  return counts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分段保留公式、导图和围栏代码', () {
    final text = '${'正文段落。' * 400}\n\n'
        '\$\$\n\\frac{a}{b}\n\$\$\n\n'
        '```mermaid\nmindmap\n  root((主题))\n    子节点\n```\n\n'
        '```dart\nfinal value = r"\$x\$";\n```\n\n'
        '${'末尾段落。' * 400}';
    final parts = splitNoteMarkdown(text, targetLength: 1000);
    expect(parts.length, greaterThan(1));
    expect(parts.where((part) => part.contains(r'\frac{a}{b}')).length, 1);
    expect(parts.where((part) => part.contains('```mermaid')).length, 1);
    expect(parts.where((part) => part.contains('```dart')).length, 1);
    expect(parts.join('\n\n'), text);
  });

  final vault = Platform.environment['CNA_VAULT_TEST_ROOT'];
  if (vault != null) {
    test('真实大笔记分段保留公式和思维导图', () {
      final files = Directory(vault)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      for (final file in files.take(5)) {
        final source = prepareNoteMarkdown(file.readAsStringSync());
        final actual = <String, int>{};
        final sections = splitNoteMarkdown(source);
        expect(sections.length, greaterThan(1), reason: file.path);
        expect(
            sections
                .map((section) => section.length)
                .reduce((a, b) => a > b ? a : b),
            lessThan(20000),
            reason: file.path);
        for (final section in sections) {
          for (final entry in specialBlockCounts(section).entries) {
            actual[entry.key] = (actual[entry.key] ?? 0) + entry.value;
          }
        }
        expect(actual, specialBlockCounts(source), reason: file.path);
      }
    });
  }

  testWidgets('打开长笔记只构建屏幕附近的段落', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final text =
        List.generate(100, (index) => '## 第 $index 节\n\n${'这是一段课堂内容。' * 220}')
            .join('\n\n');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LocalNotesBridge.channel,
      (call) async => text,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalNotesBridge.channel, null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NoteDetailPage(
                            noteId: 'local:test',
                            title: '长笔记',
                            course: '物理',
                            apiClient: ApiClient(),
                          ),
                        )),
                    child: const Text('打开'),
                  ))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('长笔记'), findsOneWidget);
    expect(find.byType(NoteMarkdown).evaluate().length, lessThan(10));
    expect(find.textContaining('第 99 节'), findsNothing);
  });
}
