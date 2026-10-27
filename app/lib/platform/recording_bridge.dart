import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../core/constants.dart';

/// 录音启动结果
class RecordingStartResult {
  final String sessionId; // 会话 ID（与后端 Recording.id 对应）
  final String filePath; // 原生侧录音文件绝对路径（.wav 或 .m4a）
  final int startedAtMs; // 起始时间戳（epoch ms）
  final String codec; // 'wav' | 'aac'

  const RecordingStartResult({
    required this.sessionId,
    required this.filePath,
    required this.startedAtMs,
    required this.codec,
  });

  factory RecordingStartResult.fromMap(Map<dynamic, dynamic> map) {
    return RecordingStartResult(
      sessionId: map['sessionId'] as String? ?? '',
      filePath: map['filePath'] as String? ?? '',
      startedAtMs:
          map['startedAtMs'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      codec: map['codec'] as String? ?? 'aac',
    );
  }
}

/// 录音落盘完成结果
class RecordingResult {
  final String sessionId;
  final String filePath;
  final int durationMs;
  final int sizeBytes;
  final bool success;
  final String? error;
  final String? courseId;
  final String? classDate;

  const RecordingResult({
    required this.sessionId,
    required this.filePath,
    required this.durationMs,
    required this.sizeBytes,
    required this.success,
    this.error,
    this.courseId,
    this.classDate,
  });

  factory RecordingResult.fromMap(Map<dynamic, dynamic> map) {
    return RecordingResult(
      sessionId: map['sessionId'] as String? ?? '',
      filePath: map['filePath'] as String? ?? '',
      durationMs: map['durationMs'] as int? ?? 0,
      sizeBytes: map['sizeBytes'] as int? ?? 0,
      success: map['success'] as bool? ?? false,
      error: map['error'] as String?,
      courseId: map['courseId'] as String?,
      classDate: map['classDate'] as String?,
    );
  }
}

/// 录音状态快照
class RecordingStatus {
  final bool isRecording;
  final bool isPaused;
  final String? sessionId;
  final int elapsedMs;
  final int amplitude; // 0..32767，用于录音动画
  final String? courseId;
  final bool isArmed;

  const RecordingStatus({
    required this.isRecording,
    required this.isPaused,
    this.sessionId,
    required this.elapsedMs,
    required this.amplitude,
    this.courseId,
    this.isArmed = false,
  });

  factory RecordingStatus.fromMap(Map<dynamic, dynamic> map) {
    return RecordingStatus(
      isRecording: map['isRecording'] as bool? ?? false,
      isPaused: map['isPaused'] as bool? ?? false,
      sessionId: map['sessionId'] as String?,
      elapsedMs: map['elapsedMs'] as int? ?? 0,
      amplitude: map['amplitude'] as int? ?? 0,
      courseId: map['courseId'] as String?,
      isArmed: map['isArmed'] == true,
    );
  }
}

/// 原生权限与白名单状态
class PermissionStatus {
  final bool recordAudio;
  final bool notifications;
  final bool foregroundService;
  final bool batteryUnrestricted; // 是否已加入电池优化白名单
  final bool autoStartEnabled; // 是否已开启自启动

  const PermissionStatus({
    required this.recordAudio,
    required this.notifications,
    required this.foregroundService,
    required this.batteryUnrestricted,
    required this.autoStartEnabled,
  });

  factory PermissionStatus.fromMap(Map<dynamic, dynamic> map) {
    return PermissionStatus(
      recordAudio: map['recordAudio'] as bool? ?? false,
      notifications: map['notifications'] as bool? ?? false,
      foregroundService: map['foregroundService'] as bool? ?? false,
      batteryUnrestricted: map['batteryUnrestricted'] as bool? ?? false,
      autoStartEnabled: map['autoStartEnabled'] as bool? ?? false,
    );
  }
}

/// 录音事件类型
class RecordingEvent {
  final String type; // 'amplitude' | 'error' | 'serviceKilled' | 'autoStopped'
  final dynamic payload;

  const RecordingEvent({required this.type, this.payload});
}

/// 原生 Platform Channel 录音桥接抽象接口（架构设计 §1.6.1）
abstract class RecordingBridge {
  Future<bool> isAvailable();
  Future<PermissionStatus> checkPermissions();
  Future<PermissionStatus> requestPermissions();
  Future<void> openAutoStartSettings();
  Future<void> openBatterySettings();
  Future<RecordingStartResult> startRecording({
    required String courseId,
    required String scheduleEntryId,
    String codec = 'aac',
  });
  Future<void> pauseRecording();
  Future<void> resumeRecording();
  Future<RecordingResult> stopRecording();
  Future<void> cancelRecording();
  Future<RecordingStatus> getStatus();
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> alarms);
  Future<List<Map<String, dynamic>>> listRecordingFiles();
  Future<bool> installApk(String filePath);
  Stream<RecordingStatus> statusStream();
  Stream<RecordingEvent> eventStream();
}

/// Android 平台原生 Channel 实际实现类
class AndroidRecordingBridge implements RecordingBridge {
  static const MethodChannel _methodChannel =
      MethodChannel(AppConstants.channelAudioRecorder);
  static const EventChannel _eventChannel =
      EventChannel(AppConstants.channelAudioEvents);

  Stream<RecordingEvent>? _eventStreamCache;

  @override
  Future<bool> isAvailable() async {
    return Platform.isAndroid;
  }

  @override
  Future<PermissionStatus> checkPermissions() async {
    if (!Platform.isAndroid) {
      return const PermissionStatus(
        recordAudio: false,
        notifications: false,
        foregroundService: false,
        batteryUnrestricted: false,
        autoStartEnabled: false,
      );
    }
    final res = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('checkPermissions');
    return PermissionStatus.fromMap(res ?? {});
  }

  @override
  Future<PermissionStatus> requestPermissions() async {
    if (!Platform.isAndroid) {
      return checkPermissions();
    }
    final res = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('requestPermissions');
    return PermissionStatus.fromMap(res ?? {});
  }

  @override
  Future<void> openAutoStartSettings() async {
    if (Platform.isAndroid) {
      await _methodChannel.invokeMethod('openAutoStartSettings');
    }
  }

  @override
  Future<void> openBatterySettings() async {
    if (Platform.isAndroid) {
      await _methodChannel.invokeMethod('openBatterySettings');
    }
  }

  @override
  Future<RecordingStartResult> startRecording({
    required String courseId,
    required String scheduleEntryId,
    String codec = 'aac',
  }) async {
    final res = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'startRecording',
      {
        'courseId': courseId,
        'scheduleEntryId': scheduleEntryId,
        'codec': codec,
      },
    );
    return RecordingStartResult.fromMap(res ?? {});
  }

  @override
  Future<void> pauseRecording() async {
    await _methodChannel.invokeMethod('pauseRecording');
  }

  @override
  Future<void> resumeRecording() async {
    await _methodChannel.invokeMethod('resumeRecording');
  }

  @override
  Future<RecordingResult> stopRecording() async {
    final res = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('stopRecording');
    return RecordingResult.fromMap(res ?? {});
  }

  @override
  Future<void> cancelRecording() async {
    await _methodChannel.invokeMethod('cancelRecording');
  }

  @override
  Future<RecordingStatus> getStatus() async {
    final res =
        await _methodChannel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
    return RecordingStatus.fromMap(res ?? {});
  }

  @override
  Stream<RecordingStatus> statusStream() {
    return eventStream()
        .where((e) => e.type == 'status')
        .map((e) => e.payload as RecordingStatus);
  }

  @override
  Stream<RecordingEvent> eventStream() {
    _eventStreamCache ??= _eventChannel
        .receiveBroadcastStream()
        .map<RecordingEvent>((dynamic event) {
      if (event is Map) {
        final type = event['type'] as String? ?? 'unknown';
        final payload = event['payload'];
        if (type == 'status' && payload is Map) {
          return RecordingEvent(
              type: type, payload: RecordingStatus.fromMap(payload));
        }
        return RecordingEvent(type: type, payload: payload);
      }
      return RecordingEvent(type: 'raw', payload: event);
    });
    return _eventStreamCache!;
  }

  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> alarms) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _methodChannel
          .invokeMethod<bool>('syncScheduleAlarms', {'alarms': alarms});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _methodChannel
          .invokeMethod<bool>('installApk', {'filePath': filePath});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listRecordingFiles() async {
    if (!Platform.isAndroid) return [];
    final value = await _methodChannel
        .invokeListMethod<Map<dynamic, dynamic>>('listRecordingFiles');
    return (value ?? []).map((item) => item.cast<String, dynamic>()).toList();
  }
}
