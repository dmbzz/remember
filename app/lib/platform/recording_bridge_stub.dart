import 'dart:async';
import 'recording_bridge.dart';

/// 桌面端与测试桩降级实现（不崩溃、模拟录音状态）
class StubRecordingBridge implements RecordingBridge {
  bool _isRecording = false;
  bool _isPaused = false;
  int _elapsed = 0;
  String? _courseId;
  int? _durationLimitMs;
  String? _limitAction;
  bool _limitTriggered = false;
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

  RecordingStatus _snapshot() {
    final activeLimit = _isRecording ? _durationLimitMs : null;
    final remaining = activeLimit == null
        ? null
        : (activeLimit - _elapsed).clamp(0, activeLimit);
    return RecordingStatus(
      isRecording: _isRecording,
      isPaused: _isPaused,
      sessionId: _isRecording ? 'stub_session' : null,
      elapsedMs: _elapsed,
      amplitude: (_isRecording && !_isPaused) ? 1500 : 0,
      courseId: _courseId,
      durationLimitMs: activeLimit,
      remainingMs: remaining,
      limitAction: activeLimit != null ? _limitAction : null,
      limitTriggered: _isRecording && _limitTriggered,
    );
  }

  @override
  Future<RecordingStartResult> startRecording({
    required String courseId,
    required String scheduleEntryId,
    String codec = 'aac',
    int? durationLimitMs,
    String? limitAction,
  }) async {
    _isRecording = true;
    _isPaused = false;
    _elapsed = 0;
    _courseId = courseId;
    _durationLimitMs = durationLimitMs;
    _limitAction = durationLimitMs != null ? (limitAction ?? 'stop') : null;
    _limitTriggered = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_isRecording || _isPaused) return;
      _elapsed += 1000;
      if (_durationLimitMs != null &&
          !_limitTriggered &&
          _elapsed >= _durationLimitMs!) {
        _limitTriggered = true;
        if (_limitAction == 'pause') {
          _isPaused = true;
          final snap = _snapshot();
          _controller.add(RecordingEvent(type: 'status', payload: snap));
          _controller
              .add(RecordingEvent(type: 'countdownPaused', payload: snap));
          return;
        } else {
          final finalElapsed = _elapsed;
          final finalCourse = _courseId ?? '';
          _isRecording = false;
          _isPaused = false;
          _durationLimitMs = null;
          _limitAction = null;
          _limitTriggered = false;
          _timer?.cancel();
          _controller.add(RecordingEvent(type: 'autoStopped', payload: {
            'filePath': '/tmp/stub_audio.$codec',
            'courseId': finalCourse,
            'durationMs': finalElapsed,
            'classDate': DateTime.now().toIso8601String().substring(0, 10),
            'reason': 'countdown',
          }));
          _controller.add(RecordingEvent(type: 'status', payload: _snapshot()));
          return;
        }
      }
      _controller.add(
        RecordingEvent(
          type: 'status',
          payload: _snapshot(),
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
  Future<void> pauseRecording() async {
    if (!_isRecording || _isPaused) return;
    _isPaused = true;
    _controller.add(RecordingEvent(type: 'status', payload: _snapshot()));
  }

  @override
  Future<void> resumeRecording() async {
    if (!_isRecording || !_isPaused) return;
    _isPaused = false;
    _controller.add(RecordingEvent(type: 'status', payload: _snapshot()));
  }

  @override
  Future<RecordingResult> stopRecording() async {
    _isRecording = false;
    _isPaused = false;
    _durationLimitMs = null;
    _limitAction = null;
    _limitTriggered = false;
    _timer?.cancel();
    return RecordingResult(
      sessionId: 'stub_session',
      filePath: '/tmp/stub_audio.aac',
      durationMs: _elapsed,
      sizeBytes: _elapsed * 16,
      courseId: _courseId,
      success: true,
    );
  }

  @override
  Future<void> cancelRecording() async {
    _isRecording = false;
    _isPaused = false;
    _durationLimitMs = null;
    _limitAction = null;
    _limitTriggered = false;
    _timer?.cancel();
  }

  @override
  Future<RecordingStatus> getStatus() async {
    return _snapshot();
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
