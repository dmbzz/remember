import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_navigation.dart';

/// Keep ink on the selection contour without changing the button's hit target.
/// InkHighlight retains this callback while a pointer hovers or stays pressed,
/// so read the current geometry at paint time instead of capturing a pose.
class _LensInkWell extends InkWell {
  const _LensInkWell({
    super.key,
    required this.lensSize,
    required super.child,
    required super.onTap,
    super.focusNode,
    super.onFocusChange,
    super.customBorder,
    super.splashFactory,
    super.overlayColor,
  });

  final ValueGetter<Size> lensSize;

  @override
  RectCallback getRectCallback(RenderBox referenceBox) => () {
        final size = lensSize();
        return Rect.fromCenter(
            center: referenceBox.size.center(Offset.zero),
            width: size.width,
            height: size.height);
      };
}

/// Local clearance for form/list pages under the floating desktop Dock.
/// Uses its fully expanded envelope: hovering never moves a field or button.
/// This reserves no shell layer and is intentionally not used by the timetable.
class StudyDockContentInset extends InheritedWidget {
  const StudyDockContentInset(
      {super.key, required this.leading, required super.child});
  final double leading;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<StudyDockContentInset>()
          ?.leading ??
      0;

  @override
  bool updateShouldNotify(StudyDockContentInset oldWidget) =>
      leading != oldWidget.leading;
}

/// Content may protect its time labels without reserving a page-wide rail.
/// This envelope always uses the collapsed width, so hover never moves content.
class StudyFloatingTimeInset extends InheritedWidget {
  const StudyFloatingTimeInset(
      {super.key,
      required this.leading,
      this.layoutLeading,
      required super.child});
  final double leading;
  // Paragraphs use the destination envelope, not every animated pose of the
  // Dock. Geometry continues to follow the actual leading value.
  final double? layoutLeading;
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<StudyFloatingTimeInset>()
          ?.leading ??
      0;
  static double layoutOf(BuildContext context) {
    final inset =
        context.dependOnInheritedWidgetOfExactType<StudyFloatingTimeInset>();
    return inset?.layoutLeading ?? inset?.leading ?? 0;
  }

  @override
  bool updateShouldNotify(StudyFloatingTimeInset oldWidget) =>
      leading != oldWidget.leading || layoutLeading != oldWidget.layoutLeading;
}

/// The chosen “弧线回港”: one surface, one set of upright labels, in both layouts.
class ArcCapsuleGeometry {
  ArcCapsuleGeometry(
      {required this.shell,
      required this.canvas,
      required this.centers,
      required this.itemSize,
      required this.lensSize,
      required this.iconOffset,
      required this.labelOffset,
      required this.radius,
      required this.contentLeft,
      required this.contentBottom});

  final Rect shell;
  final Size canvas, itemSize, lensSize;
  final List<Offset> centers;
  final Offset iconOffset, labelOffset;
  final double radius, contentLeft, contentBottom;
  bool get scrolls =>
      canvas.width > shell.width + .1 || canvas.height > shell.height + .1;

  static double _mix(double a, double b, double t) => lerpDouble(a, b, t)!;
  static double _smooth(double p) {
    p = p.clamp(0.0, 1.0);
    return p * p * (3 - 2 * p);
  }

  static double _part(double p, double a, double b) =>
      _smooth((p - a) / (b - a));

  static ArcCapsuleGeometry calculate(
      {required Size viewport,
      required EdgeInsets safe,
      required double progress,
      required Size label,
      required int count,
      bool desktop = false,
      double railExpansion = 1}) {
    final p = progress.clamp(0.0, 1.0);
    final safeWidth = math.max(48.0, viewport.width - safe.horizontal - 16);
    final safeHeight = math.max(48.0, viewport.height - safe.vertical - 24);
    final itemW = math.max(48.0, label.width);
    final itemH = math.max(desktop ? 56.0 : 48.0, 24 + 4 + label.height);
    // Preserve the portrait span after metrics rotate, avoiding a long detour.
    final rowWidth = math.min(
            safeWidth,
            math.max(
                320.0,
                math.min(viewport.width, viewport.height) -
                    safe.horizontal -
                    16)) -
        12;
    final rowStep = math.max(rowWidth / count, itemW + 8);
    final endStep = itemH + 12;
    final closedRail = itemH + 24;
    final openRail = math.max(
        136.0, desktop ? closedRail + label.width + 12 : label.width + 76);
    final rail = desktop ? _mix(closedRail, openRail, railExpansion) : openRail;
    final turn = _part(p, .04, .96);
    final angle = math.atan2(turn, 1 - turn);
    final cos = math.cos(angle), sin = math.sin(angle);
    // At least one axis separates adjacent hit targets throughout reordering.
    final spacing = math.max(
        math.min((itemW + 8) / math.max(cos, .0001),
            (itemH + 8) / math.max(sin, .0001)),
        _mix(rowStep, endStep, turn));
    final wide = _part(p, .86, 1);
    final glyphW = _mix(itemW, rail - 24, wide);
    final lensH = itemH + 8;
    final lensW = math.max(
        lensH, _mix(math.max(rowStep - 8, lensH), rail - 12, _part(p, .72, 1)));
    final group = List.generate(
        count,
        (i) => Offset((i - (count - 1) / 2) * spacing * cos,
            (i - (count - 1) / 2) * spacing * sin));
    final extentW = group.last.dx - group.first.dx + math.max(glyphW, lensW);
    final extentH = group.last.dy - group.first.dy + lensH;
    final canvasW = math.max(_mix(rowWidth, rail, p), extentW + 16);
    final canvasH = math.max(
        _mix(itemH + 24, (count - 1) * endStep + itemH + 24, p), extentH + 16);
    final width = math.min(canvasW, safeWidth),
        height = math.min(canvasH, safeHeight);
    final start = Offset(viewport.width / 2,
        viewport.height - safe.bottom - 12 - (itemH + 24) / 2);
    final end = Offset(safe.left + 12 + rail / 2,
        safe.top + (viewport.height - safe.vertical) / 2);
    var center = Offset.lerp(start, end, p)! -
        Offset(30 * math.sin(math.pi * p), 18 * math.sin(math.pi * p));
    center = Offset(
        center.dx.clamp(safe.left + 8 + width / 2,
            viewport.width - safe.right - 8 - width / 2),
        center.dy.clamp(safe.top + 12 + height / 2,
            viewport.height - safe.bottom - 12 - height / 2));
    final iconOffset = Offset(
        _mix(0, -rail / 2 + (desktop ? closedRail / 2 : 28), wide),
        _mix(-itemH / 2 + 12, 0, wide));
    final labelOffset = Offset(
        (desktop
                ? -rail / 2 +
                    closedRail -
                    12 +
                    label.width / 2 -
                    8 * (1 - railExpansion)
                : 16) *
            wide,
        (itemH / 2 - label.height / 2) * (1 - wide));
    var radius = math.min(_mix((itemH + 24) / 2, desktop ? 28 : 36, p),
        math.min(width, height) / 2);
    // All possible selected lenses participate in the envelope; selection never
    // resizes/moves the whole surface. Use the true rounded contour, not a clip fix.
    if (canvasW <= width + .1 && canvasH <= height + .1) {
      bool fits(double r) {
        final shape = RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: width, height: height),
            Radius.circular(r));
        for (final c in group) {
          for (final rect in [
            Rect.fromCenter(center: c + iconOffset, width: 24, height: 24),
            if (!desktop || railExpansion >= .999 || wide < .01)
              Rect.fromCenter(
                  center: c + labelOffset,
                  width: label.width,
                  height: label.height)
          ]) {
            for (final point in [
              rect.topLeft,
              rect.topRight,
              rect.bottomLeft,
              rect.bottomRight
            ]) {
              if (!shape.contains(point)) return false;
            }
          }
          final r2 = lensH / 2;
          for (var corner = 0; corner < 4; corner++) {
            final signX = corner < 2 ? 1.0 : -1.0,
                signY = (corner == 0 || corner == 3) ? -1.0 : 1.0;
            final origin =
                c + Offset(signX * (lensW / 2 - r2), signY * (lensH / 2 - r2));
            for (var j = 0; j <= 8; j++) {
              final a = (-90 + corner * 90 + j * 90 / 8) * math.pi / 180;
              if (!shape.contains(
                  origin + Offset(r2 * math.cos(a), r2 * math.sin(a)))) {
                return false;
              }
            }
          }
        }
        return true;
      }

      if (!fits(radius)) {
        var lo = 0.0, hi = radius;
        for (var n = 0; n < 18; n++) {
          final mid = (lo + hi) / 2;
          if (fits(mid)) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        radius = lo;
      }
    }
    return ArcCapsuleGeometry(
        shell: Rect.fromCenter(center: center, width: width, height: height),
        canvas: Size(canvasW, canvasH),
        centers:
            group.map((v) => v + Offset(canvasW / 2, canvasH / 2)).toList(),
        itemSize: Size(glyphW, itemH),
        lensSize: Size(lensW, lensH),
        iconOffset: iconOffset,
        labelOffset: labelOffset,
        radius: radius,
        // Windows content paints below the floating Dock over the whole window.
        // Reserving the open width here made even the transparent exterior an
        // empty band. Hover changes only the surface, never the content layout.
        contentLeft: desktop ? 0 : _mix(0, rail + 24, p),
        contentBottom: _mix(itemH + safe.bottom + 44, 0, p));
  }
}

/// Retarget from the current position AND velocity. Reversing never restarts
/// the animation or swaps a portrait bar for a different landscape tree.
class CapsuleOrientationSimulation extends Simulation {
  CapsuleOrientationSimulation(this.from, this.to, this.initialVelocity)
      : seconds = math.max(.08, .44 * (to - from).abs());
  final double from, to, initialVelocity, seconds;
  @override
  double x(double time) {
    final t = (time / seconds).clamp(0.0, 1.0), t2 = t * t, t3 = t2 * t;
    return ((2 * t3 - 3 * t2 + 1) * from +
            (t3 - 2 * t2 + t) * seconds * initialVelocity +
            (-2 * t3 + 3 * t2) * to)
        .clamp(0.0, 1.0);
  }

  @override
  double dx(double time) {
    if (time >= seconds) return 0;
    final t = (time / seconds).clamp(0.0, 1.0), t2 = t * t;
    return ((6 * t2 - 6 * t) * from +
            (3 * t2 - 4 * t + 1) * seconds * initialVelocity +
            (-6 * t2 + 6 * t) * to) /
        seconds;
  }

  @override
  bool isDone(double time) => time >= seconds;
}

class StudyTouchNavigationLayout extends StatefulWidget {
  const StudyTouchNavigationLayout(
      {super.key,
      required this.content,
      required this.destinations,
      required this.selectedIndex,
      required this.onSelected,
      this.desktopNavigation = false});
  final Widget content;
  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool desktopNavigation;
  @override
  State<StudyTouchNavigationLayout> createState() =>
      _StudyTouchNavigationLayoutState();
}

class _StudyTouchNavigationLayoutState extends State<StudyTouchNavigationLayout>
    with TickerProviderStateMixin {
  late final _orientation = AnimationController.unbounded(vsync: this);
  late final _selection = AnimationController.unbounded(
      vsync: this, value: widget.selectedIndex.toDouble());
  late final _expansion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180));
  late final _focusNodes = List.generate(widget.destinations.length,
      (i) => FocusNode(debugLabel: 'Navigation ${widget.destinations[i].$3}'));
  Timer? _hoverDelay;
  bool _hovered = false,
      _keyboardFocus = false,
      _keyboardInput = false,
      _reduce = false;
  bool? _landscape;
  late final _itemKeys =
      List.generate(widget.destinations.length, (_) => GlobalKey());
  bool _revealScheduled = false;
  Size _inkLensSize = Size.zero;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keyboardEvent);
  }

  bool _keyboardEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      _keyboardInput = true;
      if (widget.desktopNavigation && _focusNodes.any((n) => n.hasFocus)) {
        _keyboardFocus = true;
        _expand(true);
      }
    }
    return false;
  }

  void _expand(bool open, {bool delay = false}) {
    _hoverDelay?.cancel();
    void apply() {
      if (!mounted) return;
      if (_reduce) {
        _expansion.value = open ? 1 : 0;
      } else if (open) {
        _expansion.forward();
      } else {
        _expansion.reverse();
      }
    }

    if (delay && !_reduce) {
      _hoverDelay = Timer(Duration(milliseconds: open ? 70 : 160), apply);
    } else {
      apply();
    }
  }

  void _hover(bool enter) {
    _hovered = enter;
    if (!widget.desktopNavigation) return;
    _expand(enter || _keyboardFocus, delay: true);
  }

  void _focusChanged(bool focused) {
    if (!focused) {
      _keyboardFocus = false;
    } else if (_keyboardInput) {
      _keyboardFocus = true;
    }
    if (widget.desktopNavigation) {
      _expand(_hovered || _keyboardFocus, delay: !focused);
    }
  }

  KeyEventResult _navigate(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final current = _focusNodes.indexWhere((n) => n.hasFocus),
        key = event.logicalKey;
    int? next;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      next = (current + 1) % _focusNodes.length;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      next = (current - 1 + _focusNodes.length) % _focusNodes.length;
    }
    if (key == LogicalKeyboardKey.home) next = 0;
    if (key == LogicalKeyboardKey.end) next = _focusNodes.length - 1;
    if (next == null) return KeyEventResult.ignored;
    _focusNodes[next].requestFocus();
    return KeyEventResult.handled;
  }

  void _revealFocused(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNodes[index].hasFocus) return;
      final c = _itemKeys[index].currentContext;
      if (c != null) {
        Scrollable.ensureVisible(c, alignment: .5, duration: Duration.zero);
      }
    });
  }

  void _revealSelectedAfterLayout() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || _orientation.isAnimating) return;
      final focusedIndex =
          _keyboardInput ? _focusNodes.indexWhere((n) => n.hasFocus) : -1;
      final itemContext =
          _itemKeys[focusedIndex >= 0 ? focusedIndex : widget.selectedIndex]
              .currentContext;
      if (itemContext != null) {
        // Keep the existing task visible on entry to a scrolling short rail.
        // This changes neither focus nor the ordinary non-scrolling path.
        Scrollable.ensureVisible(itemContext,
            alignment: .5, duration: Duration.zero);
      }
    });
  }

  void _retarget(bool landscape, bool reduce) {
    final target = landscape ? 1.0 : 0.0;
    if (_landscape == null || reduce) {
      _orientation.stop();
      _orientation.value = target;
    } else if (landscape != _landscape) {
      final velocity = _orientation.velocity;
      _orientation.animateWith(
          CapsuleOrientationSimulation(_orientation.value, target, velocity));
    }
    _landscape = landscape;
  }

  @override
  void didUpdateWidget(StudyTouchNavigationLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _selection.value = widget.selectedIndex.toDouble();
      } else {
        _selection.animateTo(widget.selectedIndex.toDouble(),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic);
      }
    }
  }

  @override
  void dispose() {
    _hoverDelay?.cancel();
    HardwareKeyboard.instance.removeHandler(_keyboardEvent);
    for (final node in _focusNodes) {
      node.dispose();
    }
    _expansion.dispose();
    _orientation.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context), theme = Theme.of(context);
    final reduceChanged = _reduce != media.disableAnimations;
    _reduce = media.disableAnimations;
    if (_reduce) {
      _hoverDelay?.cancel();
    }
    if (_reduce && (_expansion.isAnimating || reduceChanged)) {
      _expansion.stop();
      _expansion.value = _hovered || _keyboardFocus ? 1 : 0;
    }
    if (media.disableAnimations &&
        (_selection.isAnimating || _selection.value != widget.selectedIndex)) {
      _selection.stop();
      _selection.value = widget.selectedIndex.toDouble();
    }
    final labelStyle = TextStyle(
        inherit: false,
        fontSize: widget.desktopNavigation ? 15 : 12,
        fontWeight: FontWeight.w500,
        height: 1.4,
        letterSpacing: 0,
        fontFamilyFallback: theme.textTheme.bodyMedium?.fontFamilyFallback,
        fontFamily: theme.textTheme.bodyMedium?.fontFamily);
    var labelSize = Size.zero;
    for (final d in widget.destinations) {
      final painter = TextPainter(
          text: TextSpan(text: d.$3, style: labelStyle),
          textDirection: Directionality.of(context),
          textScaler: media.textScaler)
        ..layout();
      labelSize = Size(
          math.max(labelSize.width, painter.width.ceilToDouble() + 2),
          math.max(labelSize.height, painter.height.ceilToDouble() + 1));
    }
    return Scaffold(body: LayoutBuilder(builder: (context, constraints) {
      final landscape = widget.desktopNavigation
          ? constraints.maxWidth >= 900
          : constraints.maxWidth >= 600 && media.size.width > media.size.height;
      final floatingTimeInset = widget.desktopNavigation
          ? media.padding.left +
              12 +
              math.max(56.0, 28 + labelSize.height) +
              24 +
              12
          : 0.0;
      _retarget(landscape, media.disableAnimations);
      return AnimatedBuilder(
          animation: Listenable.merge([_orientation, _selection, _expansion]),
          builder: (context, child) {
            final g = ArcCapsuleGeometry.calculate(
                viewport: constraints.biggest,
                safe: media.padding,
                progress: _orientation.value,
                label: labelSize,
                count: widget.destinations.length,
                desktop: widget.desktopNavigation,
                railExpansion: Curves.easeOutCubic.transform(_expansion.value));
            _inkLensSize = g.lensSize;
            final formLeading = widget.desktopNavigation
                ? (ArcCapsuleGeometry.calculate(
                                viewport: constraints.biggest,
                                safe: media.padding,
                                progress: 1,
                                label: labelSize,
                                count: widget.destinations.length,
                                desktop: true,
                                railExpansion: 1)
                            .shell
                            .right +
                        12) *
                    _orientation.value
                : 0.0;
            if (g.scrolls) _revealSelectedAfterLayout();
            final index =
                _selection.value.clamp(0.0, (g.centers.length - 1).toDouble());
            final lower = index.floor(), upper = index.ceil();
            final lensCenter =
                Offset.lerp(g.centers[lower], g.centers[upper], index - lower)!;
            return Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                  child: Row(children: [
                SizedBox(
                    key: const ValueKey('navigation-side-slot'),
                    width: g.contentLeft),
                Expanded(
                    child: MediaQuery(
                        data: media.copyWith(
                            padding: media.padding.copyWith(
                                bottom: math.max(
                                    media.padding.bottom, g.contentBottom))),
                        child: StudyFloatingTimeInset(
                            leading: floatingTimeInset *
                                _orientation.value.clamp(0.0, 1.0),
                            layoutLeading: landscape ? floatingTimeInset : 0,
                            child: StudyDockContentInset(
                                leading: formLeading, child: child!)))),
              ])),
              Positioned.fromRect(
                  rect: g.shell,
                  child: MouseRegion(
                      opaque: false,
                      hitTestBehavior: HitTestBehavior.deferToChild,
                      onEnter: (_) => _hover(true),
                      onExit: (_) => _hover(false),
                      child: Listener(
                          onPointerDown: (_) {
                            _keyboardInput = false;
                            _keyboardFocus = false;
                            if (widget.desktopNavigation && !_hovered) {
                              _expand(false, delay: true);
                            }
                          },
                          child: FocusScope(
                              onFocusChange: _focusChanged,
                              onKeyEvent: _navigate,
                              child: GlassNavigationSurface(
                                key:
                                    const ValueKey('touch-orientation-capsule'),
                                radius: g.radius,
                                child: ScrollConfiguration(
                                    // A floating navigation surface isn't a page
                                    // pane: desktop-injected scrollbars produced
                                    // an extra rail beside its rounded outline.
                                    // Keep wheel, touch and keyboard scrolling.
                                    behavior: ScrollConfiguration.of(context)
                                        .copyWith(scrollbars: false),
                                    child: GestureDetector(
                                        excludeFromSemantics: true,
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {},
                                        child: SingleChildScrollView(
                                          key: const ValueKey(
                                              'capsule-vertical-scroll'),
                                          primary: false,
                                          child: SingleChildScrollView(
                                            key: const ValueKey(
                                                'capsule-horizontal-scroll'),
                                            primary: false,
                                            scrollDirection: Axis.horizontal,
                                            child: SizedBox(
                                                width: g.canvas.width,
                                                height: g.canvas.height,
                                                child: Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      Positioned.fromRect(
                                                          rect: Rect.fromCenter(
                                                              center:
                                                                  lensCenter,
                                                              width: g.lensSize
                                                                  .width,
                                                              height: g.lensSize
                                                                  .height),
                                                          child: IgnorePointer(
                                                              child: DecoratedBox(
                                                                  key: const ValueKey(
                                                                      'navigation-lens'),
                                                                  decoration: ShapeDecoration(
                                                                      shape: StadiumBorder(
                                                                          side:
                                                                              BorderSide(color: theme.colorScheme.primary.withOpacity(.23))),
                                                                      color: MediaQuery.highContrastOf(context) ? theme.colorScheme.primaryContainer : theme.colorScheme.primary.withOpacity(.12))))),
                                                      // A shared ink canvas can paint the full lens;
                                                      // per-item Materials clip ink to the smaller hit box.
                                                      Positioned.fill(
                                                        child: Material(
                                                          key: const ValueKey(
                                                              'navigation-ink-canvas'),
                                                          color: Colors
                                                              .transparent,
                                                          child: Stack(
                                                            clipBehavior:
                                                                Clip.none,
                                                            children: [
                                                              for (var i = 0;
                                                                  i <
                                                                      widget
                                                                          .destinations
                                                                          .length;
                                                                  i++)
                                                                Positioned.fromRect(
                                                                    rect: Rect.fromCenter(center: g.centers[i], width: g.itemSize.width, height: g.itemSize.height),
                                                                    child: Semantics(
                                                                        onTap: () => widget.onSelected(i),
                                                                        button: true,
                                                                        selected: i == widget.selectedIndex,
                                                                        label: widget.destinations[i].$3,
                                                                        excludeSemantics: true,
                                                                        child: SizedBox(
                                                                          key: ValueKey(
                                                                              'capsule-item-$i'),
                                                                          child: _LensInkWell(
                                                                              lensSize: () => _inkLensSize,
                                                                              key: _itemKeys[i],
                                                                              focusNode: _focusNodes[i],
                                                                              onFocusChange: (focused) {
                                                                                if (focused && _keyboardInput) {
                                                                                  _revealFocused(i);
                                                                                }
                                                                              },
                                                                              onTap: () => widget.onSelected(i),
                                                                              customBorder: const StadiumBorder(),
                                                                              splashFactory: NoSplash.splashFactory,
                                                                              overlayColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.pressed) || states.contains(WidgetState.focused) ? theme.colorScheme.primary.withOpacity(.12) : null),
                                                                              child: Stack(clipBehavior: Clip.none, children: [
                                                                                Positioned(left: g.itemSize.width / 2 + g.iconOffset.dx - 12, top: g.itemSize.height / 2 + g.iconOffset.dy - 12, width: 24, height: 24, child: Icon(i == widget.selectedIndex ? widget.destinations[i].$2 : widget.destinations[i].$1, size: 23, color: i == widget.selectedIndex ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant)),
                                                                                Positioned(left: g.itemSize.width / 2 + g.labelOffset.dx - labelSize.width / 2, top: g.itemSize.height / 2 + g.labelOffset.dy - labelSize.height / 2, width: labelSize.width, height: labelSize.height, child: Opacity(opacity: widget.desktopNavigation ? 1 - ArcCapsuleGeometry._part(_orientation.value, .86, 1) * (1 - Curves.easeOutCubic.transform(_expansion.value)) : 1, child: Text(widget.destinations[i].$3, textAlign: TextAlign.center, maxLines: 1, softWrap: false, style: labelStyle.copyWith(color: i == widget.selectedIndex ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant)))),
                                                                              ])),
                                                                        ))),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ])),
                                          ),
                                        ))),
                              ))))),
            ]);
          },
          child: widget.content);
    }));
  }
}
