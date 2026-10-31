import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/study_section.dart';
import '../../core/course_palette.dart';
import '../../core/motion.dart';
import '../../core/shapes.dart';
import '../../core/pressable_card.dart';
import '../../core/weeks.dart';
import '../../data/api_client.dart';
import '../../data/course_store.dart';
import 'dart:convert';
import '../../platform/schedule_widget_bridge.dart';
import 'schedule_store.dart';
import 'schedule_settings_page.dart';
import 'timetable_grid.dart';
import 'schedule_anchor_view.dart';
import 'timetable_layout.dart';
import 'schedule_import_sheet.dart';
import '../recording/auto_recording_schedule.dart';
import '../../platform/recording_bridge.dart';

class SchedulePage extends StatefulWidget {
  final ApiClient apiClient;
  final DateTime? referenceDate;
  const SchedulePage({super.key, required this.apiClient, this.referenceDate});
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage>
    with WidgetsBindingObserver {
  ScheduleSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  int? _week;
  final Set<String> _saving = {};
  bool? _dayMode;
  int? _selectedDay;
  bool _wideLayout = false;
  List<LessonSlot> get _slots => _snapshot?.preferences.slots ?? schoolSlots;
  bool _layoutInitialized = false;
  Map<String, dynamic>? _selectedEntry;
  DateTime get _today => widget.referenceDate ?? DateTime.now();
  int get _currentWeek =>
      teachingWeek(_today, _snapshot?.semesterStart ?? DateTime(2026, 8, 31));
  int get _viewWeek => _week ?? _currentWeek.clamp(1, 30);
  List<Map<String, dynamic>> get _visible => (_snapshot?.entries ?? [])
      .where((e) =>
          _viewWeek <= (_snapshot?.preferences.semesterWeeks ?? 30) &&
          appearsInWeek(e, _viewWeek))
      .toList();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      if (_snapshot == null) {
        final cached = await ScheduleStore.cached();
        if (!mounted) return;
        if (cached != null) {
          setState(() {
            _snapshot = cached;
            _loading = false;
          });
        }
      }
      final snapshot = await ScheduleStore.load(widget.apiClient);
      if (!mounted) return;
      setState(() {
        final selectedId = _selectedEntry?['id']?.toString();
        Map<String, dynamic>? currentSelection;
        if (selectedId != null) {
          for (final entry in snapshot.entries) {
            if (entry['id']?.toString() == selectedId) {
              currentSelection = entry;
              break;
            }
          }
        }
        _snapshot = snapshot;
        _selectedEntry = currentSelection;
        _loading = false;
        _error = null;
      });
      try {
        await ScheduleWidgetBridge.sync(snapshot.toJson());
        if (Platform.isAndroid) {
          await AutoRecordingSchedule.sync(
              widget.apiClient, AndroidRecordingBridge(),
              snapshot: snapshot);
        }
      } catch (_) {
        if (mounted && Platform.isAndroid) {
          setState(() => _error = '桌面课表或录音排期刷新失败，请重试同步');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _pickWeek() async {
    final selected = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
            child: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('选择教学周',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 16),
                          Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: List.generate(
                                  _snapshot?.preferences.semesterWeeks ?? 30,
                                  (index) => ChoiceChip(
                                      label: Text('第 ${index + 1} 周'),
                                      selected: _viewWeek == index + 1,
                                      onSelected: (_) =>
                                          Navigator.pop(context, index + 1)))),
                        ])))));
    if (selected != null && mounted) setState(() => _week = selected);
  }

  Future<void> _import() async {
    final message = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => ScheduleImportSheet(
            api: widget.apiClient,
            semesterStart: _snapshot?.semesterStart ?? DateTime(2026, 8, 31)));
    if (message != null && mounted) {
      await _load();
      if (Platform.isAndroid) {
        try {
          await AutoRecordingSchedule.sync(
              widget.apiClient, AndroidRecordingBridge());
        } catch (_) {/* 录音页可以再次布防并展示权限原因。 */}
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  Future<void> _pinWidget() async {
    if (_snapshot == null) return;
    try {
      await ScheduleWidgetBridge.sync(_snapshot!.toJson());
      final accepted = await ScheduleWidgetBridge.pin();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(accepted
              ? '请在桌面的系统提示中确认添加'
              : '桌面长按 → 添加小部件 → 安卓小部件 → Remember·课表')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }

  Future<void> _settings() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ScheduleSettingsPage(
                api: widget.apiClient, snapshot: snapshot)));
    if (mounted) await _load();
  }

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime date) =>
      '${date.year}年${date.month}月${date.day}日';

  Future<void> _contextMenu(Map<String, dynamic> entry, Offset position) async {
    final action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(position.dx, position.dy, 0, 0),
        items: const [
          PopupMenuItem(value: 'move', child: Text('调课到…')),
          PopupMenuItem(value: 'detail', child: Text('查看课程详情')),
        ]);
    if (!mounted) return;
    if (action == 'move') await _reschedule(entry);
    if (action == 'detail') _open(entry);
  }

  Future<void> _reschedule(Map<String, dynamic> entry) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    if (snapshot.offline) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('电脑离线，连接后才能保存调课')));
      return;
    }
    final semesterStart = snapshot.semesterStart;
    final sourceWeek = _viewWeek;
    final weekday = ((entry['weekday'] as num?)?.toInt() ?? 1).clamp(1, 7);
    final sourceDate =
        semesterStart.add(Duration(days: (sourceWeek - 1) * 7 + weekday - 1));
    var targetWeek = sourceWeek;
    final targetDate = await showModalBottomSheet<DateTime>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => StatefulBuilder(builder: (sheet, setSheetState) {
              final weekStart =
                  semesterStart.add(Duration(days: (targetWeek - 1) * 7));
              return SafeArea(
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(sheet).height * .8),
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('调动这节课',
                                    style:
                                        Theme.of(sheet).textTheme.titleLarge),
                                const SizedBox(height: 8),
                                Text(
                                    '${entry['course_name']} · ${_displayDate(sourceDate)}'),
                                Text(
                                    '${entry['start_time'] ?? '时间待定'} — ${entry['end_time'] ?? '时间待定'} · ${entry['location'] ?? '教室待定'}'),
                                const SizedBox(height: 16),
                                DropdownButtonFormField<int>(
                                    value: targetWeek,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: '选择目标教学周'),
                                    items: List.generate(30, (index) {
                                      final first = semesterStart
                                          .add(Duration(days: index * 7));
                                      final last =
                                          first.add(const Duration(days: 6));
                                      return DropdownMenuItem(
                                          value: index + 1,
                                          child: Text(
                                              '第 ${index + 1} 周 · ${first.month}月${first.day}日—${last.month}月${last.day}日'));
                                    }),
                                    onChanged: (value) {
                                      if (value != null) {
                                        setSheetState(() => targetWeek = value);
                                      }
                                    }),
                                const SizedBox(height: 8),
                                Expanded(
                                    child: ListView.builder(
                                        itemCount: 7,
                                        itemBuilder: (context, index) {
                                          final date = weekStart
                                              .add(Duration(days: index));
                                          return ListTile(
                                              enabled: civilDate(date) !=
                                                  civilDate(sourceDate),
                                              title: Text('周${[
                                                '一',
                                                '二',
                                                '三',
                                                '四',
                                                '五',
                                                '六',
                                                '日'
                                              ][index]} · ${_displayDate(date)}'),
                                              subtitle: Text(
                                                  '${entry['start_time'] ?? '时间待定'} — ${entry['end_time'] ?? '时间待定'}'),
                                              trailing: const Icon(
                                                  Icons.chevron_right),
                                              onTap: () =>
                                                  Navigator.pop(sheet, date));
                                        })),
                              ]))));
            }));
    if (targetDate == null || !mounted) return;
    final targetTeachingWeek = teachingWeek(targetDate, semesterStart);
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: const Text('确认调课'),
                content: Text(
                    '将 ${entry['course_name']} 从第 $sourceWeek 周 ${_displayDate(sourceDate)} 调到第 $targetTeachingWeek 周 ${_displayDate(targetDate)}？\n\n${entry['start_time'] ?? '时间待定'} — ${entry['end_time'] ?? '时间待定'} · ${entry['location'] ?? '教室待定'}\n\n其他周的课程不变。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('确认调课')),
                ]));
    if (confirmed != true || !mounted) return;
    final result = await widget.apiClient.rescheduleOccurrence(
        entryId: '${entry['id']}',
        semesterStart: _isoDate(semesterStart),
        sourceDate: _isoDate(sourceDate),
        targetDate: _isoDate(targetDate));
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.error ?? '调课失败')));
      return;
    }
    setState(() => _week = targetTeachingWeek);
    await _load();
    if (Platform.isAndroid) {
      try {
        await AutoRecordingSchedule.sync(
            widget.apiClient, AndroidRecordingBridge());
      } catch (_) {/* 录音页可再次布防并显示具体权限原因。 */}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('已调到第 $targetTeachingWeek 周 ${_displayDate(targetDate)}')));
    }
  }

  void _open(Map<String, dynamic> entry) {
    if (_wideLayout) {
      setState(() => _selectedEntry = entry);
      return;
    }
    _openSheet(entry);
  }

  void _openSheet(Map<String, dynamic> entry) {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
            child: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                              width: 38,
                              height: 5,
                              margin: const EdgeInsets.only(bottom: 20),
                              decoration: BoxDecoration(
                                  color: courseColor('${entry['course_name']}'),
                                  borderRadius: BorderRadius.circular(3))),
                          Text('${entry['course_name']}',
                              style:
                                  Theme.of(context).textTheme.headlineMedium),
                          const SizedBox(height: 20),
                          _detail(
                              Icons.place_outlined,
                              '${entry['location'] ?? ''}'.isEmpty
                                  ? '教室待定'
                                  : '${entry['location']}'),
                          _detail(Icons.schedule,
                              '${entry['start_time'] ?? '时间待定'} — ${entry['end_time'] ?? '时间待定'}'),
                          _detail(
                              Icons.today_outlined,
                              _displayDate((_snapshot?.semesterStart ??
                                      DateTime(2026, 8, 31))
                                  .add(Duration(
                                      days: (_viewWeek - 1) * 7 +
                                          (((entry['weekday'] as num?)
                                                          ?.toInt() ??
                                                      1)
                                                  .clamp(1, 7) -
                                              1))))),
                          _detail(
                              Icons.date_range_outlined,
                              '周${[
                                '一',
                                '二',
                                '三',
                                '四',
                                '五',
                                '六',
                                '日'
                              ][((entry['weekday'] as num?)?.toInt() ?? 1).clamp(1, 7) - 1]} · ${WeeksFormatter.describe(entry['weeks'], firstWeekOdd: _snapshot?.preferences.firstWeekOdd ?? true)}'),
                          if ('${entry['teacher'] ?? ''}'.isNotEmpty)
                            _detail(
                                Icons.person_outline, '${entry['teacher']}'),
                          OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                unawaited(_reschedule(entry));
                              },
                              icon: const Icon(Icons.event_repeat_outlined),
                              label: const Text('调动这节课')),
                          const SizedBox(height: 12),
                          StatefulBuilder(
                              builder: (context, setSheetState) =>
                                  SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(Platform.isAndroid
                                          ? '本手机自动录音'
                                          : '这门课自动录音'),
                                      subtitle: Text(Platform.isAndroid
                                          ? '离线也可设置，还需在录音页开启布防'
                                          : '需在手机上开启录音权限'),
                                      value: entry['auto_record'] == true,
                                      onChanged: _saving
                                              .contains(entry['course_id'])
                                          ? null
                                          : (value) async {
                                              final id =
                                                  '${entry['course_id']}';
                                              _saving.add(id);
                                              setSheetState(() {});
                                              final result = Platform.isAndroid
                                                  ? null
                                                  : await widget.apiClient
                                                      .setCourseAutoRecord(
                                                          id, value);
                                              if (Platform.isAndroid) {
                                                await CourseStore
                                                    .setPhoneAutoRecord(
                                                        id, value);
                                              }
                                              _saving.remove(id);
                                              if (!context.mounted) return;
                                              if (result == null || result.ok) {
                                                for (final item in _snapshot
                                                        ?.entries ??
                                                    <Map<String, dynamic>>[]) {
                                                  if (item['course_id'] == id) {
                                                    item['auto_record'] = value;
                                                  }
                                                }
                                              } else {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(SnackBar(
                                                        content: Text(
                                                            result.error ??
                                                                '保存失败')));
                                              }
                                              if (Platform.isAndroid &&
                                                  _snapshot != null) {
                                                final prefs =
                                                    await SharedPreferences
                                                        .getInstance();
                                                await prefs.setString(
                                                    ScheduleStore.cacheKey,
                                                    jsonEncode(
                                                        _snapshot!.toJson()));
                                                try {
                                                  await ScheduleWidgetBridge
                                                      .sync(
                                                          _snapshot!.toJson());
                                                  await AutoRecordingSchedule.sync(
                                                      widget.apiClient,
                                                      AndroidRecordingBridge(),
                                                      snapshot: _snapshot);
                                                } catch (e) {
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                            context)
                                                        .showSnackBar(SnackBar(
                                                            content: Text(
                                                                '课程设置已保存，请在录音页检查布防：$e')));
                                                  }
                                                }
                                              }
                                              setSheetState(() {});
                                            })),
                        ])))));
  }

  Widget _detail(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text))
      ]));
  Widget _dayList(DateTime start) {
    final day = _selectedDay ?? _today.weekday;
    final date = start.add(Duration(days: day - 1));
    final entries = _visible.where((e) => e['weekday'] == day).toList()
      ..sort((a, b) => '${a['start_time']}'.compareTo('${b['start_time']}'));
    return ListView(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var i = 1; i <= 7; i++)
                  Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: SizedBox(
                          width: 46,
                          child: TextButton(
                            style: TextButton.styleFrom(
                                backgroundColor: day == i
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withOpacity(.12)
                                    : null),
                            onPressed: () => setState(() => _selectedDay = i),
                            child: Column(children: [
                              Text(['一', '二', '三', '四', '五', '六', '日'][i - 1]),
                              Text('${start.add(Duration(days: i - 1)).day}')
                            ]),
                          ))),
              ])),
          const SizedBox(height: 16),
          Text('${_displayDate(date)} · ${entries.length} 节课',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('这一天没有课程，可切换整周查看。')),
          for (final entry in entries) _courseRow(entry),
        ]);
  }

  Widget _courseRow(Map<String, dynamic> entry) {
    final tone = CoursePalette.of(context, '${entry['course_name']}');
    return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: PressableCard(
          onTap: () => _open(entry),
          onSecondaryTapDown: (details) =>
              _contextMenu(entry, details.globalPosition),
          child: Container(
            decoration: BoxDecoration(
                color: tone.fill.withOpacity(.35),
                border: Border(left: BorderSide(color: tone.line, width: 4))),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: 58,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${entry['start_time'] ?? '待定'}',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text('${entry['end_time'] ?? ''}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ])),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('${entry['course_name']}',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(color: tone.ink)),
                    const SizedBox(height: 5),
                    Text('${entry['location'] ?? '教室待定'}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ])),
              const SizedBox(width: 6),
              const Icon(Icons.north_east, size: 16),
            ]),
          ),
        ));
  }

  Widget _sideDetails(DateTime start) {
    final entry = _selectedEntry;
    if (entry == null || !_visible.any((e) => e['id'] == entry['id'])) {
      return Padding(
          padding: const EdgeInsets.all(24),
          child: Text('选择一节课，查看日期、时间和教室。',
              style: Theme.of(context).textTheme.bodySmall));
    }
    final tone = CoursePalette.of(context, '${entry['course_name']}');
    final date = start
        .add(Duration(days: ((entry['weekday'] as num?)?.toInt() ?? 1) - 1));
    return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Divider(color: tone.line, thickness: 3),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child:
                    Text('课程详情', style: Theme.of(context).textTheme.bodySmall)),
            IconButton(
              key: const ValueKey('schedule-close-details'),
              tooltip: '关闭课程详情',
              onPressed: _closeDetails,
              icon: const Icon(Icons.close),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${entry['course_name']}',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: tone.ink)),
          const SizedBox(height: 22),
          _detail(Icons.calendar_today_outlined, _displayDate(date)),
          _detail(Icons.schedule,
              '${entry['start_time'] ?? '待定'} — ${entry['end_time'] ?? '待定'}'),
          _detail(Icons.place_outlined, '${entry['location'] ?? '教室待定'}'),
          Wrap(spacing: 8, runSpacing: 10, children: [
            OutlinedButton(
                onPressed: () => _reschedule(entry), child: const Text('调课到…')),
            OutlinedButton(
                onPressed: () => _openSheet(entry),
                child: const Text('这门课自动录音')),
          ]),
          const SizedBox(height: 18),
          Text(entry['auto_record'] == true ? '自动录音已开启，仍需手机权限与布防。' : '自动录音未开启。',
              style: Theme.of(context).textTheme.bodySmall),
        ]));
  }

  void _closeDetails() {
    if (_selectedEntry != null) setState(() => _selectedEntry = null);
  }

  Widget _courseSurface(DateTime start, bool dayMode) {
    return LayoutBuilder(builder: (context, box) {
      final showDetails = _wideLayout &&
          _selectedEntry != null &&
          _visible.any((entry) => entry['id'] == _selectedEntry!['id']);
      final detailsKey = ValueKey('course-details-${_selectedEntry?['id']}');
      final width = math.min(box.maxWidth - 24,
          320 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6));
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeDetails
        },
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
              child: GestureDetector(
            key: const ValueKey('schedule-course-backdrop'),
            behavior: HitTestBehavior.translucent,
            onTap: _closeDetails,
            child: Platform.isWindows
                ? ScheduleAnchorView(
                    entries: _visible,
                    slots: _slots,
                    weekStart: start,
                    today: _today,
                    selectedDay: _selectedDay ?? _today.weekday,
                    dayMode: dayMode,
                    selectedEntryId: _selectedEntry?['id']?.toString(),
                    onSelectDay: (day) => setState(() {
                          _selectedDay = day;
                          _selectedEntry = null;
                        }),
                    onOpen: _open,
                    onSecondaryTap: _contextMenu)
                : dayMode
                    ? _dayList(start)
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TimetableGrid(
                            entries: _visible,
                            slots: _slots,
                            weekStart: start,
                            today: _today,
                            onOpen: _open,
                            onSecondaryTap: _contextMenu)),
          )),
          Positioned(
            top: 12,
            right: 12,
            width: math.max(1, width),
            child: AnimatedSwitcher(
              duration: StudyMotion.quick(context),
              reverseDuration: StudyMotion.quick(context),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topRight,
                children: [...previous, if (current != null) current],
              ),
              transitionBuilder: (child, animation) => IgnorePointer(
                ignoring: !showDetails || child.key != detailsKey,
                child: ExcludeSemantics(
                  excluding: !showDetails || child.key != detailsKey,
                  child: FadeTransition(opacity: animation, child: child),
                ),
              ),
              child: showDetails
                  ? ConstrainedBox(
                      key: detailsKey,
                      constraints: BoxConstraints(
                          maxHeight: math.max(1, box.maxHeight - 24)),
                      child: Material(
                        key: const ValueKey('schedule-floating-details'),
                        color: Theme.of(context).colorScheme.surface,
                        elevation: MediaQuery.highContrastOf(context) ? 0 : 4,
                        shadowColor: Colors.black.withOpacity(.15),
                        shape: RoundedRectangleBorder(
                          borderRadius: StudyShapes.cardBorder,
                          side: BorderSide(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _sideDetails(start),
                      ),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('course-details-hidden')),
            ),
          ),
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final start = (_snapshot?.semesterStart ?? DateTime(2026, 8, 31))
        .add(Duration(days: (_viewWeek - 1) * 7));
    final weekday =
        ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][_today.weekday - 1];
    final invalid = _visible.where((e) => !fitsGrid(e, slots: _slots)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('课表'), actions: [
        PopupMenuButton<String>(
          tooltip: '课表设置',
          onSelected: (v) {
            if (v == 'refresh') _load();
            if (v == 'name') _settings();
            if (v == 'today') setState(() => _week = null);
            if (v == 'widget') _pinWidget();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'refresh', child: Text('同步课表')),
            const PopupMenuItem(value: 'today', child: Text('回到本周')),
            const PopupMenuItem(value: 'name', child: Text('设定课表')),
            if (Platform.isAndroid)
              const PopupMenuItem(value: 'widget', child: Text('添加 2×2 桌面课表'))
          ],
        )
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _snapshot == null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error ?? '无法加载课表'),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('重试'))
                      ])))
              : LayoutBuilder(builder: (context, box) {
                  final wide = box.maxWidth >= 850;
                  // A manual choice applies to this window width band. Crossing
                  // the breakpoint restores the adaptive view in either direction.
                  if (Platform.isWindows &&
                      _layoutInitialized &&
                      _wideLayout != wide) {
                    _dayMode = null;
                  }
                  _wideLayout = wide;
                  _layoutInitialized = true;
                  final dayMode = _dayMode ?? !_wideLayout;
                  final headingTitle = '第 $_viewWeek 周 · $weekday';
                  final headingSubtitle =
                      '${start.year}.${start.month}.${start.day} — ${start.add(const Duration(days: 6)).month}.${start.add(const Duration(days: 6)).day}';
                  return Column(children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                        child: StudyHeading(
                          title: headingTitle,
                          subtitle: headingSubtitle,
                          trailing: OutlinedButton.icon(
                              onPressed: _import,
                              icon: const Icon(Icons.file_upload_outlined),
                              label: const Text('导入课表')),
                        )),
                    Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: 14,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SegmentedButton<bool>(
                                  segments: const [
                                    ButtonSegment(
                                        value: true, label: Text('当天')),
                                    ButtonSegment(
                                        value: false, label: Text('整周'))
                                  ],
                                  selected: {
                                    dayMode
                                  },
                                  showSelectedIcon: false,
                                  onSelectionChanged: (values) =>
                                      setState(() => _dayMode = values.first)),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                    tooltip: '上一周',
                                    onPressed: _viewWeek > 1
                                        ? () => setState(
                                            () => _week = _viewWeek - 1)
                                        : null,
                                    icon: const Icon(Icons.chevron_left)),
                                TextButton(
                                    onPressed: _pickWeek,
                                    child: Text(
                                        '${start.month}.${start.day} — ${start.add(const Duration(days: 6)).month}.${start.add(const Duration(days: 6)).day}')),
                                IconButton(
                                    tooltip: '下一周',
                                    onPressed: _viewWeek < 30
                                        ? () => setState(
                                            () => _week = _viewWeek + 1)
                                        : null,
                                    icon: const Icon(Icons.chevron_right)),
                              ]),
                            ])),
                    if (_snapshot!.offline || _error != null)
                      Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(children: [
                            const Icon(Icons.cloud_off_outlined, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(
                                    _error ??
                                        '离线课表 · 上次同步 ${_snapshot!.updatedAt.month}/${_snapshot!.updatedAt.day}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall)),
                            TextButton(
                                onPressed: _load, child: const Text('重试'))
                          ])),
                    if (invalid.isNotEmpty)
                      TextButton(
                          onPressed: () => showModalBottomSheet(
                              context: context,
                              builder: (sheet) => SafeArea(
                                      child:
                                          ListView(shrinkWrap: true, children: [
                                    for (final entry in invalid)
                                      ListTile(
                                          title:
                                              Text('${entry['course_name']}'),
                                          subtitle: Text(
                                              '${entry['start_time'] ?? '时间待定'} — ${entry['end_time'] ?? '时间待定'}'),
                                          onTap: () {
                                            Navigator.pop(sheet);
                                            _open(entry);
                                          })
                                  ]))),
                          child: Text('${invalid.length} 条课程在网格外或时间待完善，点击查看')),
                    if (!dayMode || Platform.isWindows)
                      Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: ExcludeSemantics(
                                  excluding: dayMode,
                                  child: Opacity(
                                      opacity: dayMode ? 0 : 1,
                                      child: Text(
                                          Platform.isWindows
                                              ? '${_slots.length} 小节 · 向下滚动查看后续课程'
                                              : '${_slots.length} 小节 · 左右滑动查看整周课表',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall))))),
                    Expanded(child: _courseSurface(start, dayMode)),
                  ]);
                }),
    );
  }
}
