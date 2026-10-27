import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../data/note_file_synchronizer.dart';
import 'note_version_actions.dart';

class NoteFileSyncPanel extends StatelessWidget {
  const NoteFileSyncPanel(
      {super.key, required this.controller, this.chooseFolder});
  final NoteFileSynchronizer controller;
  final VoidCallback? chooseFolder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final sync = controller;
        final summary = sync.needsFolder
            ? '选择手机目录后即可同步'
            : sync.syncing
                ? '同步中：${sync.processed} / ${sync.total} 篇'
                : sync.error != null
                    ? '本轮同步尚未完成，请查看原因'
                    : sync.lastCompleted == null
                        ? '连接电脑后检查差异；离线可读本地笔记'
                        : '手机更新 ${sync.downloaded} 篇 · 电脑更新 ${sync.uploaded} 篇 · 相同 ${sync.unchanged} 篇 · 待选择 ${sync.versions.length} 篇';
        return Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.sync),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text('笔记同步',
                                style:
                                    Theme.of(context).textTheme.titleMedium)),
                        if (sync.syncing)
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                      ]),
                      const SizedBox(height: 8),
                      Text(summary),
                      if (sync.lastCompleted != null)
                        Text(
                            '上次检查：${DateFormat('M月d日 HH:mm').format(sync.lastCompleted!)}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (sync.syncing) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                            value: sync.total == 0
                                ? null
                                : (sync.processed / sync.total)
                                    .clamp(0.0, 1.0)),
                        if (sync.activePath != null) Text(sync.activePath!)
                      ],
                      if (sync.error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(sync.error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 8),
                      const Text(
                          '每天自动同步一次，也可立即同步。默认以电脑版本覆盖手机，不保留被替换版本；只在手机存在的笔记不会删除。仍可手动选择手机版。只同步 Markdown，不包含附件。'),
                      const SizedBox(height: 6),
                      const Text('电脑端的选择会在手机连回电脑并打开本 APP 时执行。前台只获取待处理的选择；后台暂停。',
                          style: TextStyle(fontSize: 13)),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        TextButton.icon(
                            onPressed: sync.syncing ? null : () => sync.sync(),
                            icon: const Icon(Icons.sync),
                            label: const Text('立即同步')),
                        if (chooseFolder != null)
                          TextButton(
                              onPressed: sync.syncing ? null : chooseFolder,
                              child: Text(sync.needsWritePermission
                                  ? '重新授权目录'
                                  : '选择目录')),
                        TextButton(
                            onPressed: () => showDetails(context, sync),
                            child: const Text('查看差异并选择版本')),
                      ]),
                    ])));
      });

  static void showDetails(BuildContext context, NoteFileSynchronizer sync) =>
      Navigator.push<void>(
          context,
          MaterialPageRoute(
              builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text('笔记差异与同步选择')),
                  body: AnimatedBuilder(
                      animation: sync,
                      builder: (context, _) => ListView(
                              padding: const EdgeInsets.all(20),
                              children: [
                                const Text(
                                    '默认以电脑版本更新手机；只在手机存在的笔记保留。手动选择“同步手机的笔记”时，手机 → 电脑；“同步电脑的笔记”时，电脑 → 手机。成功后不保留另一版；传输或校验失败不会先删除原文件。'),
                                const SizedBox(height: 12),
                                NoteVersionActions(
                                    batch: true,
                                    busy: sync.syncing || sync.versions.isEmpty,
                                    phoneHash: sync.canChooseAll('phone')
                                        ? 'available'
                                        : null,
                                    computerHash: sync.canChooseAll('computer')
                                        ? 'available'
                                        : null,
                                    onChoose: (source) => _submit(context, sync,
                                        () => sync.chooseAll(source))),
                                if (sync.error != null)
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      child: Text('本轮未完成：${sync.error}',
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error))),
                                for (final entry in sync.versions.entries)
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(entry.key,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium),
                                            const SizedBox(height: 8),
                                            _actions(context, sync, entry.key,
                                                entry.value),
                                          ])),
                                if (sync.versions.isEmpty)
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 16),
                                      child: Text('当前没有待选择的差异。')),
                                TextButton.icon(
                                    onPressed: sync.syncing
                                        ? null
                                        : () => sync.sync(checkOnly: true),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新核对')),
                              ])))));

  static Widget _actions(BuildContext context, NoteFileSynchronizer sync,
      String path, Map<String, String?> versions) {
    final pending = sync.choices
        .where((c) => c['path'] == path && c['status'] == 'pending')
        .toList();
    return NoteVersionActions(
        phoneHash: versions['phone_hash'],
        computerHash: versions['computer_hash'],
        busy: sync.syncing,
        pending: pending.isEmpty ? null : pending.first,
        onChoose: (source) => _submit(
            context,
            sync,
            () => sync.chooseVersion(path, source,
                phoneHash: versions['phone_hash'],
                computerHash: versions['computer_hash'],
                revision: sync.scopeRevision)));
  }

  static Future<void> _submit(BuildContext context, NoteFileSynchronizer sync,
      Future<void> Function() action) async {
    await action();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sync.error ?? '已处理所选版本，同步成功的笔记不保留被替换版本。')));
  }
}
