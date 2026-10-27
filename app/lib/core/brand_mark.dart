import 'package:flutter/material.dart';

/// The approved folded-page brand mark. Functional icons keep their own meaning.
class RememberBrandMark extends StatelessWidget {
  const RememberBrandMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: Image.asset('assets/icons/remember.png',
            width: size, height: size, excludeFromSemantics: true),
      );
}
