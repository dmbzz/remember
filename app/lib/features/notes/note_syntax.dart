import 'package:markdown/markdown.dart' as md;

/// 仅调整阅读器兼容语法，保留原始笔记文件和公式含义。
String normalizeNoteTex(String tex) {
  var result = tex.replaceAllMapped(
    RegExp(r'\\tag\*?\{([^{}]+)\}'),
    (match) => '\\quad\\text{(${match[1]!})}',
  );
  // 历史笔记中的 JSON 转义曾把 \\right 的 \\r 写成换行。
  if (result.contains(r'\left')) {
    result =
        result.replaceAll(RegExp(r'[\r\n]+\s*ight(?=[\)\]\}])'), r'\right');
  }
  return result;
}

String prepareNoteMarkdown(String source) {
  var text = source.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n');
  if (text.startsWith('---\n')) {
    final end = text.indexOf('\n---', 4);
    if (end >= 0) text = text.substring(end + 4).trimLeft();
  }
  return text.replaceAllMapped(
    RegExp(r'^(\s*>\s*)\[!(\w+)\][+-]?\s*(.*)$', multiLine: true),
    (match) => '${match[1]}**${match[3]!.isEmpty ? match[2] : match[3]}**',
  );
}

/// Keep large notes in small, independently laid out sections. Boundaries are
/// only placed outside fenced code, display math and list continuations.
List<String> splitNoteMarkdown(String source, {int targetLength = 2600}) {
  final lines = prepareNoteMarkdown(source).split('\n');
  final sections = <String>[];
  final buffer = StringBuffer();
  String? fence;
  String? mathEnd;

  void flush() {
    final section = buffer.toString().trim();
    if (section.isNotEmpty) sections.add(section);
    buffer.clear();
  }

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final trimmed = line.trim();
    final next = index + 1 < lines.length ? lines[index + 1].trimLeft() : '';
    if (fence == null &&
        mathEnd == null &&
        buffer.length >= 700 &&
        RegExp(r'^#{1,6}\s').hasMatch(trimmed)) {
      flush();
    }

    buffer.writeln(line);
    final marker = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (fence != null) {
      if (trimmed.startsWith(fence)) fence = null;
    } else if (marker != null && mathEnd == null) {
      fence = marker;
    } else if (mathEnd != null) {
      if (trimmed.contains(mathEnd)) mathEnd = null;
    } else if (trimmed.startsWith(r'$$') &&
        !trimmed.substring(2).contains(r'$$')) {
      mathEnd = r'$$';
    } else if (trimmed.startsWith(r'\[') && !trimmed.contains(r'\]')) {
      mathEnd = r'\]';
    }

    final nextContinuesList = RegExp(r'^(?:[-*+]\s|\d+[.)]\s)').hasMatch(next);
    if (buffer.length >= targetLength &&
        trimmed.isEmpty &&
        fence == null &&
        mathEnd == null &&
        !nextContinuesList) {
      flush();
    }
  }
  flush();
  return sections.isEmpty ? [''] : sections;
}

class NoteMathInlineSyntax extends md.InlineSyntax {
  NoteMathInlineSyntax()
      : super(r'\$\$([^\n]+?)\$\$|\$([^$\n]+?)\$|\\\((.+?)\\\)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element.empty('note-math');
    node.attributes['tex'] = match[1] ?? match[2] ?? match[3] ?? '';
    parser.addNode(node);
    return true;
  }
}

class NoteMathBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s{0,3}(\$\$|\\\[)(.*)$');

  @override
  bool canParse(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current.content);
    if (match == null) return false;
    final end = match[1] == r'$$' ? r'$$' : r'\]';
    if (match[2]!.contains(end)) return true;
    for (var offset = 1; parser.peek(offset) != null; offset++) {
      if (parser.peek(offset)!.content.contains(end)) return true;
    }
    return false;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current.content)!;
    final end = match[1] == r'$$' ? r'$$' : r'\]';
    final lines = <String>[];
    var content = match[2]!;
    while (true) {
      final closing = content.indexOf(end);
      if (closing >= 0) {
        lines.add(content.substring(0, closing));
        parser.advance();
        break;
      }
      lines.add(content);
      parser.advance();
      if (parser.isDone) break;
      content = parser.current.content;
    }
    return md.Element.empty('note-equation')
      ..attributes['tex'] = lines.join('\n').trim();
  }
}

class NoteMermaidSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s{0,3}(`{3,}|~{3,})mermaid\s*$');

  @override
  md.Node parse(md.BlockParser parser) {
    final fence = pattern.firstMatch(parser.current.content)![1]!;
    final lines = <String>[];
    parser.advance();
    while (!parser.isDone) {
      final line = parser.current.content;
      parser.advance();
      if (line.trim().startsWith(fence)) break;
      lines.add(line);
    }
    return md.Element.empty('note-mindmap')
      ..attributes['source'] = lines.join('\n');
  }
}

class MindmapNode {
  final String label;
  final List<MindmapNode> children = [];
  MindmapNode(this.label);
}

MindmapNode? parseMindmap(String source) {
  final stack = <(int, MindmapNode)>[];
  MindmapNode? root;
  for (final raw in source.split('\n')) {
    final line = raw.replaceAll('\t', '  ');
    final label = line.trim();
    if (label.isEmpty ||
        label == 'mindmap' ||
        label.startsWith('%%') ||
        label.startsWith('::')) continue;
    final indent = line.length - line.trimLeft().length;
    var cleaned = label;
    final shape = RegExp(
            r'^(?:[\w-]+)?(?:\(\(|\[\[|\(|\[|\{)(.+?)(?:\)\)|\]\]|\)|\]|\})$')
        .firstMatch(label);
    if (shape != null) cleaned = shape[1]!;
    cleaned = cleaned
        .replaceAll('"', '')
        .replaceAll('`', '')
        .replaceAll('<br/>', '\n')
        .replaceAll('<br>', '\n');
    final node = MindmapNode(cleaned);
    while (stack.isNotEmpty && indent <= stack.last.$1) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      if (root == null) {
        root = node;
      } else {
        root.children.add(node);
      }
    } else {
      stack.last.$2.children.add(node);
    }
    stack.add((indent, node));
  }
  return root;
}
