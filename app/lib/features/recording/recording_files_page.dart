import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/shapes.dart';
import '../../core/orientation_capsule.dart';

import '../../data/api_client.dart';
import '../../core/motion.dart';
import '../../data/upload_queue.dart';
import '../asr/asr_job_card.dart';
import '../asr/asr_settings_entry.dart';
import 'recent_records.dart';
import 'recording_history_page.dart';
import '../asr/asr_jobs_page.dart';

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
  int _loadEpoch = 0;
  int _asrSnapshotRevision = 0;
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

  Future<void> _loadReceived({bool force = false}) async {
    if (_loading && !force) return;
    final epoch = ++_loadEpoch;
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
    if (!mounted || epoch != _loadEpoch) return;
    setState(() {
      if (result.ok) {
        _received = newestRecords((result.data ?? [])
            .map((rec) => {
                  ...rec,
                  'course_name': rec['course_name'] ??
                      names['${rec['course_id']}'] ??
                      rec['course_id']
                })
            .toList());
      }
      _receivedError = result.error;
      _asrError = results[2].error;
      if (results[2].ok) {
        _asrJobs = newestRecords(results[2].data!);
        _asrSnapshotRevision = epoch;
      }
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
          RecentRecordsHeader(
              title: '最近接收记录',
              hiddenActive: _received
                  .skip(recentRecordLimit)
                  .where((r) => r['upload_status'] != 'uploaded')
                  .length,
              onAll: () async {
                await Navigator.of(context).push(studyReadingRoute(context,
                    (_) => RecordingsHistoryPage(apiClient: widget.apiClient)));
                if (mounted) await _loadReceived(force: true);
              }),
          SizedBox(
              height: 4,
              child: _loading ? const LinearProgressIndicator() : null),
          if (_receivedError != null) Text(_receivedError!),
          if (_hasLoaded && _received.isEmpty && _receivedError == null)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('电脑尚未收到录音')),
          for (final rec in _received.take(recentRecordLimit))
            ReceivedRecordingCard(recording: rec),
          const SizedBox(height: 16),
          RecentRecordsHeader(
              title: '最近转写任务',
              hiddenActive: _asrJobs
                  .skip(recentRecordLimit)
                  .where((j) =>
                      ['running', 'queued', 'cancelling'].contains(j['status']))
                  .length,
              onAll: () async {
                await Navigator.of(context).push(studyReadingRoute(
                    context, (_) => AsrJobsPage(apiClient: widget.apiClient)));
                if (mounted) await _loadReceived(force: true);
              }),
          if (_asrError != null) Text('转写状态刷新失败：$_asrError'),
          if (_asrJobs.isEmpty && _asrError == null) const Text('暂无转写任务'),
          for (final job in _asrJobs.take(recentRecordLimit))
            AsrJobCard(
                key: ValueKey('asr-${job['id']}'),
                job: job,
                apiClient: widget.apiClient,
                snapshotRevision: _asrSnapshotRevision,
                refreshSnapshot: () async {
                  await _loadReceived(force: true);
                  return _loadEpoch;
                }),
          const SizedBox(height: 16),
          RecentRecordsHeader(
              title: '最近本电脑上传记录',
              hiddenActive: newestUploads(_items)
                  .skip(recentRecordLimit)
                  .where((e) =>
                      e.status == UploadStatus.pending ||
                      e.status == UploadStatus.uploading)
                  .length,
              onAll: () => Navigator.of(context).push(studyReadingRoute(
                  context,
                  (_) => UploadHistoryPage(
                      queue: widget.uploadQueue, desktopActions: true)))),
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
            for (final item in newestUploads(_items).take(recentRecordLimit))
              UploadRecordCard(
                  key: ValueKey(item.id),
                  item: item,
                  queue: widget.uploadQueue,
                  desktopActions: true),
        ],
      ),
    );
  }
}
