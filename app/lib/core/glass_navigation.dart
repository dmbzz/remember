import 'package:flutter/material.dart';

import 'motion.dart';

/// An opaque navigation capsule with a transparent exterior.
class GlassNavigationSurface extends StatelessWidget {
  const GlassNavigationSurface(
      {super.key, required this.child, this.radius = 30, this.pill = false});

  final Widget child;
  final double radius;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.of(context).highContrast;
    // Use one path for the fill, clip, border, and physical shadow.
    // StadiumBorder follows the bar height, including accessibility scaling.
    final side = BorderSide(
        color: colors.outlineVariant.withOpacity(dark ? .75 : .65), width: .8);
    final OutlinedBorder shape = pill
        ? StadiumBorder(side: side)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius), side: side);
    final surface = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: colors.surface,
      ),
      child: child,
    );
    return PhysicalShape(
      clipper: ShapeBorderClipper(shape: shape),
      clipBehavior: Clip.antiAlias,
      color: Colors.transparent,
      elevation: highContrast ? 0 : 3,
      shadowColor: Colors.black.withOpacity(dark ? .32 : .18),
      child: surface,
    );
  }
}

/// One continuous selection lens, shared by the phone bar and desktop rail.
/// Implicit positioning retargets from its current location on rapid taps.
class GlassNavigationGroup extends StatelessWidget {
  const GlassNavigationGroup(
      {super.key,
      required this.destinations,
      required this.selectedIndex,
      required this.onSelected,
      this.desktop = false});

  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool desktop;

  static double mobileHeight(BuildContext context) =>
      (48 + 3 + MediaQuery.textScalerOf(context).scale(12) * 1.5 + 8)
          .clamp(70.0, 120.0)
          .toDouble();

  static double railHeight(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(15) * 1.5 + 10)
          .clamp(58.0, double.infinity)
          .toDouble();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final contrast = MediaQuery.highContrastOf(context);
    final height = desktop ? railHeight(context) : mobileHeight(context);
    final stride = height + 6;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return LayoutBuilder(builder: (context, constraints) {
      final cellWidth = desktop
          ? constraints.maxWidth
          : constraints.maxWidth / destinations.length;
      return SizedBox(
        height: desktop ? destinations.length * stride - 6 : height,
        child: Stack(clipBehavior: Clip.hardEdge, children: [
          AnimatedPositioned(
            key: const ValueKey('navigation-lens-position'),
            duration: duration,
            curve: Curves.easeOutCubic,
            left: desktop ? 0 : selectedIndex * cellWidth + 4,
            top: desktop ? selectedIndex * stride : 4,
            width: desktop ? cellWidth : cellWidth - 8,
            height: desktop ? height : height - 8,
            child: IgnorePointer(
                child: DecoratedBox(
              key: const ValueKey('navigation-lens'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: contrast
                      ? [colors.primaryContainer, colors.primaryContainer]
                      : [
                          colors.primary.withOpacity(.17),
                          colors.primary.withOpacity(.07)
                        ],
                ),
                border: Border.all(
                    color: contrast
                        ? colors.primary
                        : colors.primary.withOpacity(.23)),
              ),
            )),
          ),
          Flex(
            direction: desktop ? Axis.vertical : Axis.horizontal,
            children: [
              for (var i = 0; i < destinations.length; i++) ...[
                if (desktop && i > 0) const SizedBox(height: 6),
                if (desktop)
                  RoundNavigationItem(
                      icon: destinations[i].$1,
                      selectedIcon: destinations[i].$2,
                      label: destinations[i].$3,
                      selected: selectedIndex == i,
                      onTap: () => onSelected(i),
                      desktop: true,
                      grouped: true)
                else
                  Expanded(
                      child: RoundNavigationItem(
                          icon: destinations[i].$1,
                          selectedIcon: destinations[i].$2,
                          label: destinations[i].$3,
                          selected: selectedIndex == i,
                          onTap: () => onSelected(i),
                          grouped: true)),
              ],
            ],
          ),
        ]),
      );
    });
  }
}

class RoundNavigationItem extends StatelessWidget {
  const RoundNavigationItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.desktop = false,
    this.grouped = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool desktop;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mobileHeight = GlassNavigationGroup.mobileHeight(context);
    final circle = AnimatedContainer(
      duration: StudyMotion.quick(context),
      curve: StudyMotion.standardCurve,
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: grouped
            ? Colors.transparent
            : selected
                ? colors.primary.withOpacity(.14)
                : colors.surface.withOpacity(.38),
        border: Border.all(
          color: grouped
              ? Colors.transparent
              : selected
                  ? colors.primary.withOpacity(.26)
                  : colors.outlineVariant.withOpacity(.5),
        ),
      ),
      child: AnimatedScale(
          scale: selected ? 1.02 : 1,
          duration: StudyMotion.standard(context),
          curve: Curves.easeOutCubic,
          child: Icon(selected ? selectedIcon : icon,
              size: 23,
              color: selected ? colors.primary : colors.onSurfaceVariant)),
    );
    final caption = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: desktop ? 15 : 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          splashFactory: NoSplash.splashFactory,
          overlayColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.pressed)
                  ? colors.primary.withOpacity(.08)
                  : null),
          child: desktop
              ? SizedBox(
                  height: GlassNavigationGroup.railHeight(context),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: Row(children: [
                      circle,
                      const SizedBox(width: 4),
                      Expanded(child: caption),
                    ]),
                  ))
              : SizedBox(
                  height: mobileHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [circle, const SizedBox(height: 3), caption],
                  ),
                ),
        ),
      ),
    );
  }
}
