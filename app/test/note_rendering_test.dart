import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/features/notes/note_markdown.dart';
import 'package:class_notes_assistant/features/notes/note_syntax.dart';

const example = r'''
## 相量法与正弦量

如果已知 $u_1(t) = \sqrt{2}U_1\sin(\omega t + \varphi_1)$ 与 $u_2(t) = \sqrt{2}U_2\sin(\omega t + \varphi_2)$，直接在时域相加需要展开正弦和差化积公式。

$$
\begin{aligned}
\dot{U} &= U_1 e^{j\varphi_1}+U_2 e^{j\varphi_2} \\
u(t) &= \sqrt{2}|\dot{U}|\sin(\omega t+\arg\dot{U})
\end{aligned}
$$

> [!tip] 💡 拓展｜把三角函数变为复数运算
> 先相加相量，再恢复到时域。◉课堂 · ◉教材

```mermaid
mindmap
  root((正弦交流电))
    三要素
      有效值
      初相位
    相量法
      复数相加
      回到时域
```
''';

List<md.Element> elements(String source) {
  final document = md.Document(
      blockSyntaxes: [NoteMathBlockSyntax(), NoteMermaidSyntax()],
      inlineSyntaxes: [NoteMathInlineSyntax()],
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false);
  final result = <md.Element>[];
  void visit(md.Node node) {
    if (node is md.Element) {
      result.add(node);
      for (final child in node.children ?? <md.Node>[]) {
        visit(child);
      }
    }
  }

  for (final node
      in document.parseLines(prepareNoteMarkdown(source).split('\n'))) {
    visit(node);
  }
  return result;
}

Future<void> loadFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family']);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset']));
    }
    await loader.load();
  }
  // 测试引擎不自动读取系统字体，仅在预览测试中注册系统自带 Emoji。
  final emoji = File(r'C:\Windows\Fonts\seguiemj.ttf');
  if (emoji.existsSync()) {
    final loader = FontLoader('Segoe UI Emoji')
      ..addFont(Future.value(ByteData.sublistView(emoji.readAsBytesSync())));
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LaTeX 与导图语法保持原式，普通代码不解析公式', () {
    final nodes = elements(example);
    expect(nodes.where((e) => e.tag == 'note-math').length, 2);
    expect(nodes.where((e) => e.tag == 'note-equation').length, 1);
    final diagram = nodes.singleWhere((e) => e.tag == 'note-mindmap');
    expect(parseMindmap(diagram.attributes['source']!)!.children.length, 2);
    expect(elements(r'`$raw$`').where((e) => e.tag == 'note-math'), isEmpty);
    expect(
        elements(r'\(x^2\)')
            .where((e) => e.tag == 'note-math')
            .single
            .attributes['tex'],
        'x^2');
    expect(
        elements('\\[\n\\frac{1}{2}\n\\]')
            .where((e) => e.tag == 'note-equation')
            .length,
        1);
  });

  final vault = Platform.environment['CNA_VAULT_TEST_ROOT'];
  if (vault != null) {
    test('真实笔记全部公式与思维导图解析审计', () {
      var notes = 0, formulas = 0, diagrams = 0;
      final failures = <Map<String, String>>[];
      for (final file
          in Directory(vault).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.md') ||
            file.path.contains('${Platform.pathSeparator}00-') ||
            file.path.contains('${Platform.pathSeparator}转写原文')) continue;
        notes++;
        for (final element in elements(file.readAsStringSync())) {
          if (element.tag == 'note-mindmap') {
            diagrams++;
            expect(parseMindmap(element.attributes['source']!), isNotNull);
          }
          if (element.tag == 'note-math' || element.tag == 'note-equation') {
            formulas++;
            final tex = element.attributes['tex']!;
            final math = Math.tex(normalizeNoteTex(tex),
                settings: const TexParserSettings(strict: Strict.ignore));
            if (math.parseError != null) {
              failures.add({
                'file': file.path,
                'tex': tex,
                'error': math.parseError.toString()
              });
            }
          }
        }
      }
      final report = {
        'notes': notes,
        'formulas': formulas,
        'mindmaps': diagrams,
        'failures': failures
      };
      final reportPath = Platform.environment['CNA_RENDER_AUDIT'];
      if (reportPath != null) {
        File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report));
      }
      debugPrint(
          '真实库审计：$notes 篇、$formulas 个公式、$diagrams 张导图、${failures.length} 个公式解析错误');
      for (final failure in failures.take(4)) {
        debugPrint(failure.toString());
      }
      expect(failures, isEmpty);
    });
  }

  for (final setting in [
    (390.0, false, 1.0),
    (390.0, true, 2.0),
    (1000.0, false, 1.0)
  ]) {
    testWidgets('阅读排版 ${setting.$1} 深色=${setting.$2} 缩放=${setting.$3}',
        (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = Size(setting.$1, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(loadFonts);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: setting.$2 ? AppTheme.darkTheme : AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(setting.$3)),
                child: child!),
            home: Scaffold(
                appBar: AppBar(title: const Text('课堂笔记')),
                body: SingleChildScrollView(
                    child: Center(
                        child: Container(
                  constraints: const BoxConstraints(maxWidth: 780),
                  padding: const EdgeInsets.all(24),
                  child: const NoteMarkdown(data: example),
                )))),
          )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNWidgets(3));
      final output = Platform.environment['CNA_UI_OUTPUT'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary = boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$output/阅读-${setting.$1.toInt()}-${setting.$2 ? "深色" : "浅色"}-${setting.$3}.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  if (vault != null) {
    testWidgets('真实库每篇笔记在手机宽度下构建阅读器', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(loadFonts);
      var rendered = 0;
      for (final file
          in Directory(vault).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.md') ||
            file.path.contains('${Platform.pathSeparator}00-') ||
            file.path.contains('${Platform.pathSeparator}转写原文')) continue;
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectionArea(
                          child: NoteMarkdown(
                              key: ValueKey(file.path),
                              data: file.readAsStringSync()))))),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: file.path);
        expect(find.text('此公式暂不能排版，原式如下'), findsNothing, reason: file.path);
        rendered++;
      }
      debugPrint('真实库手机阅读器构建通过：$rendered 篇');
    });
  }
}
