import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A fixed-position desktop dock. Its reserved width keeps pages still while
/// the labels follow the icons over the same short path in both directions.
class WindowsHoverDock extends StatefulWidget {
  const WindowsHoverDock({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static double reservedWidth(BuildContext context) =>
      96 + MediaQuery.textScalerOf(context).scale(15) * 4;

  @override
  State<WindowsHoverDock> createState() => _WindowsHoverDockState();
}

class _WindowsHoverDockState extends State<WindowsHoverDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  final FocusScopeNode _focusScope = FocusScopeNode(debugLabel: 'Windows dock');
  final ScrollController _scroll = ScrollController();
  late List<FocusNode> _itemFocus;
  late List<GlobalKey> _itemKeys;
  Timer? _delay;
  bool _hovered = false;
  bool _focused = false;
  bool _keyboardInput = false;
  bool _keyboardFocus = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.destinations.length, (_) => GlobalKey());
    _itemFocus = _makeFocusNodes();
    HardwareKeyboard.instance.addHandler(_handleKeyboardInput);
  }

  List<FocusNode> _makeFocusNodes() => List.generate(
      widget.destinations.length,
      (index) =>
          FocusNode(debugLabel: 'Dock ${widget.destinations[index].$3}'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    if (reduce) {
      _delay?.cancel();
      _controller.value = _hovered || _keyboardFocus ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(WindowsHoverDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destinations.length == widget.destinations.length) return;
    for (final node in _itemFocus) {
      node.dispose();
    }
    _itemKeys = List.generate(widget.destinations.length, (_) => GlobalKey());
    _itemFocus = _makeFocusNodes();
  }

  void _revealFocusedItem(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          index >= _itemKeys.length ||
          !_itemFocus[index].hasFocus) {
        return;
      }
      final itemContext = _itemKeys[index].currentContext;
      if (itemContext == null) return;
      unawaited(Scrollable.ensureVisible(
        itemContext,
        alignment: .5,
        duration:
            _reduceMotion ? Duration.zero : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      ));
    });
  }

  bool _handleKeyboardInput(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    _keyboardInput = true;
    if (_focused && !_keyboardFocus) {
      _keyboardFocus = true;
      _target(true);
    }
    return false;
  }

  void _target(bool expand, {Duration? delay}) {
    _delay?.cancel();
    void move() {
      if (!mounted) return;
      if (_reduceMotion) {
        _controller.value = expand ? 1 : 0;
      } else if (expand) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }

    if (_reduceMotion || delay == null) {
      move();
    } else {
      _delay = Timer(delay, move);
    }
  }

  void _enter() {
    _hovered = true;
    _target(true, delay: const Duration(milliseconds: 70));
  }

  void _exit() {
    _hovered = false;
    if (!_keyboardFocus) {
      _target(false, delay: const Duration(milliseconds: 160));
    }
  }

  void _pointerDown(PointerDownEvent _) {
    // Mouse clicks can focus a destination without pinning the dock open.
    _keyboardInput = false;
    _keyboardFocus = false;
    if (!_hovered) {
      _target(false, delay: const Duration(milliseconds: 160));
    }
  }

  void _focusChanged(bool focused) {
    _focused = focused;
    _keyboardFocus = focused && _keyboardInput;
    if (_keyboardFocus) {
      _target(true);
    } else if (!_hovered) {
      _target(false, delay: const Duration(milliseconds: 160));
    }
  }

  KeyEventResult _navigate(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || _itemFocus.isEmpty) {
      return KeyEventResult.ignored;
    }
    final current = _itemFocus.indexWhere((node) => node.hasFocus);
    final key = event.logicalKey;
    int? next;
    if (key == LogicalKeyboardKey.arrowDown) {
      next = (current + 1) % _itemFocus.length;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      next = (current - 1 + _itemFocus.length) % _itemFocus.length;
    } else if (key == LogicalKeyboardKey.home) {
      next = 0;
    } else if (key == LogicalKeyboardKey.end) {
      next = _itemFocus.length - 1;
    }
    if (next == null) return KeyEventResult.ignored;
    _itemFocus[next].requestFocus();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _delay?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKeyboardInput);
    for (final node in _itemFocus) {
      node.dispose();
    }
    _focusScope.dispose();
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final contrast = MediaQuery.highContrastOf(context);
    final reservedWidth = WindowsHoverDock.reservedWidth(context);
    final rowHeight =
        math.max(56.0, MediaQuery.textScalerOf(context).scale(15) * 1.4 + 24);
    final closedWidth = rowHeight + 16;
    final openWidth = math.max(closedWidth, reservedWidth - 24);
    final contentHeight = widget.destinations.length * rowHeight +
        math.max(0, widget.destinations.length - 1) * 6;

    return SizedBox(
      key: const ValueKey('windows-dock-host'),
      width: reservedWidth,
      child: LayoutBuilder(builder: (context, constraints) {
        final availableHeight = constraints.hasBoundedHeight
            ? math.max(0.0, constraints.maxHeight - 24)
            : contentHeight + 16;
        final surfaceHeight = math.min(contentHeight + 16, availableHeight);
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final progress =
                    Curves.easeOutCubic.transform(_controller.value);
                final surfaceWidth =
                    closedWidth + (openWidth - closedWidth) * progress;
                final shape = RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(
                      color: colors.outlineVariant.withOpacity(.7), width: .8),
                );
                return MouseRegion(
                  key: const ValueKey('windows-dock-hover-area'),
                  onEnter: (_) => _enter(),
                  onExit: (_) => _exit(),
                  child: Listener(
                    onPointerDown: _pointerDown,
                    child: FocusScope(
                      node: _focusScope,
                      onFocusChange: _focusChanged,
                      onKeyEvent: _navigate,
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: PhysicalShape(
                          key: const ValueKey('windows-dock-surface'),
                          clipper: ShapeBorderClipper(shape: shape),
                          clipBehavior: Clip.antiAlias,
                          color: Colors.transparent,
                          elevation: contrast ? 0 : 3,
                          shadowColor:
                              Colors.black.withOpacity(dark ? .32 : .15),
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                                shape: shape, color: colors.surface),
                            child: SizedBox(
                              width: surfaceWidth,
                              height: surfaceHeight,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: SingleChildScrollView(
                                  controller: _scroll,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (var i = 0;
                                          i < widget.destinations.length;
                                          i++) ...[
                                        if (i > 0) const SizedBox(height: 6),
                                        _item(context,
                                            index: i,
                                            rowHeight: rowHeight,
                                            openWidth: openWidth - 16,
                                            progress: progress),
                                      ],
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
              },
            ),
          ),
        );
      }),
    );
  }

  Widget _item(BuildContext context,
      {required int index,
      required double rowHeight,
      required double openWidth,
      required double progress}) {
    final colors = Theme.of(context).colorScheme;
    final contrast = MediaQuery.highContrastOf(context);
    final destination = widget.destinations[index];
    final selected = index == widget.selectedIndex;
    final shape = StadiumBorder(
      side: BorderSide(
          color: selected
              ? colors.primary.withOpacity(contrast ? 1 : .25)
              : Colors.transparent,
          width: 1),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: destination.$3,
      excludeSemantics: true,
      child: Tooltip(
        message: destination.$3,
        excludeFromSemantics: true,
        child: PhysicalShape(
          key: ValueKey('windows-dock-item-$index'),
          clipper: ShapeBorderClipper(shape: shape),
          clipBehavior: Clip.antiAlias,
          color: Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
          child: Material(
            shape: shape,
            color: selected
                ? (contrast
                    ? colors.primaryContainer
                    : colors.primary.withOpacity(.12))
                : Colors.transparent,
            child: InkWell(
              focusNode: _itemFocus[index],
              onFocusChange: (focused) {
                if (focused) _revealFocusedItem(index);
              },
              customBorder: shape,
              splashFactory: NoSplash.splashFactory,
              onTap: () => widget.onSelected(index),
              child: SizedBox(
                key: _itemKeys[index],
                height: rowHeight,
                child: Stack(children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: rowHeight,
                    child: Icon(selected ? destination.$2 : destination.$1,
                        key: ValueKey('windows-dock-icon-$index'),
                        color:
                            selected ? colors.primary : colors.onSurfaceVariant,
                        size: 24),
                  ),
                  Positioned(
                    left: rowHeight + 8,
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: math.max(0, openWidth - rowHeight - 20),
                        maxWidth: math.max(0, openWidth - rowHeight - 20),
                        child: Transform.translate(
                          key: ValueKey('windows-dock-label-offset-$index'),
                          offset: Offset(-8 * (1 - progress), 0),
                          child: Opacity(
                            key: ValueKey('windows-dock-label-opacity-$index'),
                            opacity: progress,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(destination.$3,
                                  key: ValueKey('windows-dock-label-$index'),
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: selected
                                          ? colors.primary
                                          : colors.onSurfaceVariant)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
