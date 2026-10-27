import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'shapes.dart';

typedef NoteOpeningRectProvider = Rect? Function();

int noteOpeningTitleLines(
    double availableHeight, TextStyle style, TextScaler scaler) {
  final compact = availableHeight < 230;
  final lineHeight =
      scaler.scale(style.fontSize ?? 20) * (style.height ?? 1.45);
  final budget = (availableHeight * .45).clamp(0.0, 260.0);
  return ((budget - (compact ? 28 : 94)) / lineHeight).floor().clamp(1, 3);
}

/// A card opens into the reader, keeping a single title in the route overlay.
/// The reader reserves its title space with [NoteOpeningTitleAnchor].
class NoteOpeningRoute<T> extends PageRoute<T> {
  NoteOpeningRoute({
    required BuildContext sourceContext,
    required this.noteId,
    required this.title,
    required this.builder,
    required this.sourceCardRect,
    required this.sourceTitleRect,
    required TextStyle sourceTitleStyle,
    required this.sourceTitleHidden,
    this.sourceRadius = StudyShapes.card,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
  })  : sourceTitleStyle = DefaultTextStyle.of(sourceContext)
            .style
            .merge(sourceTitleStyle)
            .copyWith(inherit: false),
        _reduceMotion = MediaQuery.disableAnimationsOf(sourceContext),
        _initialViewRect = _navigatorRect(sourceContext) {
    _captureSource();
  }

  final String noteId;
  final String title;
  final WidgetBuilder builder;
  final NoteOpeningRectProvider sourceCardRect;
  final NoteOpeningRectProvider sourceTitleRect;
  final TextStyle sourceTitleStyle;
  final ValueNotifier<bool> sourceTitleHidden;
  final double sourceRadius;
  final int? maxLines;
  final TextOverflow overflow;
  final bool _reduceMotion;
  final Rect _initialViewRect;
  final GlobalKey _viewportKey = GlobalKey();
  final ValueNotifier<int> _anchorRevision = ValueNotifier(0);
  Rect? _cardOrigin;
  Rect? _titleOrigin;
  _NoteTitleAnchorRenderBox? _anchor;
  TextStyle? _destinationStyle;
  int? _destinationMaxLines;
  TextOverflow? _destinationOverflow;
  Rect? _reportedAnchorRect;
  TextStyle? _reportedAnchorStyle;
  int? _reportedAnchorMaxLines;
  TextOverflow? _reportedAnchorOverflow;
  bool _anchorReportPending = false;
  bool _instantReturn = false;
  Offset _pageOffset = Offset.zero;

  double _titleLayoutWidth(double available) =>
      (_titleOrigin?.width ?? available).clamp(0.0, available).toDouble();

  static double _progress(double value) {
    final t = value.clamp(0.0, 1.0);
    final eased = t * t * t * (t * (t * 6 - 15) + 10);
    // The selected continuous card spread; no overshoot or separate end pose.
    return 1 - math.pow(1 - eased, 1.2).toDouble();
  }

  double get _chromeOpacity {
    if (_reduceMotion || !_hasOrigin || _instantReturn) return 1;
    final target = _destinationRect;
    if (target == null) return 0;
    final p = _progress(animation?.value ?? 0);
    final sourceLocal = _titleOrigin!.top - _cardOrigin!.top;
    final targetLocal = target.top - _viewRect.top - StudyShapes.readerInset;
    final titleLocal = sourceLocal + (targetLocal - sourceLocal) * p;
    return Curves.easeInOut
        .transform(((titleLocal - targetLocal + 24) / 24).clamp(0.0, 1.0));
  }

  static Rect _navigatorRect(BuildContext context) {
    final render = Navigator.of(context).overlay?.context.findRenderObject();
    if (render is RenderBox && render.hasSize) {
      return render.localToGlobal(Offset.zero) & render.size;
    }
    return Offset.zero & MediaQuery.sizeOf(context);
  }

  Rect get _viewRect {
    final render = _viewportKey.currentContext?.findRenderObject();
    if (render is RenderBox && render.hasSize) {
      return render.localToGlobal(Offset.zero) & render.size;
    }
    return _initialViewRect;
  }

  bool get _hasOrigin => _cardOrigin != null && _titleOrigin != null;

  void _captureSource() {
    final card = sourceCardRect();
    final heading = sourceTitleRect();
    final view = _viewRect;
    // Never use an obsolete position when the originating card disappeared.
    if (card == null ||
        heading == null ||
        card.isEmpty ||
        heading.isEmpty ||
        !card.overlaps(view) ||
        !heading.overlaps(view)) {
      _cardOrigin = null;
      _titleOrigin = null;
      return;
    }
    _cardOrigin = card;
    _titleOrigin = heading;
  }

  @override
  Duration get transitionDuration => _reduceMotion || !_hasOrigin
      ? Duration.zero
      : const Duration(milliseconds: 520);

  @override
  Duration get reverseTransitionDuration => _reduceMotion || _instantReturn
      ? Duration.zero
      : const Duration(milliseconds: 420);

  @override
  bool get opaque => false;
  @override
  bool get barrierDismissible => false;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;

  @override
  bool didPop(T? result) {
    // The list can resize while reading. Return to the same note's position now.
    _captureSource();
    _instantReturn = !_hasOrigin;
    controller?.reverseDuration = reverseTransitionDuration;
    return super.didPop(result);
  }

  @override
  void dispose() {
    sourceTitleHidden.value = false;
    _anchorRevision.dispose();
    super.dispose();
  }

  void _registerAnchor(_NoteTitleAnchorRenderBox render, TextStyle style,
      int? maxLines, TextOverflow overflow) {
    _anchor = render;
    _destinationStyle = style;
    _destinationMaxLines = maxLines;
    _destinationOverflow = overflow;
    if (_anchorReportPending) return;
    _anchorReportPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorReportPending = false;
      if (isActive) {
        // The first route layout is offstage. Keep the list title visible until
        // its replacement has a measured destination and can actually paint.
        sourceTitleHidden.value = true;
        final actualRect = _destinationRect;
        if (_reportedAnchorRect != actualRect ||
            _reportedAnchorStyle != _destinationStyle ||
            _reportedAnchorMaxLines != _destinationMaxLines ||
            _reportedAnchorOverflow != _destinationOverflow) {
          _reportedAnchorRect = actualRect;
          _reportedAnchorStyle = _destinationStyle;
          _reportedAnchorMaxLines = _destinationMaxLines;
          _reportedAnchorOverflow = _destinationOverflow;
          _anchorRevision.value++;
        }
      }
    });
  }

  Rect? get _destinationRect {
    final anchor = _anchor;
    if (anchor == null || !anchor.attached || !anchor.hasSize) return null;
    return (anchor.localToGlobal(Offset.zero) -
            _pageOffset +
            const Offset(StudyShapes.readerInset, StudyShapes.readerInset)) &
        anchor.size;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return LayoutBuilder(
        builder: (context, constraints) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: math.max(
                    0, constraints.maxWidth - StudyShapes.readerInset * 2),
                height: math.max(
                    0, constraints.maxHeight - StudyShapes.readerInset * 2),
                child: _NoteOpeningScope(
                  route: this,
                  child: Semantics(
                      scopesRoute: true,
                      explicitChildNodes: true,
                      child: builder(context)),
                ),
              ),
            ));
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return AnimatedBuilder(
      animation: Listenable.merge([animation, _anchorRevision]),
      // The long reader is constructed outside the per-frame geometry builder.
      child: RepaintBoundary(child: child),
      builder: (context, page) {
        final view = _viewRect;
        final targetTitle = _destinationRect;
        final progress = _reduceMotion || !_hasOrigin || _instantReturn
            ? 1.0
            : _progress(animation.value);
        final target = view.deflate(StudyShapes.readerInset);
        final card = Rect.lerp(_cardOrigin ?? target, target, progress)!;
        final clip = card.shift(-view.topLeft);
        final radius =
            sourceRadius + (StudyShapes.reader - sourceRadius) * progress;
        final destination = targetTitle ?? _titleOrigin;
        final titleRect = destination == null
            ? null
            : Rect.lerp(_titleOrigin ?? destination, destination, progress)!;
        final style = _destinationStyle ?? sourceTitleStyle;
        _pageOffset = clip.topLeft;
        final pageOpacity = _reduceMotion || !_hasOrigin || _instantReturn
            ? 1.0
            : Curves.easeInOut
                .transform(((animation.value - .10) / .60).clamp(0.0, 1.0));
        return SizedBox.expand(
          key: _viewportKey,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(
                color: Theme.of(context)
                    .scaffoldBackgroundColor
                    .withOpacity(progress)),
            PhysicalShape(
              key: ValueKey('note-opening-surface:$noteId'),
              color: Theme.of(context).colorScheme.surface,
              shadowColor: Theme.of(context).shadowColor,
              elevation: 4 * progress,
              clipBehavior: Clip.antiAlias,
              clipper: _NoteOpeningClipper(clip, radius),
              child: Stack(fit: StackFit.expand, children: [
                ColoredBox(color: Theme.of(context).colorScheme.surface),
                Transform.translate(
                    key: ValueKey('note-opening-page:$noteId'),
                    offset: _pageOffset,
                    child: Opacity(opacity: pageOpacity, child: page!)),
                if (titleRect != null)
                  Positioned(
                    left: titleRect.left - view.left,
                    top: titleRect.top - view.top,
                    width: destination!.width,
                    height: titleRect.height,
                    child: IgnorePointer(
                        child: ClipRect(
                            child: OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: destination.width,
                                maxWidth: destination.width,
                                minHeight: destination.height,
                                maxHeight: destination.height,
                                child: Text(
                                  title,
                                  key: ValueKey('note-opening-title:$noteId'),
                                  style: style,
                                  softWrap: true,
                                  maxLines: _anchor != null
                                      ? _destinationMaxLines
                                      : maxLines,
                                  overflow: _destinationOverflow ?? overflow,
                                )))),
                  ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _NoteOpeningClipper extends CustomClipper<Path> {
  const _NoteOpeningClipper(this.rect, this.radius);
  final Rect rect;
  final double radius;
  @override
  Path getClip(Size size) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
  @override
  bool shouldReclip(_NoteOpeningClipper oldClipper) =>
      rect != oldClipper.rect || radius != oldClipper.radius;
}

class _NoteOpeningScope extends InheritedWidget {
  const _NoteOpeningScope({required this.route, required super.child});
  final NoteOpeningRoute<dynamic> route;
  static NoteOpeningRoute<dynamic>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NoteOpeningScope>()?.route;
  @override
  bool updateShouldNotify(_NoteOpeningScope oldWidget) =>
      route != oldWidget.route;
}

/// Header chrome enters only after it has cleared the travelling title.
class NoteOpeningChrome extends StatelessWidget {
  const NoteOpeningChrome({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final route = _NoteOpeningScope.of(context);
    if (route == null || route.animation == null) return child;
    return AnimatedBuilder(
        animation: route.animation!,
        child: child,
        builder: (context, child) =>
            Opacity(opacity: route._chromeOpacity, child: child));
  }
}

/// Reserve the real heading's layout without painting a second title.
/// Put this in a fixed reader header, above loading/error and scrolling content.
/// Directly opened readers remain compatible and render their ordinary Text.
class NoteOpeningTitleAnchor extends StatelessWidget {
  const NoteOpeningTitleAnchor(
      {super.key,
      required this.noteId,
      required this.title,
      required this.style,
      this.maxLines,
      this.overflow = TextOverflow.ellipsis});
  final String noteId;
  final String title;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow overflow;
  @override
  Widget build(BuildContext context) {
    final route = _NoteOpeningScope.of(context);
    final resolvedStyle = DefaultTextStyle.of(context)
        .style
        .merge(style)
        .copyWith(inherit: false);
    if (route == null || route.noteId != noteId) {
      return Text(title,
          style: resolvedStyle, maxLines: maxLines, overflow: overflow);
    }
    return _NoteTitleAnchorBox(
        route: route,
        title: title,
        style: route.sourceTitleStyle,
        maxLines: maxLines,
        overflow: overflow,
        direction: Directionality.of(context),
        scaler: MediaQuery.textScalerOf(context));
  }
}

class _NoteTitleAnchorBox extends LeafRenderObjectWidget {
  const _NoteTitleAnchorBox(
      {required this.route,
      required this.title,
      required this.style,
      required this.maxLines,
      required this.overflow,
      required this.direction,
      required this.scaler});
  final NoteOpeningRoute<dynamic> route;
  final String title;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextDirection direction;
  final TextScaler scaler;
  @override
  _NoteTitleAnchorRenderBox createRenderObject(BuildContext context) =>
      _NoteTitleAnchorRenderBox(
          route, title, style, direction, scaler, maxLines, overflow);
  @override
  void updateRenderObject(
          BuildContext context, _NoteTitleAnchorRenderBox renderObject) =>
      renderObject.update(
          route, title, style, direction, scaler, maxLines, overflow);
}

class _NoteTitleAnchorRenderBox extends RenderBox {
  _NoteTitleAnchorRenderBox(
      this._route,
      String title,
      TextStyle style,
      TextDirection direction,
      TextScaler scaler,
      int? maxLines,
      TextOverflow overflow) {
    update(_route, title, style, direction, scaler, maxLines, overflow);
  }
  NoteOpeningRoute<dynamic> _route;
  final TextPainter _painter = TextPainter();
  TextStyle _style = const TextStyle();
  int? _maxLines;
  TextOverflow _overflow = TextOverflow.ellipsis;
  void update(
      NoteOpeningRoute<dynamic> route,
      String title,
      TextStyle style,
      TextDirection direction,
      TextScaler scaler,
      int? maxLines,
      TextOverflow overflow) {
    _route = route;
    _style = style;
    _maxLines = maxLines;
    _overflow = overflow;
    _painter
      ..text = TextSpan(text: title, style: style)
      ..textDirection = direction
      ..textScaler = scaler
      ..maxLines = maxLines
      ..ellipsis = overflow == TextOverflow.ellipsis ? '\u2026' : null;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final width = _route._titleLayoutWidth(constraints.maxWidth);
    _painter.layout(maxWidth: width);
    size = constraints.constrain(Size(
        constraints.hasBoundedWidth ? width : _painter.width, _painter.height));
    _route._registerAnchor(this, _style, _maxLines, _overflow);
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    _painter.layout(maxWidth: width);
    return _painter.height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }
}
