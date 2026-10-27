import 'package:flutter/material.dart';
import 'shapes.dart';

/// Flat, readable groups with one shared clipped outline.
class StudySection extends StatelessWidget {
  const StudySection(
      {super.key,
      required this.child,
      this.tone,
      this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final Color? tone;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: StudyShapes.cardBorder,
          side: BorderSide(
              color: tone ?? colors.outlineVariant,
              width: tone == null ? .7 : 1.2)),
      child: Padding(padding: padding, child: child),
    );
  }
}

class StudyHeading extends StatelessWidget {
  const StudyHeading(
      {super.key, required this.title, required this.subtitle, this.trailing});
  final String title;
  final String subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 5),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ]),
              if (trailing != null) trailing!,
            ]),
        const SizedBox(height: 18),
        Divider(
            height: 2,
            thickness: 1.5,
            color: Theme.of(context).colorScheme.onSurface),
      ]);
}
