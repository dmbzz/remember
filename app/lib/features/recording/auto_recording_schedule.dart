import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/api_client.dart';
import '../../features/schedule/schedule_store.dart';
import '../../features/schedule/timetable_layout.dart';
import '../../platform/course_reminder_bridge.dart';
import '../../platform/recording_bridge.dart';

/// 课表页与录音页共享的「本机到点自动录音」实时运行态快照。
class AutoRecordingState {
  final bool enabled;
  final bool syncing;
  final bool armed;
  final int? scheduledCount;
  final String? error;
  final int revision;

  const AutoRecordingState({
    this.enabled = false,
    this.syncing = false,
    this.armed = false,
    this.scheduledCount,
    this.error,
    this.revision = 0,
  });

  AutoRecordingState copyWith({
    bool? enabled,
    bool? syncing,
    bool? armed,
    int? scheduledCount,
    bool clearScheduledCount = false,
    String? error,
    bool clearError = false,
    int? revision,
  }) =>
      AutoRecordingState(
        enabled: enabled ?? this.enabled,
        syncing: syncing ?? this.syncing,
        armed: armed ?? this.armed,
        scheduledCount:
            clearScheduledCount ? null : (scheduledCount ?? this.scheduledCount),
        error: clearError ? null : (error ?? this.error),
        revision: revision ?? this.revision,
      );
}

/// 只有用户开启本机自动录音总开关且课程本身启用自动录音时才登记闹钟。
class AutoRecordingSchedule {
  static const enabledKey = 'cna_auto_record_enabled';
  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);
  static final ValueNotifier<int> revisionNotifier = ValueNotifier<int>(0);
  static final ValueNotifier<AutoRecordingState> stateNotifier =
      ValueNotifier<AutoRecordingState>(const AutoRecordingState());
  // Startup, resume, course settings and the recording page share native state.
  // Keep their asynchronous reads and native writes in request order.
  static Future<void>? _syncTail;
  static int _inFlightCount = 0;

  @visibleForTesting
  static void resetForTest({bool enabled = false}) {
    enabledNotifier.value = enabled;
    revisionNotifier.value = 0;
    stateNotifier.value = AutoRecordingState(enabled: enabled);
  }

  static void _emitState(AutoRecordingState next) {
    if (enabledNotifier.value != next.enabled) {
      enabledNotifier.value = next.enabled;
    }
    stateNotifier.value = next;
  }

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(enabledKey) ?? false;
    final current = stateNotifier.value;
    _emitState(current.copyWith(
      enabled: enabled,
      clearScheduledCount: !enabled,
      clearError: !enabled && current.enabled,
    ));
    return enabled;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
    final nextRev = revisionNotifier.value + 1;
    revisionNotifier.value = nextRev;
    _emitState(stateNotifier.value.copyWith(
      enabled: value,
      clearScheduledCount: !value,
      clearError: true,
      revision: nextRev,
    ));
  }

  static Future<bool> _probeArmed(RecordingBridge bridge) async {
    var armed = false;
    try {
      final setup = await CourseReminderBridge.status();
      armed = setup['armed'] == true;
    } catch (_) {}
    if (!armed) {
      try {
        armed = (await bridge.getStatus()).isArmed;
      } catch (_) {}
    }
    return armed;
  }

  static Future<bool> refreshArmed(RecordingBridge bridge) async {
    final armed = await _probeArmed(bridge);
    if (stateNotifier.value.armed != armed) {
      _emitState(stateNotifier.value.copyWith(armed: armed));
    }
    return armed;
  }

  static Future<int> sync(ApiClient api, RecordingBridge bridge,
      {DateTime? now, bool? enabled, ScheduleSnapshot? snapshot}) {
    _inFlightCount += 1;
    if (!stateNotifier.value.syncing) {
      _emitState(stateNotifier.value.copyWith(syncing: true));
    }
    final previous = _syncTail;
    final result = previous == null
        ? _sync(api, bridge, now: now, enabled: enabled, snapshot: snapshot)
        : previous.then((_) =>
            _sync(api, bridge, now: now, enabled: enabled, snapshot: snapshot));
    // A failed request must not prevent a later enable/disable from applying.
    late final Future<void> tail;
    void release() {
      _inFlightCount = (_inFlightCount - 1).clamp(0, 1 << 30);
      if (identical(_syncTail, tail)) _syncTail = null;
      if (_inFlightCount == 0 && stateNotifier.value.syncing) {
        _emitState(stateNotifier.value.copyWith(syncing: false));
      }
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
    try {
      if (!active) {
        await bridge.syncScheduleAlarms([]);
        final armed = await _probeArmed(bridge);
        final latestEnabled = prefs.getBool(enabledKey) ?? false;
        final nextRev = revisionNotifier.value + 1;
        revisionNotifier.value = nextRev;
        if (latestEnabled == active) {
          _emitState(stateNotifier.value.copyWith(
            armed: armed,
            clearScheduledCount: true,
            clearError: true,
            revision: nextRev,
          ));
        }
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
      final armed = await _probeArmed(bridge);
      final latestEnabled = prefs.getBool(enabledKey) ?? true;
      final nextRev = revisionNotifier.value + 1;
      revisionNotifier.value = nextRev;
      if (latestEnabled == active) {
        _emitState(stateNotifier.value.copyWith(
          armed: armed,
          scheduledCount: alarms.length,
          clearError: true,
          revision: nextRev,
        ));
      }
      return alarms.length;
    } catch (e) {
      final armed = await _probeArmed(bridge);
      final latestEnabled = prefs.getBool(enabledKey) ?? active;
      final nextRev = revisionNotifier.value + 1;
      revisionNotifier.value = nextRev;
      final cleanMsg = '$e'.replaceFirst('Bad state: ', '');
      if (latestEnabled == active) {
        _emitState(stateNotifier.value.copyWith(
          armed: armed,
          error: active ? cleanMsg : '撤销本机排期失败：$cleanMsg',
          revision: nextRev,
        ));
      }
      rethrow;
    }
  }
}
