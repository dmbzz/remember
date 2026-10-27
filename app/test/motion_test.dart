import 'package:class_notes_assistant/core/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('系统要求减少动画时，页面过渡立即完成', (tester) async {
    Duration? normal;
    Duration? reduced;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        normal = StudyMotion.standard(context);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: Builder(builder: (context) {
            reduced = StudyMotion.standard(context);
            return const SizedBox.shrink();
          }),
        );
      }),
    ));
    expect(normal, StudyMotion.standardDuration);
    expect(reduced, Duration.zero);
  });
}
