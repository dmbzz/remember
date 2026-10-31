import 'dart:async';
import '../../core/orientation_capsule.dart';
import 'package:flutter/material.dart';
import '../../core/motion.dart';
import '../../core/course_palette.dart';
import '../../core/study_section.dart';
import '../../data/api_client.dart';
import '../../data/course_store.dart';
import '../schedule/schedule_store.dart';
import '../schedule/timetable_layout.dart';
import '../../platform/course_reminder_bridge.dart';
import '../../data/upload_queue.dart';
import '../../platform/recording_bridge.dart';
import 'auto_recording_schedule.dart';
import 'recording_sync_panel.dart';
import '../asr/asr_settings_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  int _elapsedMs = 0;
  int _amplitude = 0;

  StreamSubscription<RecordingStatus>? _statusSub;

  String _selectedCourse = '工程力学';
  final List<String> _courses = [];
  final Map<String, String> _courseIds = {};

  // 课表到点自动录音联动状态
  bool _autoRecordEnabled = false;
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
    unawaited(_loadAutoPreference());
    unawaited(_refreshSetup());
    unawaited(widget.uploadQueue.reconnect(widget.recordingBridge));
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    await widget.recordingBridge.checkPermissions();
  }

  Future<void> _assignRecordingCourse(UploadItem item) async {
    final course = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('选择这段录音的课程'),
              children: [
                for (final course in _courseIds.entries)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, course.value),
                      child: Text(course.key))
              ],
            ));
    if (course != null) widget.uploadQueue.assignCourse(item.id, course);
  }

  Future<void> _loadAutoPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(AutoRecordingSchedule.enabledKey) ?? false;
    if (mounted) {
      setState(() => _autoRecordEnabled = enabled);
      unawaited(_loadScheduleAndArmAlarms());
    }
  }

  Future<void> _toggleAuto(bool value) async {
    final revision = ++_autoToggleRevision;
    final prefs = await SharedPreferences.getInstance();
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
    await prefs.setBool(AutoRecordingSchedule.enabledKey, value);
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
      unawaited(_refreshSetup());
      unawaited(_loadScheduleAndArmAlarms());
    }
  }

  Future<void> _refreshSetup() async {
    final setup = await CourseReminderBridge.status();
    if (mounted) setState(() => _setup = setup);
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

  void _listenStatus() {
    void update(RecordingStatus status) {
      if (mounted) {
        setState(() {
          _isRecording = status.isRecording;
          _isPaused = status.isPaused;
          _elapsedMs = status.elapsedMs;
          _amplitude = status.amplitude;
          if (status.courseId != null) _activeCourseId = status.courseId;
        });
      }
    }

    _statusSub = widget.recordingBridge.statusStream().listen(update);
    unawaited(widget.recordingBridge.getStatus().then(update));
  }

  Future<void> _toggleStart() async {
    if (_isRecording) return;
    final courseId = _courseIds[_selectedCourse];
    if (courseId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在课表首页导入课程')));
      return;
    }

    // 先校验权限
    final p = await widget.recordingBridge.requestPermissions();
    if (!mounted) return;
    if (!p.recordAudio) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要麦克风录音权限才能开始')),
      );
      return;
    }

    try {
      _activeCourseId = courseId;
      await widget.recordingBridge.startRecording(
        courseId: courseId,
        scheduleEntryId: 'sched_${DateTime.now().weekday}',
      );
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _isPaused = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启动录音失败: $e')),
      );
    }
  }

  Future<void> _stop() async {
    if (!_isRecording) return;

    final res = await widget.recordingBridge.stopRecording();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isPaused = false;
    });

    if (res.success && res.filePath.isNotEmpty) {
      // 自动入队待上传队列
      widget.uploadQueue.enqueue(
        filePath: res.filePath,
        courseId:
            res.courseId ?? _activeCourseId ?? _courseIds[_selectedCourse]!,
        lesson: 1,
        classDate:
            res.classDate ?? DateTime.now().toIso8601String().substring(0, 10),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '录音已保存在手机（${res.durationMs ~/ 1000}秒）。连接电脑后重试上传，电脑确认收到后才删除手机文件。')),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('录音'),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16 + StudyDockContentInset.of(context), 16,
            16, 20 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          children: [
            // 课程与当前状态
            StudySection(
              tone: CoursePalette.of(context, _selectedCourse).line,
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      value: _courseIds.containsKey(_selectedCourse)
                          ? _selectedCourse
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '录音课程'),
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
                    if (_courses.isNotEmpty && _usingCachedCourses)
                      const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('使用手机已保存的课程，可离线录音。')),
                    const SizedBox(height: 24),
                    // 录音时长计时器
                    Text(
                      _formatDuration(_elapsedMs),
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: _isRecording
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedSwitcher(
                      duration: StudyMotion.quick(context),
                      child: Text(
                        _isRecording
                            ? (_isPaused ? '录音已暂停' : '正在录音中 · 锁屏时仍会继续')
                            : (_elapsedMs > 0
                                ? '上次录音已结束，请查看下方同步状态'
                                : '选择课程后，点击下方按钮开始录音'),
                        key: ValueKey('$_isRecording-$_isPaused'),
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 振幅指示器
                    LinearProgressIndicator(
                      value: _isRecording
                          ? (_amplitude / 32767.0).clamp(0.05, 1.0)
                          : 0.0,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(.08),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _isRecording
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    // 操作按钮
                    AnimatedSwitcher(
                      duration: StudyMotion.quick(context),
                      child: Row(
                        key: ValueKey(_isRecording),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (!_isRecording)
                            FilledButton.icon(
                              onPressed: _toggleStart,
                              icon: const Icon(Icons.mic),
                              label: const Text('开始上课录音'),
                            )
                          else ...[
                            IconButton.filledTonal(
                              tooltip: _isPaused ? '继续录音' : '暂停录音',
                              onPressed: () {
                                if (_isPaused) {
                                  widget.recordingBridge.resumeRecording();
                                } else {
                                  widget.recordingBridge.pauseRecording();
                                }
                              },
                              icon: Icon(
                                  _isPaused ? Icons.play_arrow : Icons.pause),
                              iconSize: 28,
                            ),
                            const SizedBox(width: 16),
                            FilledButton.icon(
                              onPressed: _stop,
                              icon: const Icon(Icons.stop),
                              label: const Text('停止并同步'),
                            ),
                          ],
                        ],
                      ),
                    ),
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
                              '课程表到点自动录音',
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
                            '自动录音服务：${_setup['armed'] == true ? '已布防，可按缓存课表触发' : '尚未布防或已被系统停止'}'),
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
