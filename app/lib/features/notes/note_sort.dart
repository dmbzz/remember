import 'package:shared_preferences/shared_preferences.dart';

/// 笔记按标题/文件名时间排序的方向。
enum NoteSortOrder {
  newestFirst,
  oldestFirst;

  static const String prefKey = 'cna_notes_sort_order';

  String get wireValue => switch (this) {
        NoteSortOrder.newestFirst => 'newest_first',
        NoteSortOrder.oldestFirst => 'oldest_first',
      };

  String get label => switch (this) {
        NoteSortOrder.newestFirst => '最新优先',
        NoteSortOrder.oldestFirst => '从早到晚',
      };

  String get headingLabel => switch (this) {
        NoteSortOrder.newestFirst => '按时间 · 最新优先',
        NoteSortOrder.oldestFirst => '按时间 · 从早到晚',
      };

  String get tooltip => switch (this) {
        NoteSortOrder.newestFirst => '当前按标题时间最新优先，点击切换为从早到晚',
        NoteSortOrder.oldestFirst => '当前按标题时间从早到晚，点击切换为最新优先',
      };

  NoteSortOrder get toggled => this == NoteSortOrder.newestFirst
      ? NoteSortOrder.oldestFirst
      : NoteSortOrder.newestFirst;

  static NoteSortOrder fromWire(String? raw) =>
      raw == 'oldest_first' ? NoteSortOrder.oldestFirst : NoteSortOrder.newestFirst;

  static Future<NoteSortOrder> load() async {
    final prefs = await SharedPreferences.getInstance();
    return fromWire(prefs.getString(prefKey));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, wireValue);
  }
}

final _suffixDateRe = RegExp(r'_(\d{4}-\d{2}-\d{2})$');
final _sepDateTimeRe = RegExp(
  r'(?<!\d)((?:19|20)\d{2})[-./年](0?[1-9]|1[0-2])[-./月](0?[1-9]|[12]\d|3[01])日?'
  r'(?:[T _-]+([01]?\d|2[0-3])[:：-]([0-5]\d)(?:[:：-]([0-5]\d))?)?(?!\d)',
);
final _compactDateTimeRe = RegExp(
  r'(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)'
  r'(?:[T _-]+([01]\d|2[0-3])[:：-]?([0-5]\d))?',
);

DateTime? _buildValidDateTime(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  final dt = DateTime.utc(year, month, day, hour, minute, second);
  if (dt.year != year ||
      dt.month != month ||
      dt.day != day ||
      dt.hour != hour ||
      dt.minute != minute ||
      dt.second != second) {
    return null;
  }
  return dt;
}

/// 从标题或文件名中提取合法的日期时间，与后端 `note_sorting.py` 规则保持一致。
DateTime? extractNoteDateFromText(String? text) {
  if (text == null) return null;
  final raw = text.trim();
  if (raw.isEmpty) return null;

  final suffix = _suffixDateRe.firstMatch(raw);
  if (suffix != null) {
    final parts = suffix.group(1)!.split('-');
    final parsed = _buildValidDateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    if (parsed != null) return parsed;
  }

  for (final m in _sepDateTimeRe.allMatches(raw)) {
    final parsed = _buildValidDateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) != null ? int.parse(m.group(4)!) : 0,
      m.group(5) != null ? int.parse(m.group(5)!) : 0,
      m.group(6) != null ? int.parse(m.group(6)!) : 0,
    );
    if (parsed != null) return parsed;
  }

  for (final m in _compactDateTimeRe.allMatches(raw)) {
    final parsed = _buildValidDateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) != null ? int.parse(m.group(4)!) : 0,
      m.group(5) != null ? int.parse(m.group(5)!) : 0,
    );
    if (parsed != null) return parsed;
  }

  return null;
}

String _stemFromPath(String rawPath) {
  final normalized = rawPath.replaceAll('\\', '/');
  final fileName = normalized.split('/').last;
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}

/// 按 class_date → topic → 路径文件名 stem 顺序提取笔记标题时间。
DateTime? extractNoteTitleTime(Map<String, dynamic> note) {
  final classDate = note['class_date']?.toString();
  final fromClassDate = extractNoteDateFromText(classDate);
  if (fromClassDate != null) return fromClassDate;

  final topic = note['topic']?.toString();
  final fromTopic = extractNoteDateFromText(topic);
  if (fromTopic != null) return fromTopic;

  for (final key in const ['relative_path', 'obsidian_path']) {
    final path = note[key]?.toString();
    if (path != null && path.trim().isNotEmpty) {
      final fromPath = extractNoteDateFromText(_stemFromPath(path));
      if (fromPath != null) return fromPath;
    }
  }
  return null;
}

int _updatedEpochMs(Map<String, dynamic> note) {
  for (final key in const ['updated_at', 'created_at']) {
    final raw = note[key]?.toString();
    if (raw != null && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
    }
  }
  return 0;
}

int _lessonValue(Map<String, dynamic> note, NoteSortOrder order) {
  final raw = note['lesson'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final parsed = int.tryParse('${raw ?? ''}');
  if (parsed != null) return parsed;
  return order == NoteSortOrder.newestFirst ? -1 : 1 << 30;
}

int _compareFallback(Map<String, dynamic> a, Map<String, dynamic> b) {
  final updatedCmp = _updatedEpochMs(b).compareTo(_updatedEpochMs(a));
  if (updatedCmp != 0) return updatedCmp;

  final topicA = (a['topic'] ?? '').toString().toLowerCase();
  final topicB = (b['topic'] ?? '').toString().toLowerCase();
  final topicCmp = topicA.compareTo(topicB);
  if (topicCmp != 0) return topicCmp;

  final pathA = (a['relative_path'] ?? a['obsidian_path'] ?? '').toString();
  final pathB = (b['relative_path'] ?? b['obsidian_path'] ?? '').toString();
  final pathCmp = pathA.compareTo(pathB);
  if (pathCmp != 0) return pathCmp;

  return (a['note_id'] ?? '').toString().compareTo((b['note_id'] ?? '').toString());
}

/// 按标题时间顺序排序；无日期笔记始终排在末尾并按更新时间/标题稳定兜底。
List<Map<String, dynamic>> sortNotesByTitleTime(
  Iterable<Map<String, dynamic>> notes,
  NoteSortOrder order,
) {
  final dated = <(DateTime, Map<String, dynamic>)>[];
  final undated = <Map<String, dynamic>>[];

  for (final note in notes) {
    final dt = extractNoteTitleTime(note);
    if (dt != null) {
      dated.add((dt, note));
    } else {
      undated.add(note);
    }
  }

  dated.sort((a, b) {
    final timeCmp = order == NoteSortOrder.newestFirst
        ? b.$1.compareTo(a.$1)
        : a.$1.compareTo(b.$1);
    if (timeCmp != 0) return timeCmp;

    final lessonA = _lessonValue(a.$2, order);
    final lessonB = _lessonValue(b.$2, order);
    final lessonCmp = order == NoteSortOrder.newestFirst
        ? lessonB.compareTo(lessonA)
        : lessonA.compareTo(lessonB);
    if (lessonCmp != 0) return lessonCmp;

    return _compareFallback(a.$2, b.$2);
  });

  undated.sort(_compareFallback);
  return [
    for (final pair in dated) pair.$2,
    ...undated,
  ];
}
