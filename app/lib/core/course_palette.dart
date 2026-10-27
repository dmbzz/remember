import 'package:flutter/material.dart';

/// Course identity stays separate from the orange navigation/action color.
class CourseTone {
  const CourseTone(this.fill, this.ink, this.line);
  final Color fill;
  final Color ink;
  final Color line;
}

abstract final class CoursePalette {
  static const _names = <String, int>{
    '工程力学': 0,
    '普通物理': 1,
    '线性代数': 2,
    '大学英语（三）': 3,
    '电工电子技术': 4,
    'C语言程序设计': 5,
    '大学体育（三）': 6,
    '马克思主义基本原理': 7,
  };
  static const _light = [
    CourseTone(Color(0xFFF6DFB6), Color(0xFF5E411D), Color(0xFFD0A662)),
    CourseTone(Color(0xFFDCE8FA), Color(0xFF294870), Color(0xFF9BB6DD)),
    CourseTone(Color(0xFFD9ECE8), Color(0xFF28594F), Color(0xFF91BDB1)),
    CourseTone(Color(0xFFE7DEF8), Color(0xFF533776), Color(0xFFB3A1D0)),
    CourseTone(Color(0xFFF2D7DB), Color(0xFF762D40), Color(0xFFD4A0AB)),
    CourseTone(Color(0xFFF3DDEC), Color(0xFF733C5B), Color(0xFFD3A6BF)),
    CourseTone(Color(0xFFE1ECCD), Color(0xFF455A29), Color(0xFFAFC392)),
    CourseTone(Color(0xFFE8E1D6), Color(0xFF5E5140), Color(0xFFBFB09C)),
  ];
  static const _dark = [
    CourseTone(Color(0xFF473720), Color(0xFFF2D9AC), Color(0xFFB79860)),
    CourseTone(Color(0xFF25374D), Color(0xFFCEE2FF), Color(0xFF82A7D8)),
    CourseTone(Color(0xFF203D37), Color(0xFFC6EEE2), Color(0xFF7DBAAA)),
    CourseTone(Color(0xFF392C4D), Color(0xFFE5D4FF), Color(0xFFAA91CA)),
    CourseTone(Color(0xFF482A31), Color(0xFFFFD3DA), Color(0xFFCF91A1)),
    CourseTone(Color(0xFF442C3C), Color(0xFFF6D3E9), Color(0xFFC591B2)),
    CourseTone(Color(0xFF333C26), Color(0xFFE0ECC1), Color(0xFFA6BC83)),
    CourseTone(Color(0xFF3B352D), Color(0xFFE9DFCE), Color(0xFFB7A389)),
  ];
  static CourseTone forName(String name, {bool dark = false}) {
    final normalized =
        name.replaceAll(' ', '').replaceAll('(', '（').replaceAll(')', '）');
    final alias = normalized.contains('物理')
        ? 1
        : normalized.contains('电工')
            ? 4
            : null;
    final index = _names[normalized] ??
        alias ??
        normalized.runes
                .fold(0, (int n, int ch) => (n * 31 + ch) & 0x7fffffff) %
            _light.length;
    return (dark ? _dark : _light)[index];
  }

  static CourseTone of(BuildContext context, String name) =>
      forName(name, dark: Theme.of(context).brightness == Brightness.dark);
}
