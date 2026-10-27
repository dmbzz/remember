import 'package:flutter/material.dart';
import '../../data/upload_queue.dart';

class RecordingSyncPanel extends StatelessWidget {
  const RecordingSyncPanel(
      {super.key, required this.queue, required this.onSync, this.onAssign});
  final UploadQueue queue;
  final Future<void> Function() onSync;
  final void Function(UploadItem)? onAssign;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<UploadItem>>(
        stream: queue.queueStream,
        initialData: queue.items,
        builder: (context, snapshot) {
          final items = (snapshot.data ?? []).reversed.toList();
          return Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('录音同步到电脑',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      const Text('自动录音结束后会入队。连回电脑所在网络后自动重试，电脑确认完整接收才删除手机副本。'),
                      const SizedBox(height: 8),
                      Text(
                          '上次扫描找到 ${queue.scannedFiles} 个录音文件 · 同步记录 ${items.length} 条'),
                      if (queue.recoveryError != null)
                        Text(queue.recoveryError!),
                      FilledButton.tonalIcon(
                          onPressed: () => onSync(),
                          icon: const Icon(Icons.sync),
                          label: const Text('重新扫描并同步')),
                      if (items.isEmpty) const Text('暂无同步记录。录音结束后可点击上方按钮重新扫描。'),
                      for (final item in items.take(10))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.filePath.split(RegExp(r'[\\/]')).last,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                Text(switch (item.status) {
                                  UploadStatus.pending => '等待上传，手机文件保留',
                                  UploadStatus.uploading =>
                                    '正在发送到电脑：${item.progress}%',
                                  UploadStatus.completed => '电脑已确认收到 · 手机副本已删除',
                                  UploadStatus.failed => item.retryable
                                      ? '等待连接电脑，稍后自动重试'
                                      : '需要处理，手机文件保留',
                                }),
                                if (item.error != null)
                                  Text(item.error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                if (item.status == UploadStatus.uploading)
                                  LinearProgressIndicator(
                                      value: item.progress / 100),
                                if (item.status == UploadStatus.failed)
                                  Wrap(spacing: 8, children: [
                                    TextButton(
                                        onPressed: () => queue.retry(item.id),
                                        child: const Text('立即重试')),
                                    if (onAssign != null &&
                                        (!item.retryable ||
                                            item.courseId.isEmpty))
                                      TextButton(
                                          onPressed: () => onAssign!(item),
                                          child: const Text('指定课程')),
                                  ]),
                              ]),
                        ),
                    ],
                  )));
        },
      );
}
