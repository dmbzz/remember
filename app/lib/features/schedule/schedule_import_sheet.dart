import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/api_client.dart';
import '../../platform/schedule_file_picker.dart';

class ScheduleImportSheet extends StatefulWidget {
  final ApiClient api;
  final DateTime semesterStart;
  const ScheduleImportSheet(
      {super.key, required this.api, required this.semesterStart});
  @override
  State<ScheduleImportSheet> createState() => _ScheduleImportSheetState();
}

class _ScheduleImportSheetState extends State<ScheduleImportSheet> {
  late DateTime _start = widget.semesterStart;
  late final _semester = TextEditingController(
      text: '${_start.year}${_start.month >= 7 ? '秋' : '春'}');
  ScheduleFile? _file;
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _semester.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await ScheduleFilePicker.pick();
      if (mounted && file != null) setState(() => _file = file);
    } catch (e) {
      if (mounted) setState(() => _error = '选择文件失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _date() async {
    final date = await showDatePicker(
        context: context,
        initialDate: _start,
        firstDate: DateTime(2020),
        lastDate: DateTime(2040),
        helpText: '选择第一教学周的周一');
    if (date != null && mounted) {
      setState(() => _start = date.subtract(Duration(days: date.weekday - 1)));
    }
  }

  Future<void> _import() async {
    if (_file == null || _semester.text.trim().isEmpty) {
      setState(() => _error = '请选择 .ics 文件并填写学期');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api.importSchedule(
        filename: _file!.name,
        bytes: _file!.bytes,
        semester: _semester.text.trim(),
        semesterStart: _start.toIso8601String().substring(0, 10));
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _error = result.error;
        _busy = false;
      });
      return;
    }
    final data = result.data!;
    final added = (data['entries_count'] as num?)?.toInt() ?? 0;
    final skipped = (data['skipped'] as List?)?.length ?? 0;
    if (added == 0 && skipped == 0) {
      setState(() {
        _busy = false;
        _error = '文件中没有可导入的课程，请确认导出的是课表日历';
      });
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'cna_semester_start', _start.toIso8601String().substring(0, 10));
    if (mounted) {
      Navigator.pop(context, '导入完成：新增 $added 条课表，跳过 $skipped 条重复');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: SafeArea(
          child: SingleChildScrollView(
              child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      24, 24, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('导入课表',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 12),
                        const Text('支持 .ics 日历文件。可从课表应用导出，也可以先将文件发送到手机或电脑。'),
                        const SizedBox(height: 20),
                        OutlinedButton.icon(
                            onPressed: _busy ? null : _pick,
                            icon: const Icon(Icons.folder_open),
                            label: Text(_file?.name ?? '选择 .ics 文件')),
                        const SizedBox(height: 16),
                        TextField(
                            controller: _semester,
                            enabled: !_busy,
                            maxLength: 24,
                            decoration: const InputDecoration(
                                labelText: '学期', hintText: '例如：2026秋')),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('第一教学周的周一'),
                            subtitle:
                                Text(_start.toIso8601String().substring(0, 10)),
                            trailing: const Icon(Icons.edit_calendar),
                            onTap: _busy ? null : _date),
                        const Text('合并导入：保留已有课表，跳过重复条目。选好开学日期后，才能正确计算单双周。'),
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(_error!,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                            onPressed: _busy ? null : _import,
                            icon: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.file_download_outlined),
                            label: Text(_busy ? '正在处理…' : '导入课表')),
                      ])))));
}
