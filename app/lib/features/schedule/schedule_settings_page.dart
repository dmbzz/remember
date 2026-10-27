import 'dart:io';
import 'package:flutter/material.dart';
import '../../data/api_client.dart';
import '../../core/weeks.dart';
import '../../platform/schedule_widget_bridge.dart';
import '../../platform/recording_bridge.dart';
import '../recording/auto_recording_schedule.dart';
import 'schedule_preferences.dart';
import 'schedule_store.dart';
import 'timetable_layout.dart';

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _clock(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay _tod(String s) {
  final m = timeMinutes(s) ?? 480;
  return TimeOfDay(hour: m ~/ 60, minute: m % 60);
}

class ScheduleSettingsPage extends StatefulWidget {
  const ScheduleSettingsPage(
      {super.key, required this.api, required this.snapshot});
  final ApiClient api;
  final ScheduleSnapshot snapshot;
  @override
  State<ScheduleSettingsPage> createState() => _ScheduleSettingsPageState();
}

class _ScheduleSettingsPageState extends State<ScheduleSettingsPage> {
  late ScheduleSnapshot _saved = widget.snapshot;
  late final _label = TextEditingController(text: _saved.termLabel);
  late DateTime _start = _saved.semesterStart;
  late int _weeks = _saved.preferences.semesterWeeks;
  late bool _odd = _saved.preferences.firstWeekOdd;
  late String _defaultRule = _saved.preferences.defaultRule;
  late List<LessonSlot> _slots = List.of(_saved.preferences.slots);
  bool _dirty = false, _busy = false, _apply = true, _fresh = true;
  int _tab = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _label.addListener(_markDirty);
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _exit() async {
    if (_busy) return;
    if (_dirty) {
      final leave = await showDialog<bool>(
          context: context,
          builder: (c) =>
              AlertDialog(title: const Text('放弃未保存的作息修改？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('继续编辑')),
                TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('放弃修改'))
              ]));
      if (leave != true || !mounted) return;
    }
    Navigator.pop(context);
  }

  void _resize(int count) {
    setState(() {
      while (_slots.length < count) {
        final previous = timeMinutes(_slots.last.end)!;
        final a = (previous + 10).clamp(0, 1380),
            b = (previous + 55).clamp(0, 1425);
        String fmt(int m) =>
            '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
        _slots.add(LessonSlot(_slots.length + 1, fmt(a), fmt(b)));
      }
      _slots = _slots.take(count).toList();
      _dirty = true;
    });
  }

  Future<void> _time(int index, bool start) async {
    final slot = _slots[index];
    final picked = await showTimePicker(
        context: context,
        initialTime: _tod(start ? slot.start : slot.end),
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (picked != null && mounted) {
      setState(() {
        _slots[index] = LessonSlot(
            index + 1,
            start ? _clock(picked) : slot.start,
            start ? slot.end : _clock(picked));
        _dirty = true;
      });
    }
  }

  String? _validate() {
    if (_label.text.trim().isEmpty) return '请填写课表名称';
    if (_start.weekday != 1) return '第一教学周的起始日期请选择周一';
    var previous = -1;
    for (final s in _slots) {
      final a = timeMinutes(s.start), b = timeMinutes(s.end);
      if (a == null || b == null || b <= a) {
        return '第 ${s.number} 节的结束时间必须晚于开始时间';
      }
      if (a < previous) return '第 ${s.number} 节与前一节重叠，请调整时间';
      previous = b;
    }
    return null;
  }

  Future<void> _refresh() async {
    final snapshot = await ScheduleStore.load(widget.api);
    if (snapshot.offline) throw StateError(snapshot.error ?? '课表同步未完成');
    if (mounted) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      setState(() {
        _saved = snapshot;
        _fresh = true;
        if (!_dirty) {
          _label.removeListener(_markDirty);
          _label.text = snapshot.termLabel;
          _label.addListener(_markDirty);
          _start = snapshot.semesterStart;
          _weeks = snapshot.preferences.semesterWeeks;
          _odd = snapshot.preferences.firstWeekOdd;
          _defaultRule = snapshot.preferences.defaultRule;
          _slots = List.of(snapshot.preferences.slots);
        }
      });
    }
    await ScheduleWidgetBridge.sync(snapshot.toJson());
    if (Platform.isAndroid) {
      await AutoRecordingSchedule.sync(widget.api, AndroidRecordingBridge(),
          snapshot: snapshot);
    }
  }

  Future<void> _save() async {
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    final error = _validate();
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final prefs = SchedulePreferences(
        slots: List.of(_slots),
        semesterWeeks: _weeks,
        firstWeekOdd: _odd,
        defaultRule: _defaultRule);
    final settings = {
      ...prefs.toJson(),
      'semester_start': _date(_start),
      'term_label': _label.text.trim()
    };
    final result = await widget.api.saveSchedulePreferences({
      'revision': _saved.revision,
      'settings': settings,
      'apply_to_entries': _apply
    });
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.error ?? '保存失败')));
      setState(() {
        _busy = false;
        _error = result.error;
        _fresh = false;
      });
      return;
    }
    setState(() {
      _dirty = false;
      _fresh = false;
      _saved = ScheduleSnapshot(
          entries: _saved.entries,
          semesterStart: _start,
          updatedAt: DateTime.now(),
          termLabel: _label.text.trim(),
          preferences: prefs,
          revision: (result.data!['revision'] as num).toInt(),
          configured: true);
    });
    var message = '作息已保存，调整了 ${result.data!['updated_entries'] ?? 0} 条匹配的排课';
    try {
      await _refresh();
    } catch (_) {
      message = '作息已保存，课表或提醒刷新未完成，请返回课表重试同步';
      if (mounted) setState(() => _error = message);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _edit([Map<String, dynamic>? entry]) async {
    setState(() => _error = null);
    final courses = await widget.api.getCourses();
    if (!mounted) return;
    if (!courses.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(courses.error ?? '课程读取失败，请重试')));
      setState(() => _error = courses.error);
      return;
    }
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _EntryEditor(
                api: widget.api,
                snapshot: _saved,
                courses: courses.data!,
                entry: entry)));
    if (changed == true) {
      try {
        await _refresh();
      } catch (_) {
        if (mounted) setState(() => _error = '排课已保存，刷新失败，请返回课表同步');
      }
    }
  }

  Widget _notice(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(text,
          style: TextStyle(color: Theme.of(context).colorScheme.error)));
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exit();
      },
      child: Scaffold(
          appBar: AppBar(
              title: const Text('设定课表'), leading: BackButton(onPressed: _exit)),
          body: SafeArea(
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Column(children: [
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: SegmentedButton<int>(
                                segments: const [
                                  ButtonSegment(
                                      value: 0,
                                      icon: Icon(Icons.schedule),
                                      label: Text('作息设置')),
                                  ButtonSegment(
                                      value: 1,
                                      icon: Icon(Icons.edit_calendar_outlined),
                                      label: Text('课程安排'))
                                ],
                                selected: {
                                  _tab
                                },
                                onSelectionChanged: _busy
                                    ? null
                                    : (v) {
                                        if (_dirty && v.first == 1) {
                                          setState(
                                              () => _error = '请先保存作息设置，再安排课程');
                                          return;
                                        }
                                        setState(() {
                                          _tab = v.first;
                                          _error = null;
                                        });
                                      })),
                        Expanded(
                            child: ListView(
                                padding: EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    24 +
                                        MediaQuery.viewInsetsOf(context)
                                            .bottom),
                                children: [
                              if (_saved.offline)
                                _notice('当前离线，可查看已缓存的设置；连接电脑后再保存。'),
                              if (_error != null) _notice(_error!),
                              if (_saved.offline || !_fresh)
                                TextButton.icon(
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新同步课表'),
                                    onPressed: _busy
                                        ? null
                                        : () async {
                                            setState(() => _busy = true);
                                            try {
                                              await _refresh();
                                              if (mounted) {
                                                setState(() => _error = null);
                                              }
                                            } catch (e) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(const SnackBar(
                                                        content: Text(
                                                            '课表同步未完成，请检查电脑连接')));
                                              }
                                            } finally {
                                              if (mounted) {
                                                setState(() => _busy = false);
                                              }
                                            }
                                          }),
                              if (_tab == 0) ...[
                                TextField(
                                    controller: _label,
                                    maxLength: 16,
                                    enabled: !_busy,
                                    decoration: const InputDecoration(
                                        labelText: '课表名称')),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('第一教学周的周一'),
                                    subtitle: Text(_date(_start)),
                                    trailing: const Icon(
                                        Icons.calendar_today_outlined),
                                    onTap: _busy
                                        ? null
                                        : () async {
                                            final picked = await showDatePicker(
                                                context: context,
                                                initialDate: _start.subtract(
                                                    Duration(
                                                        days: _start.weekday -
                                                            1)),
                                                firstDate: DateTime(2020),
                                                lastDate: DateTime(2100),
                                                selectableDayPredicate: (d) =>
                                                    d.weekday == 1,
                                                helpText: '第一教学周的周一');
                                            if (picked != null && mounted) {
                                              setState(() {
                                                _start = picked;
                                                _dirty = true;
                                              });
                                            }
                                          }),
                                const SizedBox(height: 16),
                                DropdownButtonFormField<int>(
                                    value: _weeks,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: '学期总周数'),
                                    items: [
                                      for (var w = 1; w <= 30; w++)
                                        DropdownMenuItem(
                                            value: w, child: Text('$w 周'))
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(() {
                                              _weeks = v!;
                                              _dirty = true;
                                            })),
                                const SizedBox(height: 20),
                                DropdownButtonFormField<int>(
                                    key: const ValueKey('daily-slot-count'),
                                    value: _slots.length,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: '每天的节次数量'),
                                    items: [
                                      for (var i = 1; i <= 20; i++)
                                        DropdownMenuItem(
                                            value: i, child: Text('每天 $i 节'))
                                    ],
                                    onChanged:
                                        _busy ? null : (v) => _resize(v!)),
                                const SizedBox(height: 16),
                                Text('各节上课时间',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 8),
                                for (var i = 0; i < _slots.length; i++)
                                  Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 12),
                                      child: Wrap(
                                          spacing: 12,
                                          runSpacing: 8,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text('第 ${i + 1} 节'),
                                            OutlinedButton(
                                                key: ValueKey(
                                                    'slot-${i + 1}-start'),
                                                onPressed: _busy
                                                    ? null
                                                    : () => _time(i, true),
                                                child: Text(
                                                    '开始 ${_slots[i].start}')),
                                            OutlinedButton(
                                                key: ValueKey(
                                                    'slot-${i + 1}-end'),
                                                onPressed: _busy
                                                    ? null
                                                    : () => _time(i, false),
                                                child: Text(
                                                    '结束 ${_slots[i].end}')),
                                          ])),
                                const SizedBox(height: 12),
                                SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('第1教学周按单周计算'),
                                    subtitle: Text(
                                        _odd ? '第1、3、5…周为单周' : '第1、3、5…周为双周'),
                                    value: _odd,
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(() {
                                              _odd = v;
                                              _dirty = true;
                                            })),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                    value: _defaultRule,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: '新增排课的默认周次规则'),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'every', child: Text('每周')),
                                      DropdownMenuItem(
                                          value: 'odd', child: Text('单周')),
                                      DropdownMenuItem(
                                          value: 'even', child: Text('双周'))
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(() {
                                              _defaultRule = v!;
                                              _dirty = true;
                                            })),
                                const SizedBox(height: 12),
                                const Text(
                                    '单双周从第一教学周计算。以上规则用于新建或重新选择周次；已有课程保留已选周次，具体课程可单独修改。'),
                                CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _apply,
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(() {
                                              _apply = v!;
                                              _dirty = true;
                                            }),
                                    title: const Text('同步调整匹配旧作息的已有课程'),
                                    subtitle: const Text(
                                        '只调整起止时间正好对应旧节次的排课，自定义时间保持。减少节数前请先调整被移除节次的课程。')),
                                const SizedBox(height: 16),
                                FilledButton(
                                    key: const ValueKey(
                                        'save-timetable-settings'),
                                    onPressed:
                                        _busy || _saved.offline ? null : _save,
                                    child: Text(_busy ? '正在保存…' : '保存作息设置')),
                              ] else ...[
                                FilledButton.icon(
                                    onPressed:
                                        _busy || _saved.offline || !_fresh
                                            ? null
                                            : () => _edit(),
                                    icon: const Icon(Icons.add),
                                    label: const Text('新增排课')),
                                const SizedBox(height: 16),
                                if (_saved.entries.isEmpty)
                                  const Text('还没有课程，点击“新增排课”单独安排。'),
                                for (final e in _saved.entries)
                                  Card(
                                      child: ListTile(
                                          title: Text('${e['course_name']}'),
                                          subtitle: Text('周${[
                                            '一',
                                            '二',
                                            '三',
                                            '四',
                                            '五',
                                            '六',
                                            '日'
                                          ][((e['weekday'] as num?)?.toInt() ?? 1).clamp(1, 7) - 1]} · ${e['start_time'] ?? '待定'}—${e['end_time'] ?? '待定'}\n${WeeksFormatter.describe(e['weeks'], firstWeekOdd: _saved.preferences.firstWeekOdd)} · ${e['location'] ?? ''}'),
                                          trailing:
                                              const Icon(Icons.edit_outlined),
                                          onTap: _saved.offline || !_fresh
                                              ? null
                                              : () => _edit(e))),
                              ]
                            ]))
                      ]))))));
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor(
      {required this.api,
      required this.snapshot,
      required this.courses,
      this.entry});
  final ApiClient api;
  final ScheduleSnapshot snapshot;
  final List<Map<String, dynamic>> courses;
  final Map<String, dynamic>? entry;
  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final SchedulePreferences _prefs = widget.snapshot.preferences;
  late final _name = TextEditingController();
  late final _room =
      TextEditingController(text: widget.entry?['location']?.toString() ?? '');
  String? _courseId, _error;
  bool _new = false, _busy = false, _customTime = false;
  int _day = 1, _first = 1, _last = 1, _from = 1, _to = 30;
  String _rule = 'every', _startTime = '08:15', _endTime = '09:00';
  Set<int> _selected = {};
  @override
  void initState() {
    super.initState();
    _courseId = widget.entry?['course_id']?.toString();
    if (!widget.courses.any((c) => c['id'] == _courseId)) {
      _courseId = null;
      if (widget.entry != null) _error = '原课程已不可用，请明确选择课程或新建课程';
    }
    if (widget.entry == null) {
      _courseId ??= widget.courses.isEmpty
          ? null
          : widget.courses.first['id']?.toString();
    }
    _new = widget.entry == null && _courseId == null;
    _day = (widget.entry?['weekday'] as num?)?.toInt() ?? 1;
    final a =
        _prefs.slots.indexWhere((s) => s.start == widget.entry?['start_time']);
    final b =
        _prefs.slots.indexWhere((s) => s.end == widget.entry?['end_time']);
    _first = a < 0 ? 1 : a + 1;
    _last = b < a || b < 0 ? _first : b + 1;
    _customTime = widget.entry != null && (a < 0 || b < 0 || b < a);
    _startTime = widget.entry?['start_time']?.toString() ??
        _prefs.slots[_first - 1].start;
    _endTime =
        widget.entry?['end_time']?.toString() ?? _prefs.slots[_last - 1].end;
    _to = _prefs.semesterWeeks;
    _rule = _prefs.defaultRule;
    if (widget.entry != null) {
      _selected = WeeksFormatter.normalize(widget.entry!['weeks']).toSet();
      if (_selected.isEmpty) _selected = {for (var i = 1; i <= _to; i++) i};
      final sorted = _selected.toList()..sort();
      _from = sorted.first.clamp(1, _to);
      final end = sorted.last.clamp(1, _to);
      _to = end;
      _rule = 'custom';
    } else {
      _applyRule();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _room.dispose();
    super.dispose();
  }

  void _applyRule() {
    if (_rule != 'custom') {
      _selected = _prefs.weeksFor(_rule, _from, _to).toSet();
    }
  }

  Future<void> _pickTime(bool start) async {
    final picked = await showTimePicker(
        context: context,
        initialTime: _tod(start ? _startTime : _endTime),
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (picked != null && mounted) {
      setState(() {
        if (start) {
          _startTime = _clock(picked);
        } else {
          _endTime = _clock(picked);
        }
      });
    }
  }

  Future<void> _save() async {
    final weeks = _selected.toList()..sort();
    final start = _customTime ? _startTime : _prefs.slots[_first - 1].start;
    final end = _customTime ? _endTime : _prefs.slots[_last - 1].end;
    String? error;
    if (_new ? _name.text.trim().isEmpty : _courseId == null) {
      error = '请选择课程或填写新课程名称';
    }
    if (weeks.isEmpty || weeks.any((w) => w < 1 || w > _prefs.semesterWeeks)) {
      error = '请至少选择一个本学期内的有效周次';
    }
    if (timeMinutes(start) == null ||
        timeMinutes(end) == null ||
        timeMinutes(end)! <= timeMinutes(start)!) error = '结束时间必须晚于开始时间';
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api.saveManualSchedule({
      'revision': widget.snapshot.revision,
      if (widget.entry != null) 'entry_id': widget.entry!['id'],
      if (_new) 'course_name': _name.text.trim() else 'course_id': _courseId,
      'weekday': _day,
      'start_slot': _first,
      'end_slot': _last,
      if (_customTime) ...{'start_time': start, 'end_time': end},
      'location': _room.text.trim(),
      'weeks': weeks
    });
    if (!mounted) return;
    if (result.ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.error ?? '保存排课失败')));
    }
  }

  Widget _number(String label, int value, int max, ValueChanged<int> changed) =>
      DropdownButtonFormField<int>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (var i = 1; i <= max; i++)
              DropdownMenuItem(value: i, child: Text('$i'))
          ],
          onChanged: _busy ? null : (v) => changed(v!));
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: Scaffold(
          appBar: AppBar(title: Text(widget.entry == null ? '新增排课' : '修改排课')),
          body: SafeArea(
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: ListView(
                          padding: EdgeInsets.fromLTRB(20, 8, 20,
                              24 + MediaQuery.viewInsetsOf(context).bottom),
                          children: [
                            if (_error != null)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('新建课程'),
                                value: _new,
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _new = v)),
                            if (_new)
                              TextField(
                                  controller: _name,
                                  maxLength: 128,
                                  enabled: !_busy,
                                  decoration:
                                      const InputDecoration(labelText: '课程名称'))
                            else
                              DropdownButtonFormField<String>(
                                  value: _courseId,
                                  isExpanded: true,
                                  decoration:
                                      const InputDecoration(labelText: '选择课程'),
                                  items: [
                                    for (final c in widget.courses)
                                      DropdownMenuItem(
                                          value: '${c['id']}',
                                          child: Text('${c['name']}',
                                              overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _courseId = v)),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<int>(
                                value: _day,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '上课星期'),
                                items: [
                                  for (var i = 1; i <= 7; i++)
                                    DropdownMenuItem(
                                        value: i,
                                        child: Text('星期${[
                                          '一',
                                          '二',
                                          '三',
                                          '四',
                                          '五',
                                          '六',
                                          '日'
                                        ][i - 1]}'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() => _day = v!)),
                            const SizedBox(height: 20),
                            _number(
                                '开始节次',
                                _first,
                                _prefs.slots.length,
                                (v) => setState(() {
                                      _first = v;
                                      if (_last < v) _last = v;
                                    })),
                            const SizedBox(height: 16),
                            _number(
                                '结束节次',
                                _last,
                                _prefs.slots.length,
                                (v) => setState(() {
                                      _last = v;
                                      if (_first > v) _first = v;
                                    })),
                            const SizedBox(height: 12),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('单独设置本课时间'),
                                subtitle: Text(_customTime
                                    ? '$_startTime—$_endTime'
                                    : '${_prefs.slots[_first - 1].start}—${_prefs.slots[_last - 1].end}'),
                                value: _customTime,
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() {
                                          if (v && !_customTime) {
                                            _startTime =
                                                _prefs.slots[_first - 1].start;
                                            _endTime =
                                                _prefs.slots[_last - 1].end;
                                          }
                                          _customTime = v;
                                        })),
                            if (_customTime)
                              Wrap(spacing: 12, children: [
                                OutlinedButton(
                                    onPressed:
                                        _busy ? null : () => _pickTime(true),
                                    child: Text('开始 $_startTime')),
                                OutlinedButton(
                                    onPressed:
                                        _busy ? null : () => _pickTime(false),
                                    child: Text('结束 $_endTime'))
                              ]),
                            const SizedBox(height: 16),
                            TextField(
                                controller: _room,
                                maxLength: 128,
                                enabled: !_busy,
                                decoration: const InputDecoration(
                                    labelText: '教室 / 地点')),
                            const SizedBox(height: 12),
                            _number(
                                '开始周',
                                _from,
                                _prefs.semesterWeeks,
                                (v) => setState(() {
                                      _from = v;
                                      if (_to < v) _to = v;
                                      _applyRule();
                                    })),
                            const SizedBox(height: 16),
                            _number(
                                '结束周',
                                _to,
                                _prefs.semesterWeeks,
                                (v) => setState(() {
                                      _to = v;
                                      if (_from > v) _from = v;
                                      _applyRule();
                                    })),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                                key: const ValueKey('entry-week-rule'),
                                value: _rule,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '上课周次规则'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'every', child: Text('每周')),
                                  DropdownMenuItem(
                                      value: 'odd', child: Text('单周')),
                                  DropdownMenuItem(
                                      value: 'even', child: Text('双周')),
                                  DropdownMenuItem(
                                      value: 'custom', child: Text('自选周次'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() {
                                          _rule = v!;
                                          _applyRule();
                                        })),
                            const SizedBox(height: 12),
                            Text(
                                '已选：${WeeksFormatter.compress(_selected.toList())}'),
                            Wrap(spacing: 6, runSpacing: 6, children: [
                              for (var w = 1; w <= _prefs.semesterWeeks; w++)
                                FilterChip(
                                    label: Text('第 $w 周'),
                                    selected: _selected.contains(w),
                                    onSelected: _busy
                                        ? null
                                        : (v) => setState(() {
                                              _rule = 'custom';
                                              if (v) {
                                                _selected.add(w);
                                              } else {
                                                _selected.remove(w);
                                              }
                                            }))
                            ]),
                            const SizedBox(height: 20),
                            FilledButton(
                                key: const ValueKey('save-manual-schedule'),
                                onPressed: _busy ? null : _save,
                                child: Text(_busy ? '正在保存…' : '保存排课')),
                          ]))))));
}
