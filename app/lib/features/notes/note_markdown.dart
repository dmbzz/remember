import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import '../../core/theme.dart';
import 'mindmap_view.dart';
import 'note_syntax.dart';

/// 离线原生阅读器：Markdown、LaTeX 与 Mermaid mindmap。
class NoteMarkdown extends StatelessWidget {
  final String data;
  final double fontSize;
  const NoteMarkdown({super.key, required this.data, this.fontSize = 17});
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final colors = Theme.of(context).colorScheme;
        final body = TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontFamilyFallback: AppTheme.fontFallback,
            fontSize: fontSize,
            height: 1.8,
            color: colors.onSurface);
        return MarkdownBody(
          data: prepareNoteMarkdown(data),
          selectable: false,
          fitContent: false,
          blockSyntaxes: [NoteMathBlockSyntax(), NoteMermaidSyntax()],
          inlineSyntaxes: [NoteMathInlineSyntax()],
          builders: {
            'p': _ParagraphBuilder(body, constraints.maxWidth),
            'note-math': _MathBuilder(fontSize, constraints.maxWidth, false),
            'note-equation': _MathBuilder(fontSize, constraints.maxWidth, true),
            'note-mindmap': _MindmapBuilder(),
          },
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: body,
            h1: body.copyWith(
                fontSize: fontSize + 10,
                fontWeight: FontWeight.w600,
                height: 1.4),
            h2: body.copyWith(
                fontSize: fontSize + 5,
                fontWeight: FontWeight.w600,
                height: 1.5),
            h3: body.copyWith(
                fontSize: fontSize + 2, fontWeight: FontWeight.w600),
            h1Padding: const EdgeInsets.only(top: 18, bottom: 12),
            h2Padding: const EdgeInsets.only(top: 24, bottom: 10),
            h3Padding: const EdgeInsets.only(top: 18, bottom: 6),
            blockSpacing: 16,
            listBullet: body,
            blockquote: body,
            blockquotePadding: const EdgeInsets.all(16),
            blockquoteDecoration: BoxDecoration(
              color: colors.primary.withOpacity(.055),
              borderRadius: BorderRadius.circular(10),
              border: Border(
                  left: BorderSide(
                      color: colors.primary.withOpacity(.65), width: 3)),
            ),
            code: body.copyWith(
                fontSize: fontSize - 2,
                backgroundColor: colors.onSurface.withOpacity(.045)),
            codeblockPadding: const EdgeInsets.all(16),
            codeblockDecoration: BoxDecoration(
                color: colors.onSurface.withOpacity(.045),
                borderRadius: BorderRadius.circular(12)),
            tableBody: body.copyWith(fontSize: fontSize - 1),
            tableHead: body.copyWith(
                fontSize: fontSize - 1, fontWeight: FontWeight.w600),
            tableCellsPadding: const EdgeInsets.all(10),
            tableBorder:
                TableBorder.all(color: colors.outlineVariant, width: .6),
            horizontalRuleDecoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outlineVariant))),
          ),
        );
      });
}

class _ParagraphBuilder extends MarkdownElementBuilder {
  final TextStyle style;
  final double width;
  _ParagraphBuilder(this.style, this.width);
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    InlineSpan span(md.Node node, TextStyle current) {
      if (node is md.Text) return TextSpan(text: node.text, style: current);
      final item = node as md.Element;
      if (item.tag == 'note-math') {
        return WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: NoteEquation(
              tex: item.attributes['tex'] ?? '',
              fontSize: style.fontSize!,
              maxWidth: width,
              display: false,
            ));
      }
      if (item.tag == 'br') return const TextSpan(text: '\n');
      final next = switch (item.tag) {
        'strong' => current.copyWith(fontWeight: FontWeight.w600),
        'em' => current.copyWith(fontStyle: FontStyle.italic),
        'del' => current.copyWith(decoration: TextDecoration.lineThrough),
        'code' => current.copyWith(
            backgroundColor:
                Theme.of(context).colorScheme.onSurface.withOpacity(.05)),
        'a' => current.copyWith(color: Theme.of(context).colorScheme.primary),
        _ => current,
      };
      return TextSpan(style: next, children: [
        for (final child in item.children ?? <md.Node>[]) span(child, next)
      ]);
    }

    return Text.rich(TextSpan(style: style, children: [
      for (final child in element.children ?? <md.Node>[]) span(child, style)
    ]));
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  final double fontSize;
  final double width;
  final bool display;
  _MathBuilder(this.fontSize, this.width, this.display);
  @override
  bool isBlockElement() => display;
  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    return NoteEquation(
        tex: element.attributes['tex'] ?? '',
        fontSize: fontSize,
        maxWidth: width,
        display: display);
  }
}

class NoteEquation extends StatelessWidget {
  final String tex;
  final double fontSize;
  final double maxWidth;
  final bool display;
  const NoteEquation(
      {super.key,
      required this.tex,
      required this.fontSize,
      required this.maxWidth,
      required this.display});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final equation = Semantics(
        label: '数学公式 $tex',
        child: Math.tex(
          normalizeNoteTex(tex),
          mathStyle: display ? MathStyle.display : MathStyle.text,
          textScaleFactor: 1,
          textStyle: TextStyle(
              fontSize: MediaQuery.textScalerOf(context).scale(fontSize),
              color: colors.onSurface),
          settings: const TexParserSettings(strict: Strict.ignore),
          onErrorFallback: (error) => _EquationFallback(tex: tex),
        ));
    final scroll = _MathViewport(display: display, child: equation);
    if (!display) {
      return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth), child: scroll);
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
          color: colors.onSurface.withOpacity(.025),
          borderRadius: BorderRadius.circular(10)),
      child: Tooltip(message: '左右滑动查看完整公式', child: scroll),
    );
  }
}

class _MathViewport extends StatefulWidget {
  final bool display;
  final Widget child;
  const _MathViewport({required this.display, required this.child});
  @override
  State<_MathViewport> createState() => _MathViewportState();
}

class _MathViewportState extends State<_MathViewport> {
  final _controller = ScrollController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        thickness: 3,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: Padding(
              padding: EdgeInsets.fromLTRB(
                  widget.display ? 12 : 2,
                  widget.display ? 12 : 3,
                  widget.display ? 12 : 2,
                  widget.display ? 14 : 7),
              child: widget.child),
        ),
      );
}

class _EquationFallback extends StatelessWidget {
  final String tex;
  const _EquationFallback({required this.tex});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('此公式暂不能排版，原式如下', style: Theme.of(context).textTheme.bodySmall),
        SelectableText(tex,
            style:
                const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 15)),
      ]);
}

class _MindmapBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
          TextStyle? preferredStyle, TextStyle? parentStyle) =>
      MindmapView(source: element.attributes['source'] ?? '');
}
