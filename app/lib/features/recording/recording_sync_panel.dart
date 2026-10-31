import 'package:flutter/material.dart';
import '../../data/upload_queue.dart';
import '../../core/motion.dart';
import 'recent_records.dart';
import 'recording_history_page.dart';

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
          final items = newestUploads(snapshot.data ?? []);
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
                      RecentRecordsHeader(
                          title: '最近上传记录',
                          hiddenActive: items
                              .skip(recentRecordLimit)
                              .where((e) =>
                                  e.status == UploadStatus.pending ||
                                  e.status == UploadStatus.uploading)
                              .length,
                          onAll: () => Navigator.of(context).push(
                              studyReadingRoute(
                                  context,
                                  (_) => UploadHistoryPage(
                                      queue: queue,
                                      onSync: onSync,
                                      onAssign: onAssign)))),
                      for (final item in items.take(recentRecordLimit))
                        UploadRecordCard(
                            key: ValueKey(item.id),
                            item: item,
                            queue: queue,
                            onAssign: onAssign),
                    ],
                  )));
        },
      );
}
