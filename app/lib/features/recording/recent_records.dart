import 'package:flutter/material.dart';
import '../../data/upload_queue.dart';

const recentRecordLimit = 3;

/// Known timestamps sort newest first; missing/equal timestamps keep input order.
List<Map<String, dynamic>> newestRecords(List<Map<String, dynamic>> items) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final left = DateTime.tryParse('${a.$2['created_at'] ?? ''}');
    final right = DateTime.tryParse('${b.$2['created_at'] ?? ''}');
    if (left == null && right != null) return 1;
    if (left != null && right == null) return -1;
    if (left != null && right != null) {
      final order = right.compareTo(left);
      if (order != 0) return order;
    }
    return a.$1.compareTo(b.$1);
  });
  return indexed.map((e) => e.$2).toList();
}

List<UploadItem> newestUploads(List<UploadItem> items) {
  final indexed = items.reversed.indexed.toList();
  indexed.sort((a, b) {
    if (a.$2.createdAt == null && b.$2.createdAt != null) return 1;
    if (a.$2.createdAt != null && b.$2.createdAt == null) return -1;
    if (a.$2.createdAt != null && b.$2.createdAt != null) {
      final order = b.$2.createdAt!.compareTo(a.$2.createdAt!);
      if (order != 0) return order;
    }
    return a.$1.compareTo(b.$1);
  });
  return indexed.map((e) => e.$2).toList();
}

class RecentRecordsHeader extends StatelessWidget {
  const RecentRecordsHeader(
      {super.key,
      required this.title,
      required this.onAll,
      this.hiddenActive = 0});
  final String title;
  final VoidCallback onAll;
  final int hiddenActive;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              TextButton(onPressed: onAll, child: const Text('查看全部'))
            ]),
        if (hiddenActive > 0)
          Text('另有 $hiddenActive 个进行中的任务，可在“查看全部”中查看。',
              style: Theme.of(context).textTheme.bodySmall),
      ]);
}
