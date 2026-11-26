import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/shapes.dart';

typedef NoteImageLoader = Future<Uint8List?> Function(String ref);

String _displayImageName(String src) {
  var decoded = src;
  if (decoded.contains('%')) {
    try {
      decoded = Uri.decodeFull(decoded);
    } catch (_) {}
  }
  final normalized = decoded.replaceAll('\\', '/').split('/').last.trim();
  return normalized.isEmpty ? '课堂图片' : normalized;
}

/// 笔记正文内的原生图片卡片：支持宽度限制、离线/缺失降级重试与点击全屏缩放。
class NoteImageView extends StatefulWidget {
  final String src;
  final String alt;
  final double? preferredWidth;
  final double maxWidth;
  final NoteImageLoader? loader;

  const NoteImageView({
    super.key,
    required this.src,
    this.alt = '',
    this.preferredWidth,
    required this.maxWidth,
    this.loader,
  });

  @override
  State<NoteImageView> createState() => _NoteImageViewState();
}

class _NoteImageViewState extends State<NoteImageView> {
  Future<Uint8List?>? _future;
  bool _decodeFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NoteImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src || oldWidget.loader != widget.loader) {
      _load();
    }
  }

  void _load() {
    _decodeFailed = false;
    final loader = widget.loader;
    _future = loader == null ? Future<Uint8List?>.value(null) : loader(widget.src);
  }

  void _retry() {
    setState(_load);
  }

  void _markDecodeFailed() {
    if (_decodeFailed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_decodeFailed) {
        setState(() => _decodeFailed = true);
      }
    });
  }

  void _openLightbox(Uint8List bytes) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final title = widget.alt.isNotEmpty ? widget.alt : _displayImageName(widget.src);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
        reverseTransitionDuration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 160),
        pageBuilder: (_, __, ___) => NoteImageLightbox(
          bytes: bytes,
          title: title,
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final targetWidth = widget.preferredWidth != null
        ? math.min(widget.preferredWidth!, widget.maxWidth)
        : widget.maxWidth;
    final cardFallbackWidth = math.min(
      widget.maxWidth,
      math.max(targetWidth, math.min(260.0, widget.maxWidth)),
    );
    final borderColor = highContrast ? colors.onSurface : colors.outlineVariant;
    final borderWidth = highContrast ? 1.5 : 1.0;
    final mutedTextColor =
        highContrast ? colors.onSurface : colors.onSurfaceVariant;
    final displayName = _displayImageName(widget.src);
    final caption = widget.alt.isNotEmpty ? widget.alt : null;

    Widget buildFallbackCard(String message) {
      return Container(
        key: ValueKey('note-image-fallback:${widget.src}'),
        width: cardFallbackWidth,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: StudyShapes.cardBorder,
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: mutedTextColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: mutedTextColor),
            ),
            if (widget.loader != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _retry,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 36),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.padded,
                  side: BorderSide(color: borderColor, width: borderWidth),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: FutureBuilder<Uint8List?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                width: cardFallbackWidth,
                height: 140,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: StudyShapes.cardBorder,
                  border: Border.all(color: borderColor, width: borderWidth),
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '正在加载图片 · $displayName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: mutedTextColor),
                      ),
                    ),
                  ],
                ),
              );
            }

            final bytes = snapshot.data;
            if (_decodeFailed) {
              return buildFallbackCard('图片格式无法解码，请确认附件未损坏后重试。');
            }
            if (snapshot.hasError || bytes == null || bytes.isEmpty) {
              return buildFallbackCard(
                widget.loader == null
                    ? '当前离线或未配置图片读取，请联网或同步图片目录后查看。'
                    : '未能读取图片，请先同步手机笔记目录或连接电脑后重试。',
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  image: true,
                  button: true,
                  excludeSemantics: true,
                  label: '$displayName，点击放大查看',
                  child: Tooltip(
                    message: '点击放大查看图片',
                    child: Material(
                      color: colors.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: StudyShapes.cardBorder,
                        side: BorderSide(color: borderColor, width: borderWidth),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey('note-image-card:${widget.src}'),
                        onTap: () => _openLightbox(bytes),
                        child: Stack(
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: targetWidth,
                                maxHeight: 460,
                              ),
                              child: Image.memory(
                                bytes,
                                width: widget.preferredWidth != null
                                    ? targetWidth
                                    : null,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, __, ___) {
                                  _markDecodeFailed();
                                  return const SizedBox(
                                      width: 120, height: 80);
                                },
                              ),
                            ),
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.55),
                                    borderRadius:
                                        BorderRadius.circular(StudyShapes.small),
                                  ),
                                  child: const Icon(
                                    Icons.zoom_in_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    caption,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: mutedTextColor,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 全屏深色遮罩图片预览器，支持双指缩放、平移与双击复位。
class NoteImageLightbox extends StatefulWidget {
  final Uint8List bytes;
  final String title;

  const NoteImageLightbox({
    super.key,
    required this.bytes,
    required this.title,
  });

  @override
  State<NoteImageLightbox> createState() => _NoteImageLightboxState();
}

class _NoteImageLightboxState extends State<NoteImageLightbox> {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _lastTap;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transform.value = Matrix4.identity();
  }

  void _handleDoubleTap() {
    final currentScale = _transform.value.getMaxScaleOnAxis();
    if (currentScale > 1.05 || currentScale < 0.95) {
      _resetZoom();
      return;
    }
    final pos = _lastTap?.localPosition ?? Offset.zero;
    const targetScale = 2.2;
    _transform.value = Matrix4.identity()
      ..translate(-pos.dx * (targetScale - 1), -pos.dy * (targetScale - 1))
      ..scale(targetScale);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black.withOpacity(0.94),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            title: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            leading: IconButton(
              key: const Key('note-image-lightbox-close'),
              tooltip: '关闭大图',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
            actions: [
              IconButton(
                key: const Key('note-image-lightbox-reset'),
                tooltip: '还原缩放',
                onPressed: _resetZoom,
                icon: const Icon(Icons.center_focus_strong_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: GestureDetector(
              onDoubleTapDown: (details) => _lastTap = details,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                key: const Key('note-image-lightbox-viewer'),
                transformationController: _transform,
                minScale: 0.8,
                maxScale: 5.0,
                boundaryMargin: const EdgeInsets.all(80),
                child: Center(
                  child: Image.memory(
                    widget.bytes,
                    fit: BoxFit.contain,
                    semanticLabel: widget.title,
                    errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.broken_image_outlined,
                            size: 42,
                            color: Colors.white70,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '无法预览该图片：${widget.title}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
