import 'package:flutter/material.dart';
import 'orientation_capsule.dart';

/// Touch devices keep the same animated selection in either orientation.
/// The content stays in the same Row slot when the navigation moves.
class StudyNavigationLayout extends StatelessWidget {
  const StudyNavigationLayout(
      {super.key,
      required this.content,
      required this.destinations,
      required this.selectedIndex,
      required this.onSelected});

  final Widget content;
  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    return StudyTouchNavigationLayout(
        desktopNavigation: !touch,
        content: content,
        destinations: destinations,
        selectedIndex: selectedIndex,
        onSelected: onSelected);
  }
}
