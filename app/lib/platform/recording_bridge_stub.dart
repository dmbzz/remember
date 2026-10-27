import 'dart:async';
import 'recording_bridge.dart';

/// 桌面端与测试桩降级实现（不崩溃、模拟录音状态）
class StubRecordingBridge implements RecordingBridge {
  bool _isRecording = false;
  int _elapsed = 0;
  Timer? _timer;
  final StreamController<RecordingEvent> _controller =
      StreamController<RecordingEvent>.broadcast();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<PermissionStatus> checkPermissions() async {
    return const PermissionStatus(
      recordAudio: true,
      notifications: true,
      foregroundService: true,
      batteryUnrestricted: true,
      autoStartEnabled: true,
    );
  }

  @override
  Future<PermissionStatus> requestPermissions() async {
    return checkPermissions();
  }

  @override
  Future<void> openAutoStartSettings() async {}

  @override
  Future<void> openBatterySettings() async {}

  @override
  Future<RecordingStartResult> startRecording({
    required String courseId,
    required String scheduleEntryId,
    String codec = 'aac',
  }) async {
    _isRecording = true;
    _elapsed = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      _elapsed += 1000;
      _controller.add(
        RecordingEvent(
          type: 'status',
          payload: RecordingStatus(
            isRecording: true,
            isPaused: false,
            sessionId: 'stub_session',
            elapsedMs: _elapsed,
            amplitude: 1500,
          ),
        ),
      );
    });

    return RecordingStartResult(
      sessionId: 'stub_${DateTime.now().millisecondsSinceEpoch}',
      filePath: '/tmp/stub_audio.$codec',
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      codec: codec,
    );
  }

  @override
  Future<void> pauseRecording() async {}

  @override
  Future<void> resumeRecording() async {}

  @override
  Future<RecordingResult> stopRecording() async {
    _isRecording = false;
    _timer?.cancel();
    return RecordingResult(
      sessionId: 'stub_session',
      filePath: '/tmp/stub_audio.aac',
      durationMs: _elapsed,
      sizeBytes: _elapsed * 16,
      success: true,
    );
  }

  @override
  Future<void> cancelRecording() async {
    _isRecording = false;
    _timer?.cancel();
  }

  @override
  Future<RecordingStatus> getStatus() async {
    return RecordingStatus(
      isRecording: _isRecording,
      isPaused: false,
      sessionId: _isRecording ? 'stub_session' : null,
      elapsedMs: _elapsed,
      amplitude: _isRecording ? 1200 : 0,
    );
  }

  @override
  Stream<RecordingStatus> statusStream() {
    return eventStream()
        .where((e) => e.type == 'status')
        .map((e) => e.payload as RecordingStatus);
  }

  @override
  Stream<RecordingEvent> eventStream() => _controller.stream;

  @override
  Future<bool> syncScheduleAlarms(List<Map<String, dynamic>> alarms) async => true;

  @override
  Future<List<Map<String, dynamic>>> listRecordingFiles() async => [];

  @override
  Future<bool> installApk(String filePath) async => true;
}
