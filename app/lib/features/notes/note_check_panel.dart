import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../data/note_check_controller.dart';
import 'note_file_sync_panel.dart';
import 'note_version_actions.dart';

class NoteCheckPanel extends StatelessWidget {
  const NoteCheckPanel(
      {super.key, required this.controller, this.chooseFolder});
  final NoteCheckController controller;
  final VoidCallback? chooseFolder;

  static String time(Object? value) {
    final date = DateTime.tryParse('$value');
    return date == null
        ? '未知'
        : DateFormat('M月d日 HH:mm').format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.fileSync != null) {
          return NoteFileSyncPanel(
              controller: controller.fileSync!, chooseFolder: chooseFolder);
        }
        final report =
            controller.reports.isEmpty ? null : controller.reports.first;
        final message = controller.needsFolder
            ? '先选择手机 Obsidian 库或课堂笔记目录'
            : report == null
                ? (controller.android
                    ? '连接电脑后自动核对；离线仍可读本地笔记'
                    : '尚未收到手机摘要；请在手机选择笔记目录并连接电脑')
                : '上次结果：一致 ${report['same']} 篇 · 差异 ${_differenceCount(report)} 篇';
        return Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.fact_check_outlined),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text('笔记同步核对',
                                style:
                                    Theme.of(context).textTheme.titleMedium)),
                        if (controller.checking)
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                      ]),
                      const SizedBox(height: 8),
                      Text(message),
                      if (report != null) ...[
                        const SizedBox(height: 4),
                        Text(
                            '手机摘要：${time(report['phone_checked_at'])} · 电脑核对：${time(report['computer_checked_at'])}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                      if (controller.error != null) ...[
                        const SizedBox(height: 8),
                        Text('本轮未核对成功：${controller.error}',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 6),
                      Text(
                          controller.android
                              ? '每天首次使用应用时自动核对一次；当天未成功时连回电脑补做，也可立即核对。文件传输由本 APP 执行。'
                              : '应用开启时每天核对一次，也可立即核对。按当前电脑文件比较最近手机摘要；手机后续修改须再次提交摘要。',
                          style: Theme.of(context).textTheme.bodySmall),
                      Wrap(spacing: 8, children: [
                        TextButton.icon(
                            onPressed:
                                controller.checking ? null : controller.check,
                            icon: const Icon(Icons.refresh),
                            label: const Text('立即核对')),
                        if (report != null)
                          TextButton(
                              onPressed: () => showDetails(context, controller),
                              child: const Text('查看差异')),
                        if ((controller.needsFolder ||
                                controller.error != null) &&
                            chooseFolder != null)
                          TextButton(
                              onPressed: chooseFolder,
                              child: const Text('选择目录')),
                      ]),
                    ])));
      });

  static int _differenceCount(Map<String, dynamic> report) =>
      (report['only_on_phone'] as List).length +
      (report['only_on_computer'] as List).length +
      (report['different'] as List).length;

  static void showDetails(
      BuildContext context, NoteCheckController controller) {
    Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text('笔记差异')),
                  body: AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => ListView(
                              padding: const EdgeInsets.all(20),
                              children: [
                                if (controller.error != null) ...[
                                  Text('本轮未核对成功：${controller.error}',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                  const Text('以下为上次成功结果，不能代表当前两端已一致。'),
                                  const SizedBox(height: 12),
                                ],
                                const Text(
                                    '默认以电脑版本更新手机，每天自动同步一次，也可手动同步；只在手机存在的笔记保留。按相对路径与 SHA-256 核对，仍可手动选择手机版。成功后不保留被替换版本。电脑端的选择会等待手机连回电脑并打开 APP 后执行。'),
                                if (controller.choiceMessage != null)
                                  Text(controller.choiceMessage!),
                                for (final report in controller.reports) ...[
                                  const SizedBox(height: 20),
                                  Text('${report['folder_label']}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  Text(
                                      '手机摘要 ${time(report['phone_checked_at'])}；电脑核对 ${time(report['computer_checked_at'])}'),
                                  Text(
                                      '一致 ${report['same']} · 只在手机 ${(report['only_on_phone'] as List).length} · 只在电脑 ${(report['only_on_computer'] as List).length} · 内容不同 ${(report['different'] as List).length}'),
                                  if (report['folder_id'] != null &&
                                      report['versions'] is Map)
                                    NoteVersionActions(
                                        batch: true,
                                        busy: controller.choosing ||
                                            controller.checking,
                                        phoneHash:
                                            _batchAvailable(report, 'phone')
                                                ? 'available'
                                                : null,
                                        computerHash:
                                            _batchAvailable(report, 'computer')
                                                ? 'available'
                                                : null,
                                        onChoose: (source) => _submit(
                                            context,
                                            controller,
                                            () => controller.chooseAll(
                                                report, source))),
                                  for (final entry in {
                                    'only_on_phone': '只在手机',
                                    'only_on_computer': '只在电脑',
                                    'different': '内容不同'
                                  }.entries)
                                    for (final path
                                        in report[entry.key] as List)
                                      Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('$path',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium),
                                                Text(entry.value),
                                                if (report['folder_id'] !=
                                                        null &&
                                                    (report['versions']
                                                        as Map?)?[path] is Map)
                                                  _actions(context, controller,
                                                      report, '$path')
                                                else
                                                  const Text(
                                                      '请先更新手机 APP 并重新核对，才能选择同步来源。'),
                                              ])),
                                ],
                                if (controller.reports.isEmpty)
                                  const Text('核对范围已变化，请返回并重新检查。'),
                              ])),
                )));
  }

  static Widget _actions(BuildContext context, NoteCheckController controller,
      Map<String, dynamic> report, String path) {
    final values = (report['versions'] as Map)[path] as Map;
    final candidates = (report['choices'] as List? ?? [])
        .where((c) => c['path'] == path && c['status'] == 'pending')
        .toList();
    return NoteVersionActions(
        phoneHash: values['phone_hash'] as String?,
        computerHash: values['computer_hash'] as String?,
        busy: controller.choosing || controller.checking,
        pending: candidates.isEmpty
            ? null
            : (candidates.first as Map).cast<String, dynamic>(),
        onChoose: (source) => _submit(context, controller,
            () => controller.chooseVersion(report, path, source)));
  }

  static bool _batchAvailable(Map<String, dynamic> report, String source) =>
      (report['versions'] as Map).entries.any((e) =>
          (e.value as Map)['${source}_hash'] != null &&
          !(report['choices'] as List? ?? [])
              .any((c) => c['path'] == e.key && c['status'] == 'pending'));
  static Future<void> _submit(BuildContext context,
      NoteCheckController controller, Future<void> Function() action) async {
    await action();
    if (!context.mounted) return;
    final message = controller.error ?? controller.choiceMessage;
    if (message != null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
