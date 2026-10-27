import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/shapes.dart';
import '../../core/orientation_capsule.dart';

import '../../data/api_client.dart';
import '../../core/course_palette.dart';
import '../../data/upload_queue.dart';
import '../asr/asr_job_card.dart';
import '../asr/asr_settings_entry.dart';
import 'reception_progress.dart';

/// 桌面端（Windows）「录音」标签页。
///
/// 判断：**桌面端不录音**——录音是手机在课堂上做的事（见 PRD §5 / FR-03）。
/// 因此桌面端该标签页改为「录音文件 / 上传队列」管理：查看待上传队列、失败重试、
/// 并说明录音请用手机端。
class RecordingFilesPage extends StatefulWidget {
  final UploadQueue uploadQueue;
  final ApiClient apiClient;

  const RecordingFilesPage({
    super.key,
    required this.uploadQueue,
    required this.apiClient,
  });

  @override
  State<RecordingFilesPage> createState() => _RecordingFilesPageState();
}

class _RecordingFilesPageState extends State<RecordingFilesPage> {
  late List<UploadItem> _items;
  StreamSubscription<List<UploadItem>>? _sub;
  List<Map<String, dynamic>> _received = [];
  List<Map<String, dynamic>> _asrJobs = [];
  String? _asrError;
  String? _receivedError;
  bool _loading = false;
  bool _hasLoaded = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _items = widget.uploadQueue.items;
    _sub = widget.uploadQueue.queueStream.listen((list) {
      if (mounted) setState(() => _items = list);
    });
    unawaited(_loadReceived());
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && TickerMode.of(context)) unawaited(_loadReceived());
    });
  }

  Future<void> _loadReceived() async {
    if (_loading) return;
    setState(() => _loading = true);
    final results = await Future.wait([
      widget.apiClient.getRecordings(),
      widget.apiClient.getCourses(),
      widget.apiClient.getAsrJobs()
    ]);
    final result = results.first;
    final names = {
      for (final course in results[1].data ?? <Map<String, dynamic>>[])
        '${course['id']}': '${course['name']}'
    };
    if (!mounted) return;
    setState(() {
      if (result.ok) {
        _received = (result.data ?? [])
            .map((rec) => {
                  ...rec,
                  'course_name': rec['course_name'] ??
                      names['${rec['course_id']}'] ??
                      rec['course_id']
                })
            .toList();
      }
      _receivedError = result.error;
      _asrError = results[2].error;
      if (results[2].ok) _asrJobs = results[2].data!;
      _loading = false;
      _hasLoaded = true;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('电脑收到的录音'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新电脑已收到的录音',
            onPressed: _loadReceived,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20 + StudyDockContentInset.of(context), 20,
            20, 20 + MediaQuery.paddingOf(context).bottom),
        children: [
          AsrSettingsEntry(apiClient: widget.apiClient, canConfigure: true),
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.surface,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: StudyShapes.cardBorder,
              side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.phone_android,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '上方显示电脑实际收到的录音。手机待上传文件请在手机“录音同步到电脑”中查看。',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('电脑收到的录音',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          SizedBox(
              height: 4,
              child: _loading ? const LinearProgressIndicator() : null),
          if (_receivedError != null) Text(_receivedError!),
          if (_hasLoaded && _received.isEmpty && _receivedError == null)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('电脑尚未收到录音')),
          for (final rec in _received)
            Card(
                shape: RoundedRectangleBorder(
                    borderRadius: StudyShapes.cardBorder,
                    side: BorderSide(
                        color:
                            CoursePalette.of(context, "${rec['course_name']}")
                                .line)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: Icon(rec['upload_status'] == 'uploaded'
                            ? Icons.check_circle_outline
                            : Icons.cloud_upload_outlined),
                        title: Text(
                            '${rec['course_name'] ?? rec['course_id'] ?? '录音'}'),
                        subtitle: Text(
                            '${rec['upload_status'] == 'uploaded' ? '已保存到电脑' : '手机录音同步'} · ${((rec['size_bytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB\n${rec['file_path'] ?? ''}'),
                      ),
                      ReceptionProgress(recording: rec)
                    ])),
          const SizedBox(height: 16),
          Text('ASR 转写进度', style: Theme.of(context).textTheme.titleMedium),
          if (_asrError != null) Text('转写状态刷新失败：$_asrError'),
          if (_asrJobs.isEmpty && _asrError == null) const Text('暂无转写任务'),
          for (final job in _asrJobs.take(10)) AsrJobCard(job: job),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.cloud_upload_outlined,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('本电脑上传队列（${_items.length}）',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15))),
            ],
          ),
          const SizedBox(height: 8),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.inbox_outlined,
                      size: 56, color: Colors.grey.shade400),
                  const SizedBox(height: 10),
                  Text('暂无待上传的录音文件',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            )
          else
            ..._items.map(_buildItem),
        ],
      ),
    );
  }

  Widget _buildItem(UploadItem item) {
    final (label, color, icon) = _statusStyle(item.status);
    final fileName = item.filePath.split(RegExp(r'[\\/]')).last;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(fileName.isEmpty ? item.filePath : fileName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                Chip(
                  label: Text(label,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 11)),
                  backgroundColor: color,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('课程：${item.courseId} ｜ 第${item.lesson}课 ｜ ${item.classDate}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (item.status == UploadStatus.uploading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: item.progress / 100.0),
            ],
            if (item.error != null && item.error!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('错误：${item.error}',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (item.status == UploadStatus.failed)
                  TextButton.icon(
                    onPressed: () => widget.uploadQueue.retry(item.id),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                TextButton.icon(
                  onPressed: () => widget.uploadQueue.remove(item.id),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('移除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  (String, Color, IconData) _statusStyle(UploadStatus status) {
    switch (status) {
      case UploadStatus.pending:
        return ('待上传', Colors.orange.shade700, Icons.schedule);
      case UploadStatus.uploading:
        return ('上传中', Colors.blue.shade700, Icons.cloud_upload);
      case UploadStatus.completed:
        return ('已完成', Colors.green.shade700, Icons.check_circle);
      case UploadStatus.failed:
        return ('失败', Colors.red.shade700, Icons.error_outline);
    }
  }
}
