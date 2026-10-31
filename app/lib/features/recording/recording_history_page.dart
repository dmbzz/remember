import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/course_palette.dart';
import '../../core/orientation_capsule.dart';
import '../../core/shapes.dart';
import '../../data/api_client.dart';
import '../../data/upload_queue.dart';
import 'recent_records.dart';
import 'reception_progress.dart';

class ReceivedRecordingCard extends StatelessWidget {
  const ReceivedRecordingCard({super.key, required this.recording});
  final Map<String, dynamic> recording;
  @override
  Widget build(BuildContext context) {
    final rec = recording;
    final deleted = rec['deleted_at'] != null;
    return Card(
        shape: RoundedRectangleBorder(
            borderRadius: StudyShapes.cardBorder,
            side: BorderSide(
                color:
                    CoursePalette.of(context, "${rec['course_name']}").line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
              leading: Icon(deleted
                  ? Icons.audio_file_outlined
                  : rec['upload_status'] == 'uploaded'
                      ? Icons.check_circle_outline
                      : Icons.cloud_upload_outlined),
              title: Text('${rec['course_name'] ?? rec['course_id'] ?? '录音'}'),
              subtitle: Text(
                  '${deleted ? '电脑录音已删除，接收记录保留' : rec['upload_status'] == 'uploaded' ? '已保存到电脑' : '手机录音同步'} · ${((rec['size_bytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB\n${rec['file_path'] ?? ''}')),
          ReceptionProgress(recording: rec)
        ]));
  }
}

class RecordingsHistoryPage extends StatefulWidget {
  const RecordingsHistoryPage({super.key, required this.apiClient});
  final ApiClient apiClient;
  @override
  State<RecordingsHistoryPage> createState() => _RecordingsHistoryPageState();
}

class _RecordingsHistoryPageState extends State<RecordingsHistoryPage> {
  List<Map<String, dynamic>> _items = [];
  String? _error;
  bool _reading = false, _loaded = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && TickerMode.of(context)) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_reading) return;
    setState(() => _reading = true);
    final results = await Future.wait(
        [widget.apiClient.getRecordings(), widget.apiClient.getCourses()]);
    if (!mounted) return;
    final names = {
      for (final c in results[1].data ?? <Map<String, dynamic>>[])
        '${c['id']}': '${c['name']}'
    };
    setState(() {
      _reading = false;
      _loaded = true;
      _error = results[0].error;
      if (results[0].ok) {
        _items = newestRecords(results[0]
            .data!
            .map((r) => {
                  ...r,
                  'course_name': r['course_name'] ??
                      names['${r['course_id']}'] ??
                      r['course_id']
                })
            .toList());
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('全部接收记录'), actions: [
        IconButton(
            onPressed: _reading ? null : _refresh,
            tooltip: '刷新全部接收记录',
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(
          padding: EdgeInsets.fromLTRB(20 + StudyDockContentInset.of(context),
              20, 20, 20 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (_reading) const LinearProgressIndicator(),
            if (_error != null)
              Text('接收记录刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_loaded && _items.isEmpty && _error == null)
              const Text('电脑尚未收到录音'),
            for (final item in _items) ReceivedRecordingCard(recording: item),
          ]));
}

class UploadRecordCard extends StatelessWidget {
  const UploadRecordCard(
      {super.key,
      required this.item,
      required this.queue,
      this.onAssign,
      this.desktopActions = false});
  final UploadItem item;
  final UploadQueue queue;
  final void Function(UploadItem)? onAssign;
  final bool desktopActions;
  @override
  Widget build(BuildContext context) {
    final label = switch (item.status) {
      UploadStatus.pending => desktopActions ? '等待上传，原文件保留' : '等待上传，手机文件保留',
      UploadStatus.uploading =>
        desktopActions ? '正在上传：${item.progress}%' : '正在发送到电脑：${item.progress}%',
      UploadStatus.completed =>
        desktopActions ? '电脑已确认接收' : '电脑已确认收到 · 手机副本已删除',
      UploadStatus.failed => desktopActions
          ? '上传失败，原文件保留'
          : item.retryable
              ? '等待连接电脑，稍后自动重试'
              : '需要处理，手机文件保留',
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.filePath.split(RegExp(r'[\\/]')).last,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(label),
              if (desktopActions)
                Text(
                    '课程：${item.courseId} ｜ 第${item.lesson}课 ｜ ${item.classDate}'),
              if (item.error != null && item.error!.isNotEmpty)
                Text(item.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (item.status == UploadStatus.uploading)
                LinearProgressIndicator(value: item.progress / 100),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (item.status == UploadStatus.failed)
                  TextButton(
                      onPressed: () => queue.retry(item.id),
                      child: const Text('立即重试')),
                if (item.status == UploadStatus.failed &&
                    onAssign != null &&
                    (!item.retryable || item.courseId.isEmpty))
                  TextButton(
                      onPressed: () => onAssign!(item),
                      child: const Text('指定课程')),
                if (desktopActions)
                  TextButton(
                      onPressed: () => queue.remove(item.id),
                      child: const Text('移除')),
              ]),
            ])));
  }
}

class UploadHistoryPage extends StatelessWidget {
  const UploadHistoryPage(
      {super.key,
      required this.queue,
      this.onSync,
      this.onAssign,
      this.desktopActions = false});
  final UploadQueue queue;
  final Future<void> Function()? onSync;
  final void Function(UploadItem)? onAssign;
  final bool desktopActions;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('全部上传记录')),
      body: StreamBuilder<List<UploadItem>>(
          stream: queue.queueStream,
          initialData: queue.items,
          builder: (context, snapshot) {
            final items = newestUploads(snapshot.data ?? []);
            return ListView(
                padding: EdgeInsets.fromLTRB(
                    20 + StudyDockContentInset.of(context),
                    20,
                    20,
                    20 + MediaQuery.paddingOf(context).bottom),
                children: [
                  if (onSync != null)
                    Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                            onPressed: onSync,
                            icon: const Icon(Icons.sync),
                            label: const Text('重新扫描并同步'))),
                  if (queue.recoveryError != null)
                    Text(queue.recoveryError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (items.isEmpty) const Text('暂无上传记录'),
                  for (final item in items)
                    UploadRecordCard(
                        key: ValueKey(item.id),
                        item: item,
                        queue: queue,
                        onAssign: onAssign,
                        desktopActions: desktopActions),
                ]);
          }));
}
