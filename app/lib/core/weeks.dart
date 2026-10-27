/// 周次集合的归一与显示（架构设计 v3.3 §3.9.1）。
///
/// `ScheduleEntry.weeks` 在新模型中是 **周次集合 `list[int]`**（升序去重），
/// 以表达「单周 / 双周 / 停课断档」。为兼容旧数据（字符串 `"1-16"` / `"1-8,10-16"`），
/// 本工具统一把两种形态归一为 `List<int>` 再展示。
class WeeksFormatter {
  const WeeksFormatter._();

  /// 把任意来源的 weeks（`List<int>` 或 `String`）归一为**升序去重**的周次列表。
  static List<int> normalize(dynamic weeks) {
    if (weeks is List) {
      final result = <int>{};
      for (final e in weeks) {
        final v = e is int ? e : int.tryParse('$e');
        if (v != null && v > 0) result.add(v);
      }
      final sorted = result.toList()..sort();
      return sorted;
    }
    if (weeks is String) {
      return _parseString(weeks);
    }
    return const <int>[];
  }

  /// 解析旧格式字符串：`"1-16"`、`"1-8,10-16"`、`"1-5, 7"` 等。
  static List<int> _parseString(String raw) {
    final result = <int>{};
    for (final chunk in raw.split(',')) {
      final seg = chunk.trim();
      if (seg.isEmpty) continue;
      if (seg.contains('-')) {
        final bounds = seg.split('-');
        if (bounds.length == 2) {
          final start = int.tryParse(bounds[0].trim());
          final end = int.tryParse(bounds[1].trim());
          if (start != null && end != null && end >= start) {
            for (var w = start; w <= end; w++) {
              if (w > 0) result.add(w);
            }
          }
        }
      } else {
        final v = int.tryParse(seg);
        if (v != null && v > 0) result.add(v);
      }
    }
    final sorted = result.toList()..sort();
    return sorted;
  }

  /// 压缩连续区间：`[1,2,3,5,6,9] -> "1-3, 5-6, 9"`。
  static String compress(List<int> weeks) {
    if (weeks.isEmpty) return '';
    final sorted = weeks.toSet().toList()..sort();
    final parts = <String>[];
    var start = sorted.first;
    var prev = sorted.first;
    for (var i = 1; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur == prev + 1) {
        prev = cur;
        continue;
      }
      parts.add(start == prev ? '$start' : '$start-$prev');
      start = cur;
      prev = cur;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    return parts.join(', ');
  }

  /// 面向课表展示：识别「单周 / 双周」模式，否则给出压缩区间。
  ///
  /// 例：`{1,3,...,19} -> "单周 1-19"`；`{8,10,12} -> "双周 8-12"`；
  /// `{1..5,7..12} -> "1-5, 7-12"`。
  static String describe(dynamic weeks, {bool firstWeekOdd = true}) {
    final w = normalize(weeks);
    if (w.isEmpty) return '—';
    final hasOdd = w.any((e) => e.isOdd);
    final hasEven = w.any((e) => e.isEven);
    final regular = List.generate(w.length - 1, (i) => w[i + 1] - w[i] == 2)
        .every((v) => v);
    if (!regular && (hasOdd != hasEven)) return compress(w);
    if (hasOdd && !hasEven) return '${firstWeekOdd ? '单周' : '双周'} ${_span(w)}';
    if (hasEven && !hasOdd) return '${firstWeekOdd ? '双周' : '单周'} ${_span(w)}';
    return compress(w);
  }

  static String _span(List<int> sorted) {
    if (sorted.length == 1) return '${sorted.first}';
    return '${sorted.first}-${sorted.last}';
  }
}
