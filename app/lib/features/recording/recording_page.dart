import 'dart:async';
import '../../core/orientation_capsule.dart';
import 'package:flutter/material.dart';
import '../../core/motion.dart';
import '../../core/course_palette.dart';
import '../../core/shapes.dart';
import '../../core/study_section.dart';
import '../../data/api_client.dart';
import '../../data/course_store.dart';
import '../schedule/schedule_store.dart';
import '../schedule/timetable_layout.dart';
import '../../platform/course_reminder_bridge.dart';
import '../../data/upload_queue.dart';
import '../../platform/recording_bridge.dart';
import '../../platform/local_recording_actions.dart';
import 'auto_recording_schedule.dart';
import 'recording_sync_panel.dart';
import 'recording_timer.dart';
import '../asr/asr_settings_entry.dart';

/// 课堂录音与后台保活设置页面（最高风险点 FR-03 UI）
class RecordingPage extends StatefulWidget {
  final RecordingBridge recordingBridge;
  final UploadQueue uploadQueue;
  final ApiClient? apiClient;

  const RecordingPage({
    super.key,
    required this.recordingBridge,
    required this.uploadQueue,
    this.apiClient,
  });

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage>
    with WidgetsBindingObserver {
  bool _isRecording = false;
  bool _isPaused = false;
  bool _recordingBusy = false;
  int _elapsedMs = 0;
  int _amplitude = 0;

  // 定时录音配置与当前会话倒计时状态
  RecordingTimerConfig _timerConfig = const RecordingTimerConfig();
  int? _activeDurationLimitMs;
  int? _remainingMs;
  String? _activeLimitAction;
  bool _limitTriggered = false;
  bool _lastCountdownStopped = false;

  StreamSubscription<RecordingStatus>? _statusSub;
  StreamSubscription<RecordingEvent>? _eventSub;

  String _selectedCourse = '工程力学';
  final List<String> _courses = [];
  final Map<String, String> _courseIds = {};

  // 课表到点自动录音联动状态
  bool _autoRecordEnabled = false;
  bool _autoRecordArmed = false;
  Map<String, dynamic>? _nextClass;
  bool _syncingSchedule = false;
  bool _scheduleSyncPending = false;
  Future<void>? _scheduleSync;
  int _autoToggleRevision = 0;
  bool _usingCachedCourses = true;
  String? _activeCourseId;
  Map<String, dynamic> _setup = {};

  /// 最近一次课表同步的失败原因（非 null 表示上次同步失败，含实际 URL）。
  String? _lastScheduleSyncError;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadCourses();
    _listenStatus();
    WidgetsBinding.instance.addObserver(this);
    final shared = AutoRecordingSchedule.stateNotifier.value;
    _autoRecordEnabled = shared.enabled;
    _autoRecordArmed = shared.armed;
    _syncingSchedule = shared.syncing;
    AutoRecordingSchedule.stateNotifier.addListener(_onSharedAutoChanged);
    unawaited(_loadAutoPreference());
    unawaited(_loadTimerPreference());
    unawaited(_refreshSetup());
    unawaited(widget.uploadQueue.reconnect(widget.recordingBridge));
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _eventSub?.cancel();
    AutoRecordingSchedule.stateNotifier.removeListener(_onSharedAutoChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onSharedAutoChanged() {
    if (!mounted) return;
    final shared = AutoRecordingSchedule.stateNotifier.value;
    setState(() {
      _autoRecordEnabled = shared.enabled;
      _autoRecordArmed = shared.armed;
      _syncingSchedule = shared.syncing;
      if (!shared.syncing && shared.error != null) {
        _lastScheduleSyncError = shared.error;
      } else if (!shared.syncing && shared.error == null) {
        _lastScheduleSyncError =
            shared.enabled && shared.scheduledCount == 0
                ? '剩余学期没有开启自动录音的课程；请在课程详情中打开开关'
                : null;
      }
    });
    if (!shared.syncing) {
      unawaited(_refreshSetup());
    }
  }

  Future<void> _loadTimerPreference() async {
    final loaded = await RecordingTimerConfig.load();
    if (mounted) {
      setState(() => _timerConfig = loaded);
    }
  }

  void _updateTimerConfig(RecordingTimerConfig next) {
    setState(() => _timerConfig = next);
    unawaited(next.save());
  }

  Future<void> _pickCustomDuration() async {
    if (_isRecording) return;
    final minutes = await showCustomRecordingDurationDialog(
      context,
      initialMinutes: _timerConfig.durationMinutes,
    );
    if (!mounted || minutes == null) return;
    _updateTimerConfig(_timerConfig.copyWith(durationMinutes: minutes));
  }

  Future<void> _checkPermissions() async {
    await widget.recordingBridge.checkPermissions();
  }

  Future<void> _assignRecordingCourse(UploadItem item) async {
    final api = widget.apiClient;
    if (api == null) return;
    final revision = api.connectionRevision;
    final result = await api.getCourses();
    if (!mounted || revision != api.connectionRevision) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.error ?? '无法读取当前电脑的课程')));
      return;
    }
    final courses = result.data ?? <Map<String, dynamic>>[];
    final course = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('选择这段录音的课程'),
              children: [
                for (final course in courses)
                  SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, course['id'] as String),
                      child: Text('${course['name']}'))
              ],
            ));
    if (course != null && revision == api.connectionRevision) {
      widget.uploadQueue.assignCourse(item.id, course);
    }
  }

  Future<void> _loadAutoPreference() async {
    final enabled = await AutoRecordingSchedule.loadEnabled();
    if (mounted) {
      setState(() => _autoRecordEnabled = enabled);
      unawaited(_loadScheduleAndArmAlarms());
    }
  }

  Future<void> _toggleAuto(bool value) async {
    final revision = ++_autoToggleRevision;
    if (value) {
      final permission = await widget.recordingBridge.requestPermissions();
      if (!permission.recordAudio || !permission.notifications) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('请先允许麦克风和通知权限')));
        }
        return;
      }
    }
    if (!mounted || revision != _autoToggleRevision) return;
    setState(() => _autoRecordEnabled = value);
    await AutoRecordingSchedule.setEnabled(value);
    await _loadScheduleAndArmAlarms();
  }

  void _applyCourses(List<Map<String, dynamic>> courses,
      {required bool cached}) {
    if (!mounted || courses.isEmpty) return;
    final ids = <String, String>{};
    for (final course in courses) {
      final name = '${course['name'] ?? ''}'.trim();
      final id = '${course['id'] ?? ''}'.trim();
      if (name.isEmpty || id.isEmpty) continue;
      final label =
          ids.containsKey(name) && ids[name] != id ? '$name · $id' : name;
      ids[label] = id;
    }
    setState(() {
      _usingCachedCourses = cached;
      _courses
        ..clear()
        ..addAll(ids.keys);
      _courseIds
        ..clear()
        ..addAll(ids);
      if (ids.isNotEmpty && !ids.containsKey(_selectedCourse)) {
        _selectedCourse = ids.keys.first;
      }
    });
  }

  Future<void> _loadCourses() async {
    _applyCourses(await CourseStore.cached(), cached: true);
    final result = await widget.apiClient?.getCourses();
    if (result?.ok != true) return;
    final courses = result!.data ?? <Map<String, dynamic>>[];
    await CourseStore.save(courses);
    _applyCourses(courses, cached: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.recordingBridge.getStatus().then(_applyStatus));
      unawaited(widget.uploadQueue.recoverLocalRecordings(widget.recordingBridge));
      unawaited(_refreshSetup());
      unawaited(_loadScheduleAndArmAlarms());
    }
  }

  Future<void> _refreshSetup() async {
    final setup = await CourseReminderBridge.status();
    final armed = await AutoRecordingSchedule.refreshArmed(widget.recordingBridge);
    if (mounted) {
      setState(() {
        _setup = setup;
        _autoRecordArmed = setup['armed'] == true || armed;
      });
    }
  }

  Future<void> _testReminder() async {
    try {
      await widget.recordingBridge.requestPermissions();
      await CourseReminderBridge.refresh();
      await CourseReminderBridge.test();
      await _refreshSetup();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('测试通知已发送，请查看通知栏；展开可看教室和上课时间')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _applyStatus(RecordingStatus status) {
    if (!mounted) return;
    setState(() {
      _isRecording = status.isRecording;
      _isPaused = status.isPaused;
      _elapsedMs = status.elapsedMs;
      _amplitude = status.amplitude;
      _activeDurationLimitMs = status.durationLimitMs;
      _remainingMs = status.remainingMs;
      _activeLimitAction = status.limitAction;
      _limitTriggered = status.limitTriggered;
      if (status.isRecording) _lastCountdownStopped = false;
      if (status.courseId != null) _activeCourseId = status.courseId;
    });
  }

  void _listenStatus() {
    _statusSub = widget.recordingBridge.statusStream().listen(_applyStatus);
    _eventSub = widget.recordingBridge.eventStream().listen((event) {
      if (!mounted) return;
      if (event.type == 'countdownPaused') {
        setState(() {
          _isPaused = true;
          _limitTriggered = true;
          _remainingMs = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已到达定时时长，录音已自动暂停。可点击继续录音，或点击“停止并同步”。'),
          ),
        );
      } else if (event.type == 'autoStopped' && event.payload is Map) {
        final payload = (event.payload as Map).cast<String, dynamic>();
        if (payload['reason'] == 'countdown') {
          final durationMs = (payload['durationMs'] as num?)?.toInt() ?? 0;
          setState(() {
            _isRecording = false;
            _isPaused = false;
            _elapsedMs = durationMs;
            _activeDurationLimitMs = null;
            _remainingMs = null;
            _activeLimitAction = null;
            _limitTriggered = false;
            _lastCountdownStopped = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '定时录音已到点自动停止（${_formatDuration(durationMs)}），已加入同步队列。'),
            ),
          );
        }
      } else if (event.type == 'error' && event.payload is Map) {
        final msg = (event.payload as Map)['message']?.toString();
        if (msg != null && msg.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('录音操作异常：$msg')),
          );
        }
      }
    });
    unawaited(widget.recordingBridge.getStatus().then(_applyStatus));
  }

  Future<void> _toggleStart() async {
    if (_isRecording || _recordingBusy) return;
    final courseId = _courseIds[_selectedCourse];
    if (courseId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在课表首页导入课程')));
      return;
    }

    setState(() => _recordingBusy = true);
    try {
      // 先校验权限
      final p = await widget.recordingBridge.requestPermissions();
      if (!mounted) return;
      if (!p.recordAudio) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要麦克风录音权限才能开始')),
        );
        return;
      }

      _activeCourseId = courseId;
      final limitMs = _timerConfig.durationLimitMs;
      final limitAction =
          _timerConfig.isTimed ? _timerConfig.action.wireValue : null;
      await widget.recordingBridge.startRecording(
        courseId: courseId,
        scheduleEntryId: 'sched_${DateTime.now().weekday}',
        durationLimitMs: limitMs,
        limitAction: limitAction,
      );
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _isPaused = false;
        _elapsedMs = 0;
        _activeDurationLimitMs = limitMs;
        _remainingMs = limitMs;
        _activeLimitAction = limitAction;
        _limitTriggered = false;
        _lastCountdownStopped = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启动录音失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Future<void> _stop() async {
    if (!_isRecording || _recordingBusy) return;
    setState(() => _recordingBusy = true);
    try {
      final res = await widget.recordingBridge.stopRecording();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isPaused = false;
        _activeDurationLimitMs = null;
        _remainingMs = null;
        _activeLimitAction = null;
        _limitTriggered = false;
        _lastCountdownStopped = false;
      });

      if (res.success && res.filePath.isNotEmpty) {
        // 自动入队待上传队列
        widget.uploadQueue.enqueue(
          filePath: res.filePath,
          durationMs: res.durationMs,
          courseId:
              res.courseId ?? _activeCourseId ?? _courseIds[_selectedCourse]!,
          lesson: 1,
          classDate: res.classDate ??
              DateTime.now().toIso8601String().substring(0, 10),
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '录音已保存在手机（${res.durationMs ~/ 1000}秒）。连接电脑后重试上传，电脑确认收到后才删除手机文件。')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('停止录音失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Future<void> _discard() async {
    if (!_isRecording || _recordingBusy) return;
    setState(() => _recordingBusy = true);
    try {
      final status = await widget.recordingBridge.getStatus();
      final sessionId = status.sessionId;
      if (!status.isRecording || sessionId == null || sessionId.isEmpty) {
        throw StateError('当前录音已结束，请在录音记录中查看');
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('停止并删除这次录音？'),
                scrollable: true,
                content: const Text('将停止当前录音并永久删除手机文件，不会加入同步队列，无法恢复。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('继续录音')),
                  TextButton(
                      style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('停止并删除')),
                ],
              ));
      if (confirmed != true) return;
      await LocalRecordingActions.discardSession(sessionId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('本次录音已删除，不会同步到电脑')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('未能删除录音：$e')));
      }
    } finally {
      // A failed delete may have stopped the recorder but retained the file.
      // Recover the native discard flag without allowing an automatic upload.
      try {
        final status = await widget.recordingBridge.getStatus();
        if (mounted) {
          setState(() {
            _isRecording = status.isRecording;
            _isPaused = status.isPaused;
            _activeDurationLimitMs = status.durationLimitMs;
            _remainingMs = status.remainingMs;
            _activeLimitAction = status.limitAction;
            _limitTriggered = status.limitTriggered;
            if (!status.isRecording) _lastCountdownStopped = false;
          });
        }
        await widget.uploadQueue.recoverLocalRecordings(widget.recordingBridge);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('录音状态刷新失败，请重新打开录音页：$e')));
        }
      } finally {
        if (mounted) setState(() => _recordingBusy = false);
      }
    }
  }

  String _formatDuration(int ms) {
    final totalSec = ms ~/ 1000;
    final sec = totalSec % 60;
    final min = (totalSec ~/ 60) % 60;
    final hr = totalSec ~/ 3600;
    if (hr > 0) {
      return '${hr.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _recordingStatusText() {
    if (_isRecording) {
      if (_isPaused) {
        if (_limitTriggered) return '已达到定时时长，录音已自动暂停';
        if (_activeDurationLimitMs != null) return '录音已暂停 · 倒计时已暂停';
        return '录音已暂停';
      }
      if (_limitTriggered) return '正在录音中 · 已超过原定时长，需手动停止';
      if (_activeDurationLimitMs != null) {
        return '正在定时录音 · 锁屏时仍会继续';
      }
      return '正在录音中 · 锁屏时仍会继续';
    }
    if (_lastCountdownStopped) {
      return '定时录音已到点自动停止，请查看下方同步状态';
    }
    if (_elapsedMs > 0) {
      return '上次录音已结束，请查看下方同步状态';
    }
    return '选择课程后，点击下方按钮开始录音';
  }

  Widget _animatedCollapse(BuildContext context, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return AnimatedSize(
      duration: StudyMotion.quickDuration,
      curve: StudyMotion.standardCurve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _buildTimerChip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: selected,
      showCheckmark: true,
      checkmarkColor: colors.primary,
      backgroundColor: colors.surfaceContainerLow,
      selectedColor: colors.primaryContainer.withOpacity(.6),
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
        width: selected ? 1.5 : 1.0,
      ),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? colors.primary : colors.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      onSelected: (_) => onSelected(),
    );
  }

  Widget _buildTimerSelector(BuildContext context) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final iconSize = (18.0 * textScale.clamp(1.0, 1.5)).roundToDouble();
    final customLabel = _timerConfig.isCustomDuration
        ? '自定义 · ${RecordingTimerConfig.formatMinutes(_timerConfig.durationMinutes!)}'
        : '自定义';

    return Column(
      key: const Key('recording-timer-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: iconSize,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '定时录音',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Text(
                _timerConfig.summaryLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _timerConfig.isTimed
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight:
                      _timerConfig.isTimed ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildTimerChip(
              key: const Key('timer-preset-unlimited'),
              label: '不限时',
              selected: !_timerConfig.isTimed,
              onSelected: () => _updateTimerConfig(
                _timerConfig.copyWith(clearDuration: true),
              ),
            ),
            for (final minutes in RecordingTimerConfig.presetMinutes)
              _buildTimerChip(
                key: Key('timer-preset-$minutes'),
                label: RecordingTimerConfig.presetLabel(minutes),
                selected: _timerConfig.durationMinutes == minutes,
                onSelected: () => _updateTimerConfig(
                  _timerConfig.copyWith(durationMinutes: minutes),
                ),
              ),
            _buildTimerChip(
              key: const Key('timer-preset-custom'),
              label: customLabel,
              selected: _timerConfig.isCustomDuration,
              onSelected: () => unawaited(_pickCustomDuration()),
            ),
          ],
        ),
        _animatedCollapse(
          context,
          _timerConfig.isTimed
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    key: const Key('recording-timer-action-row'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '到点后',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          for (final action in RecordingTimerAction.values)
                            _buildTimerChip(
                              key: Key('timer-action-${action.wireValue}'),
                              label: action.shortLabel,
                              selected: _timerConfig.action == action,
                              onSelected: () => _updateTimerConfig(
                                _timerConfig.copyWith(action: action),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _timerConfig.action.helperText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildActiveCountdownBadge(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final action = RecordingTimerAction.fromWire(_activeLimitAction);
    final String label;
    final IconData icon;
    final Color fg;
    final Color bg;

    if (_limitTriggered && _isPaused) {
      label = '定时已到 · 已自动暂停';
      icon = Icons.pause_circle_outline;
      fg = colors.onPrimaryContainer;
      bg = colors.primaryContainer;
    } else if (_limitTriggered) {
      label = '已超原定时长 · 手动停止结束';
      icon = Icons.timer_off_outlined;
      fg = colors.onSurfaceVariant;
      bg = colors.surfaceContainerHighest;
    } else {
      final rem = _remainingMs ?? _activeDurationLimitMs ?? 0;
      label = '剩余 ${_formatDuration(rem)} · ${action.detailLabel}';
      icon = Icons.hourglass_bottom;
      fg = _isPaused ? colors.onSurfaceVariant : colors.onErrorContainer;
      bg = _isPaused ? colors.surfaceContainerHighest : colors.errorContainer;
    }

    return Container(
      key: const Key('recording-countdown-badge'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(StudyShapes.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingActionButtons(BuildContext context) {
    return AnimatedSwitcher(
      duration: StudyMotion.quick(context),
      child: Wrap(
        key: ValueKey(_isRecording),
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!_isRecording)
            FilledButton.icon(
              onPressed: _recordingBusy ? null : _toggleStart,
              icon: const Icon(Icons.mic),
              label: const Text('开始上课录音'),
            )
          else ...[
            IconButton.filledTonal(
              tooltip: _isPaused ? '继续录音' : '暂停录音',
              onPressed: _recordingBusy
                  ? null
                  : () {
                      if (_isPaused) {
                        widget.recordingBridge.resumeRecording();
                      } else {
                        widget.recordingBridge.pauseRecording();
                      }
                    },
              icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
              iconSize: 28,
            ),
            FilledButton.icon(
              onPressed: _recordingBusy ? null : _stop,
              icon: const Icon(Icons.stop),
              label: const Text('停止并同步'),
            ),
            TextButton.icon(
              onPressed: _recordingBusy ? null : _discard,
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.delete_outline),
              label: const Text('停止并删除'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final compactLandscape =
        screenSize.height < 500 && screenSize.width > screenSize.height;
    final timerReadout = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatDuration(_elapsedMs),
          style: TextStyle(
            fontSize: compactLandscape ? 34 : 42,
            fontWeight: FontWeight.bold,
            color: _isRecording
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        _animatedCollapse(
          context,
          _isRecording && _activeDurationLimitMs != null
              ? _buildActiveCountdownBadge(context)
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: StudyMotion.quick(context),
          child: Text(
            _recordingStatusText(),
            key: ValueKey(
                '$_isRecording-$_isPaused-$_limitTriggered-${_activeDurationLimitMs != null}-$_lastCountdownStopped'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13),
          ),
        ),
        SizedBox(height: compactLandscape ? 10 : 16),
        // 振幅指示器
        LinearProgressIndicator(
          value: _isRecording
              ? (_amplitude / 32767.0).clamp(0.05, 1.0)
              : 0.0,
          backgroundColor:
              Theme.of(context).colorScheme.onSurface.withOpacity(.08),
          valueColor: AlwaysStoppedAnimation<Color>(
            _isRecording
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('录音'),
        toolbarHeight: compactLandscape ? 44 : null,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16 + StudyDockContentInset.of(context),
            compactLandscape ? 10 : 16,
            16,
            20 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          children: [
            // 课程与当前状态
            StudySection(
              tone: CoursePalette.of(context, _selectedCourse).line,
              padding: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.all(compactLandscape ? 12 : 16),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      value: _courseIds.containsKey(_selectedCourse)
                          ? _selectedCourse
                          : null,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: '录音课程',
                        isDense: compactLandscape,
                      ),
                      items: _courses
                          .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: _isRecording
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => _selectedCourse = v);
                              }
                            },
                    ),
                    if (_courses.isNotEmpty &&
                        _usingCachedCourses &&
                        !compactLandscape)
                      const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('使用手机已保存的课程，可离线录音。')),
                    _animatedCollapse(
                      context,
                      _isRecording
                          ? const SizedBox.shrink()
                          : _buildTimerSelector(context),
                    ),
                    SizedBox(height: compactLandscape ? 12 : 24),
                    if (compactLandscape && _isRecording)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(flex: 5, child: timerReadout),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 4,
                            child: Center(
                              child: _buildRecordingActionButtons(context),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      timerReadout,
                      SizedBox(height: compactLandscape ? 14 : 24),
                      _buildRecordingActionButtons(context),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            if (widget.apiClient != null) ...[
              AsrSettingsEntry(
                  apiClient: widget.apiClient!, canConfigure: false),
              const SizedBox(height: 16),
            ],
            RecordingSyncPanel(
                queue: widget.uploadQueue,
                onSync: () =>
                    widget.uploadQueue.reconnect(widget.recordingBridge),
                onAssign: _assignRecordingCourse),
            const SizedBox(height: 16),

            // 课表到点自动录音联动卡片
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                            child: Row(
                          children: [
                            Icon(Icons.alarm_on,
                                color: Theme.of(context).colorScheme.onSurface),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                              '本机到点自动录音',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            )),
                          ],
                        )),
                        Switch(
                          value: _autoRecordEnabled,
                          onChanged: _toggleAuto,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                        '在课表详情中选择需要自动录音的课程。应用会提前启动前台服务；若系统停止服务，到点会通知你手动开始。'),
                    const SizedBox(height: 8),
                    Text(
                      _nextClass != null
                          ? '下一节：${_nextClass!['course_name']}\n${_nextClass!['start_time']} - ${_nextClass!['end_time']}'
                          : '今天没有课程，或尚未导入课表。可在课表页查看并同步。',
                      style: TextStyle(
                          fontSize: 15,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _syncingSchedule ? null : _onManualSync,
                            icon: const Icon(Icons.refresh, size: 18),
                            label:
                                Text(_syncingSchedule ? '正在排期...' : '刷新自动录音排期'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('课程通知与后台状态',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 8),
                        Text(
                            '课程提醒：${_setup['notifications'] == true ? '通知已允许' : '请允许通知'} · 已安排 ${_setup['scheduled'] ?? 0} 节课'),
                        Text(
                            '精确闹钟：${_setup['exactAlarms'] == true ? '已允许' : '未允许，到点提醒可能延迟'}'),
                        Text(
                            '自动录音服务：${(_setup['armed'] == true || _autoRecordArmed) ? '已布防，可按缓存课表触发' : '尚未布防或已被系统停止'}'),
                        Text(_setup['islandConfigured'] == true
                            ? '超级岛：${_setup['focusPermission'] == true ? '系统已允许' : '系统权限未确认'}'
                            : '超级岛：此安装包尚未取得小米平台授权，当前使用普通课程通知。'),
                        if (_lastScheduleSyncError != null)
                          Text(_lastScheduleSyncError!),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          const OutlinedButton(
                              onPressed: CourseReminderBridge.openExactAlarms,
                              child: Text('允许精确闹钟')),
                          const OutlinedButton(
                              onPressed: CourseReminderBridge.openNotifications,
                              child: Text('通知设置')),
                          FilledButton.tonal(
                              onPressed: _testReminder,
                              child: const Text('测试课程通知')),
                        ]),
                      ],
                    ))),
            const SizedBox(height: 16),

            // 国产 ROM 保活与白名单设置引导（架构设计 §5 / FR-03）
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield_outlined,
                            color: Theme.of(context).colorScheme.onSurface),
                        const SizedBox(width: 8),
                        Text(
                          '后台录音设置',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.onSurface),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '为降低锁屏时录音被系统终止的概率，建议开启以下两项：',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                widget.recordingBridge.openBatterySettings(),
                            child: const Text('电池优化白名单'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                widget.recordingBridge.openAutoStartSettings(),
                            child: const Text('自启动管理'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadScheduleAndArmAlarms() {
    if (widget.apiClient == null) return Future<void>.value();
    _scheduleSyncPending = true;
    return _scheduleSync ??=
        _drainScheduleSync().whenComplete(() => _scheduleSync = null);
  }

  Future<void> _drainScheduleSync() async {
    if (mounted) setState(() => _syncingSchedule = true);
    try {
      do {
        _scheduleSyncPending = false;
        await _syncScheduleOnce();
      } while (_scheduleSyncPending);
    } finally {
      if (mounted) setState(() => _syncingSchedule = false);
    }
  }

  Future<void> _syncScheduleOnce() async {
    try {
      final snapshot = await ScheduleStore.cached() ??
          await ScheduleStore.load(widget.apiClient!);
      final now = DateTime.now();
      final week = teachingWeek(now, snapshot.semesterStart);
      final items = snapshot.entries
          .where((entry) =>
              entry['weekday'] == now.weekday &&
              appearsInWeek(entry, week) &&
              (timeMinutes(entry['end_time']) ?? -1) >
                  now.hour * 60 + now.minute)
          .toList()
        ..sort((a, b) => (timeMinutes(a['start_time']) ?? 9999)
            .compareTo(timeMinutes(b['start_time']) ?? 9999));
      if (mounted) {
        setState(() {
          _nextClass = items.isEmpty ? null : items.first;
          if (!_isRecording &&
              _nextClass != null &&
              _courseIds.containsKey(_nextClass!['course_name'])) {
            _selectedCourse = _nextClass!['course_name'];
          }
        });
      }
      final count = await AutoRecordingSchedule.sync(
          widget.apiClient!, widget.recordingBridge,
          enabled: _autoRecordEnabled, snapshot: snapshot);
      _lastScheduleSyncError = _autoRecordEnabled && count == 0
          ? '剩余学期没有开启自动录音的课程；请在课程详情中打开开关'
          : null;
      await CourseReminderBridge.refresh();
      await _refreshSetup();
    } catch (e) {
      _lastScheduleSyncError = '$e';
    }
  }

  /// 用户手动同步课表：同步后按结果给出明确反馈（失败带上原因与 URL）。
  Future<void> _onManualSync() async {
    await _loadScheduleAndArmAlarms();
    if (!mounted) return;
    final err = _lastScheduleSyncError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err == null ? '录音排期已刷新' : '录音排期失败：$err')),
    );
  }
}
