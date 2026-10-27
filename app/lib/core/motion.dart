import 'package:flutter/material.dart';

/// Shared, short transitions for changes that help people keep their place.
/// The platform's reduced-motion setting always wins.
abstract final class StudyMotion {
  static const standardDuration = Duration(milliseconds: 220);
  static const quickDuration = Duration(milliseconds: 160);
  static const standardCurve = Curves.easeOutCubic;

  static Duration standard(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : standardDuration;

  static Duration quick(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : quickDuration;
}

/// Reading routes move a few pixels without compositing the entire long page.
Route<T> studyReadingRoute<T>(BuildContext context, WidgetBuilder builder) =>
    PageRouteBuilder<T>(
      transitionDuration: StudyMotion.quick(context),
      reverseTransitionDuration: StudyMotion.quick(context),
      pageBuilder: (context, animation, secondary) => builder(context),
      transitionsBuilder: (context, animation, secondary, child) =>
          Transform.translate(
        offset: Offset(
            MediaQuery.disableAnimationsOf(context)
                ? 0
                : 10 * (1 - Curves.easeOutCubic.transform(animation.value)),
            0),
        child: child,
      ),
    );

/// Keep every visited page mounted; animate only a short translation of the
/// newly selected content. No whole-page opacity layer or repeated data fetch.
class StudyTabDeck extends StatefulWidget {
  const StudyTabDeck({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  State<StudyTabDeck> createState() => _StudyTabDeckState();
}

class _StudyTabDeckState extends State<StudyTabDeck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: StudyMotion.standardDuration, value: 1);
  double _direction = 1;

  @override
  void didUpdateWidget(StudyTabDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _direction = widget.index > oldWidget.index ? 1 : -1;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
        child: IndexedStack(
      index: widget.index,
      children: List.generate(
          widget.children.length,
          (index) => TickerMode(
                enabled: index == widget.index,
                child: RepaintBoundary(
                    child: AnimatedBuilder(
                  animation: _controller,
                  child: widget.children[index],
                  builder: (context, child) {
                    final progress =
                        Curves.easeOutCubic.transform(_controller.value);
                    final offset = index == widget.index &&
                            !MediaQuery.disableAnimationsOf(context)
                        ? 10 * _direction * (1 - progress)
                        : 0.0;
                    return Transform.translate(
                        offset: Offset(offset, 0), child: child);
                  },
                )),
              )),
    ));
  }
}

/// Crossfades related content. The small horizontal movement reinforces
/// direction without making a long schedule feel as if it is sliding away.
class StudyContentTransition extends StatelessWidget {
  const StudyContentTransition({
    super.key,
    required this.child,
    required this.identity,
  });

  final Widget child;
  final Object identity;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: StudyMotion.standard(context),
      switchInCurve: StudyMotion.standardCurve,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        if (reduceMotion) {
          return FadeTransition(opacity: animation, child: child);
        }
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.025, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(identity), child: child),
    );
  }
}
