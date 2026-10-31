import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../features/schedule/schedule_store.dart';

/// Course identity must be available before any network request completes.
class CourseStore {
  static const cacheKey = 'cna_courses_cache_v1';
  static const autoFlagsKey = 'cna_phone_auto_record_flags_v1';
  static Future<Map<String, bool>> autoFlags() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      return (jsonDecode(prefs.getString(autoFlagsKey) ?? '{}') as Map)
          .map((key, value) => MapEntry('$key', value == true));
    } catch (_) {
      return {};
    }
  }

  static Future<void> setPhoneAutoRecord(String id, bool enabled) async {
    final flags = await autoFlags();
    flags[id] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(autoFlagsKey, jsonEncode(flags));
  }

  static Future<void> save(List<Map<String, dynamic>> courses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, jsonEncode(courses));
  }

  static Future<List<Map<String, dynamic>>> cached() async {
    final prefs = await SharedPreferences.getInstance();
    final byId = <String, Map<String, dynamic>>{};
    try {
      for (final item
          in jsonDecode(prefs.getString(cacheKey) ?? '[]') as List) {
        final course = (item as Map).cast<String, dynamic>();
        final id = '${course['id'] ?? ''}';
        if (id.isNotEmpty) byId[id] = course;
      }
    } catch (_) {/* Existing schedule also contains course IDs and names. */}
    for (final entry in (await ScheduleStore.cached())?.entries ??
        <Map<String, dynamic>>[]) {
      final id = '${entry['course_id'] ?? ''}';
      if (id.isEmpty) continue;
      byId.putIfAbsent(
          id,
          () => {
                'id': id,
                'name': entry['course_name'] ?? '课程',
                'auto_record': entry['auto_record'] == true,
              });
    }
    return byId.values.toList();
  }
}
