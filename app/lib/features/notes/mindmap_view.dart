import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'note_syntax.dart';

class MindmapView extends StatefulWidget {
  final String source;
  final bool fullscreen;
  const MindmapView({super.key, required this.source, this.fullscreen = false});
  @override
  State<MindmapView> createState() => _MindmapViewState();
}

class _MindmapViewState extends State<MindmapView> {
  final _transform = TransformationController();
  bool _positioned = false;
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MindmapView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _positioned = false;
  }

  @override
  Widget build(BuildContext context) {
    final root = parseMindmap(widget.source);
    final colors = Theme.of(context).colorScheme;
    if (root == null) return const Text('思维导图暂无内容');
    final layout = _DiagramLayout(root, MediaQuery.textScalerOf(context));
    return Container(
      decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(16)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(children: [
            Icon(Icons.account_tree_outlined, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('思维导图',
                    style: TextStyle(fontWeight: FontWeight.w600))),
            IconButton(
                tooltip: '显示完整导图',
                icon: const Icon(Icons.fit_screen_rounded),
                onPressed: () => setState(() => _positioned = false)),
            if (!widget.fullscreen)
              IconButton(
                  tooltip: '展开导图',
                  icon: const Icon(Icons.open_in_full_rounded),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(root.label)),
                                body: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: MindmapView(
                                        source: widget.source,
                                        fullscreen: true)),
                              )))),
          ]),
        ),
        SizedBox(
          height: widget.fullscreen
              ? math.max(320, MediaQuery.sizeOf(context).height - 200)
              : 380,
          width: double.infinity,
          child: LayoutBuilder(builder: (context, constraints) {
            if (!_positioned) {
              final scale = math.min(
                  1.0,
                  math.min(constraints.maxWidth / layout.width,
                      constraints.maxHeight / layout.height));
              _transform.value = Matrix4.identity()
                ..translate((constraints.maxWidth - layout.width * scale) / 2,
                    (constraints.maxHeight - layout.height * scale) / 2)
                ..scale(scale);
              _positioned = true;
            }
            return ClipRect(
                child: InteractiveViewer(
              transformationController: _transform,
              constrained: false,
              minScale: .08,
              maxScale: 3.0,
              boundaryMargin: const EdgeInsets.all(200),
              child: SizedBox(
                  width: layout.width,
                  height: layout.height,
                  child: Stack(children: [
                    Positioned.fill(
                        child: CustomPaint(
                            painter: _ConnectionsPainter(layout.entries,
                                colors.brightness == Brightness.dark))),
                    for (final item in layout.entries)
                      Positioned.fromRect(
                          rect: item.rect,
                          child: Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: item.parent == null
                                  ? colors.primary
                                  : Color.alphaBlend(
                                      item.color.withOpacity(.08),
                                      colors.surface),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: item.parent == null
                                      ? colors.primary
                                      : item.color.withOpacity(.45)),
                            ),
                            child: Text(item.node.label,
                                style: TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontSize: 14,
                                    height: 1.4,
                                    fontWeight: FontWeight.w600,
                                    color: item.parent == null
                                        ? colors.onPrimary
                                        : colors.onSurface)),
                          )),
                  ])),
            ));
          }),
        ),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Text('双指缩放 · 拖动查看分支',
                style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }
}

class _DiagramEntry {
  final MindmapNode node;
  final Rect rect;
  final _DiagramEntry? parent;
  final Color color;
  _DiagramEntry(this.node, this.rect, this.parent, this.color);
}

class _DiagramLayout {
  static const _nodeWidth = 194.0;
  static const _step = 238.0;
  final entries = <_DiagramEntry>[];
  final _spans = <MindmapNode, double>{};
  final _heights = <MindmapNode, double>{};
  double width = 0;
  double height = 0;
  static const _palette = [
    Color(0xFF0066CC),
    Color(0xFF14806A),
    Color(0xFF8061B8),
    Color(0xFFAE6817),
    Color(0xFFB44F79),
    Color(0xFF39748A)
  ];
  _DiagramLayout(MindmapNode root, TextScaler scaler) {
    double measure(MindmapNode node) {
      final painter = TextPainter(
          text: TextSpan(
              text: node.label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 14,
                  height: 1.4,
                  fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
          textScaler: scaler)
        ..layout(maxWidth: _nodeWidth - 28);
      final ownHeight = math.max(56.0, painter.height + 24);
      painter.dispose();
      _heights[node] = ownHeight;
      final children = node.children.map(measure).toList();
      return _spans[node] = math.max(
          ownHeight,
          children.fold(0.0, (a, b) => a + b) +
              math.max(0, children.length - 1) * 18);
    }

    height = measure(root) + 40;
    void position(MindmapNode node, int depth, double top,
        _DiagramEntry? parent, Color color) {
      final ownHeight = _heights[node]!;
      final item = _DiagramEntry(
          node,
          Rect.fromLTWH(20 + depth * _step,
              top + (_spans[node]! - ownHeight) / 2, _nodeWidth, ownHeight),
          parent,
          color);
      entries.add(item);
      width = math.max(width, item.rect.right + 20);
      var y = top;
      for (var i = 0; i < node.children.length; i++) {
        final child = node.children[i];
        position(child, depth + 1, y, item,
            depth == 0 ? _palette[i % _palette.length] : color);
        y += _spans[child]! + 18;
      }
    }

    position(root, 0, 20, null, _palette.first);
  }
}

class _ConnectionsPainter extends CustomPainter {
  final List<_DiagramEntry> entries;
  final bool dark;
  _ConnectionsPainter(this.entries, this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in entries) {
      if (entry.parent == null) continue;
      final start = entry.parent!.rect.centerRight;
      final end = entry.rect.centerLeft;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx + 24, start.dy, end.dx - 24, end.dy, end.dx, end.dy);
      canvas.drawPath(
          path,
          Paint()
            ..color = entry.color.withOpacity(dark ? .8 : .55)
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_ConnectionsPainter old) =>
      old.entries != entries || old.dark != dark;
}
