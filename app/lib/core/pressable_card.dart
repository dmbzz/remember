import 'package:flutter/material.dart';

import 'motion.dart';
import 'shapes.dart';

/// Full-surface press feedback for a large card. A radial ink splash cannot
/// reach the card edge before a fast navigation gesture covers the route.
class PressableCard extends StatefulWidget {
  const PressableCard({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = StudyShapes.card,
    this.onSecondaryTapDown,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;

  @override
  State<PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<PressableCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (mounted && _pressed != value) setState(() => _pressed = value);
  }

  Future<void> _activate() async {
    if (MediaQuery.disableAnimationsOf(context)) {
      _setPressed(false);
      widget.onTap?.call();
      return;
    }
    _setPressed(true);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    if (!mounted) return;
    _setPressed(false);
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(widget.radius),
    );
    return Material(
      color: colors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onSecondaryTapDown: widget.onSecondaryTapDown,
        customBorder: shape,
        splashFactory: NoSplash.splashFactory,
        onTap: widget.onTap == null ? null : _activate,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        child: AnimatedContainer(
          duration: StudyMotion.quick(context),
          curve: StudyMotion.standardCurve,
          color:
              _pressed ? colors.primary.withOpacity(.13) : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
