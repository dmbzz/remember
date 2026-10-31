import 'package:shared_preferences/shared_preferences.dart';
import '../../data/api_client.dart';
import '../../features/schedule/schedule_store.dart';
import '../../features/schedule/timetable_layout.dart';
import '../../platform/recording_bridge.dart';

/// 只有用户在录音页开启布防且课程本身启用自动录音时才登记闹钟。
class AutoRecordingSchedule {
  static const enabledKey = 'cna_auto_record_enabled';
  // Startup, resume, course settings and the recording page share native state.
  // Keep their asynchronous reads and native writes in request order.
  static Future<void>? _syncTail;

  static Future<int> sync(ApiClient api, RecordingBridge bridge,
      {DateTime? now, bool? enabled, ScheduleSnapshot? snapshot}) {
    final previous = _syncTail;
    final result = previous == null
        ? _sync(api, bridge, now: now, enabled: enabled, snapshot: snapshot)
        : previous.then((_) =>
            _sync(api, bridge, now: now, enabled: enabled, snapshot: snapshot));
    // A failed request must not prevent a later enable/disable from applying.
    late final Future<void> tail;
    void release() {
      if (identical(_syncTail, tail)) _syncTail = null;
    }

    tail = result.then<void>((_) => release(),
        onError: (Object _, StackTrace __) => release());
    _syncTail = tail;
    return result;
  }

  static Future<int> _sync(ApiClient api, RecordingBridge bridge,
      {DateTime? now, bool? enabled, ScheduleSnapshot? snapshot}) async {
    final prefs = await SharedPreferences.getInstance();
    final active = enabled ?? (prefs.getBool(enabledKey) ?? false);
    if (!active) {
      await bridge.syncScheduleAlarms([]);
      return 0;
    }
    final schedule = await ScheduleStore.withPhoneFlags(snapshot ??
        await ScheduleStore.cached() ??
        await ScheduleStore.load(api));
    final current = now ?? DateTime.now();
    final alarms = <Map<String, dynamic>>[];
    final lastWeek = schedule.preferences.semesterWeeks;
    final termEnd = schedule.semesterStart.add(Duration(days: lastWeek * 7));
    final horizon = termEnd.difference(current).inDays.clamp(0, 365) + 1;
    for (var offset = 0; offset < horizon; offset++) {
      final day = DateTime(current.year, current.month, current.day + offset);
      final week = teachingWeek(day, schedule.semesterStart);
      for (final entry in schedule.entries) {
        if (entry['auto_record'] != true ||
            (entry['weekday'] as num?)?.toInt() != day.weekday ||
            (week > lastWeek || !appearsInWeek(entry, week))) continue;
        final start = timeMinutes(entry['start_time']);
        final end = timeMinutes(entry['end_time']);
        if (start == null || end == null || end <= start) continue;
        final when = day.add(Duration(minutes: start));
        final until = day.add(Duration(minutes: end));
        // A switch/permission prompt may finish just after class starts. Keep
        // that occurrence so native can begin now and stop at its original end.
        if (!until.isAfter(current)) continue;
        alarms.add({
          'courseName': '${entry['course_name'] ?? '课程'}',
          'courseId': '${entry['course_id']}',
          'location': '${entry['location'] ?? ''}',
          'classDate': day.toIso8601String().substring(0, 10),
          'startTime': '${entry['start_time']}',
          'endTime': '${entry['end_time']}',
          'triggerEpochMs': when.millisecondsSinceEpoch,
          'endEpochMs': until.millisecondsSinceEpoch,
          'durationMs': (end - start) * 60000,
        });
      }
    }
    if (!await bridge.syncScheduleAlarms(alarms)) {
      throw StateError('无法布防：请授予录音、通知和精确闹钟权限，并保持应用在后台运行');
    }
    return alarms.length;
  }
}
