import 'dart:convert';
import 'schedule_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/api_client.dart';
import '../../data/api_result.dart';
import '../../data/course_store.dart';
import '../../core/weeks.dart';
import '../../platform/schedule_widget_bridge.dart';

class ScheduleSnapshot {
  final List<Map<String, dynamic>> entries;
  final DateTime semesterStart;
  final DateTime updatedAt;
  final String termLabel;
  final bool offline;
  final SchedulePreferences preferences;
  final int revision;
  final bool configured;
  final String? error;
  const ScheduleSnapshot(
      {required this.entries,
      required this.semesterStart,
      required this.updatedAt,
      required this.termLabel,
      this.preferences = const SchedulePreferences(),
      this.revision = 0,
      this.configured = false,
      this.offline = false,
      this.error});
  Map<String, dynamic> toJson() => {
        'version': 1,
        'entries': entries
            .map((entry) =>
                {...entry, 'weeks': WeeksFormatter.normalize(entry['weeks'])})
            .toList(),
        'semester_start': semesterStart.toIso8601String().substring(0, 10),
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'preferences': preferences.toJson(),
        'settings_revision': revision,
        'settings_configured': configured,
        'semester_weeks': preferences.semesterWeeks,
        'term_label': termLabel
      };
  factory ScheduleSnapshot.fromJson(Map<String, dynamic> value,
          {bool offline = false, String? error}) =>
      ScheduleSnapshot(
          entries: (value['entries'] as List).cast<Map<String, dynamic>>(),
          semesterStart: DateTime.parse(value['semester_start']),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(value['updated_at']),
          termLabel: value['term_label'] ?? '大二上',
          preferences: SchedulePreferences.fromJson(
              (value['preferences'] as Map?)?.cast<String, dynamic>()),
          revision: (value['settings_revision'] as num?)?.toInt() ?? 0,
          configured: value['settings_configured'] == true,
          offline: offline,
          error: error);
}

class ScheduleStore {
  static const cacheKey = 'cna_schedule_cache_v1';
  static Future<ScheduleSnapshot> withPhoneFlags(
      ScheduleSnapshot snapshot) async {
    final flags = await CourseStore.autoFlags();
    for (final entry in snapshot.entries) {
      if (flags.containsKey(entry['course_id'])) {
        entry['auto_record'] = flags[entry['course_id']];
      }
    }
    return snapshot;
  }

  static Future<ScheduleSnapshot?> cached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw == null) return null;
      final data = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (data['settings_configured'] != true) {
        data['semester_start'] =
            prefs.getString('cna_semester_start') ?? data['semester_start'];
        data['term_label'] =
            prefs.getString('cna_widget_term_label') ?? data['term_label'];
      }
      return withPhoneFlags(ScheduleSnapshot.fromJson(data, offline: true));
    } catch (_) {
      return null;
    }
  }

  static Future<ScheduleSnapshot> load(ApiClient api) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = await cached();
    final remote = await api.getScheduleSnapshot();
    if (!remote.ok && previous?.configured == true) {
      return ScheduleSnapshot.fromJson(previous!.toJson(),
          offline: true, error: remote.error ?? '课表设置同步失败，保留上次完整课表');
    }
    final data = remote.ok ? remote.data : null;
    final List<ApiResult<Object>> results;
    if (data != null &&
        data['entries'] is List &&
        data['courses'] is List &&
        data['preferences'] is Map) {
      results = [
        ApiResult<List<Map<String, dynamic>>>.ok((data['entries'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList()),
        ApiResult<List<Map<String, dynamic>>>.ok((data['courses'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList()),
        ApiResult<Map<String, dynamic>>.ok(
            (data['preferences'] as Map).cast<String, dynamic>())
      ];
    } else {
      results = await Future.wait([
        api.getScheduleEntries(),
        api.getCourses(),
        api.getSchedulePreferences()
      ]);
    }
    final entriesResult = results[0] as ApiResult<List<Map<String, dynamic>>>;
    final coursesResult = results[1] as ApiResult<List<Map<String, dynamic>>>;
    if (!entriesResult.ok) {
      final cached = prefs.getString(cacheKey);
      if (cached != null) {
        try {
          final snapshot = ScheduleSnapshot.fromJson(jsonDecode(cached),
              offline: true, error: entriesResult.error);
          // 学期设置可能在离线时已修改，不使用旧缓存的周次起点。
          final data = snapshot.toJson();
          if (data['settings_configured'] != true) {
            data['semester_start'] =
                prefs.getString('cna_semester_start') ?? data['semester_start'];
            data['term_label'] =
                prefs.getString('cna_widget_term_label') ?? snapshot.termLabel;
          }
          return withPhoneFlags(ScheduleSnapshot.fromJson(data,
              offline: true, error: entriesResult.error));
        } catch (_) {/* 损坏缓存不能伪装成无课。 */}
      }
      throw StateError(entriesResult.error ?? '课表同步失败');
    }
    if (previous?.configured == true &&
        (!results[2].ok || results[2].data is! Map)) {
      return ScheduleSnapshot.fromJson(previous!.toJson(),
          offline: true, error: '课表设置同步失败，保留上次完整课表');
    }
    final courseList = coursesResult.ok
        ? coursesResult.data ?? <Map<String, dynamic>>[]
        : await CourseStore.cached();
    if (coursesResult.ok) await CourseStore.save(courseList);
    final courses = {
      for (final item in courseList)
        (item['id'] ?? item['course_id']).toString(): item
    };
    final entries =
        (entriesResult.data ?? <Map<String, dynamic>>[]).map((item) {
      final course = courses[item['course_id']] ?? <String, dynamic>{};
      final teacher = (course['teacher'] ?? item['teacher'] ?? '').toString();
      var location = (item['location'] ?? '').toString().trim();
      if (teacher.isNotEmpty && location.endsWith(teacher)) {
        location =
            location.substring(0, location.length - teacher.length).trim();
      }
      return {
        ...item,
        'course_name': item['course_name'] ?? course['name'] ?? '未命名课程',
        'teacher': teacher,
        'location': location,
        'auto_record': course.containsKey('auto_record')
            ? course['auto_record'] == true
            : (previous?.entries.any((old) =>
                    old['course_id'] == item['course_id'] &&
                    old['auto_record'] == true) ??
                false)
      };
    }).toList();
    final shared = results[2].ok && results[2].data is Map
        ? (results[2].data as Map).cast<String, dynamic>()
        : null;
    final configured =
        shared?['configured'] == true || (previous?.configured ?? false);
    final rawPrefs = shared?['configured'] == true
        ? (shared!['settings'] as Map).cast<String, dynamic>()
        : null;
    if (rawPrefs != null) {
      await prefs.setString(
          'cna_semester_start', '${rawPrefs['semester_start']}');
      await prefs.setString(
          'cna_widget_term_label', '${rawPrefs['term_label']}');
    }
    final snapshot = await withPhoneFlags(ScheduleSnapshot(
        entries: entries,
        preferences: rawPrefs != null
            ? SchedulePreferences.fromJson(rawPrefs)
            : previous?.preferences ?? const SchedulePreferences(),
        revision:
            (shared?['revision'] as num?)?.toInt() ?? previous?.revision ?? 0,
        configured: configured,
        semesterStart:
            DateTime.tryParse(prefs.getString('cna_semester_start') ?? '') ??
                DateTime(2026, 8, 31),
        updatedAt: DateTime.now(),
        termLabel: prefs.getString('cna_widget_term_label') ?? '大二上'));
    await prefs.setString(cacheKey, jsonEncode(snapshot.toJson()));
    return snapshot;
  }

  static Future<void> refreshWidget(ApiClient api) async {
    try {
      await ScheduleWidgetBridge.sync((await load(api)).toJson());
    } catch (_) {/* 保留已有桌面缓存，课表页显示具体同步失败信息。 */}
  }
}
