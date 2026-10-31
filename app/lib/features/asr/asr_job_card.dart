import 'package:flutter/material.dart';
import '../../data/api_client.dart';

class AsrJobCard extends StatefulWidget {
  const AsrJobCard(
      {super.key,
      required this.job,
      this.onRetry,
      this.apiClient,
      this.onChanged,
      this.snapshotRevision,
      this.refreshSnapshot});
  final Map<String, dynamic> job;
  final VoidCallback? onRetry;
  final ApiClient? apiClient;
  final Future<void> Function()? onChanged;

  /// Revision of a successfully applied list response, never of a failed read.
  final int? snapshotRevision;

  /// Force a post-action read and return its request epoch, including on failure.
  /// A later successful snapshot must reach this floor before replacing a receipt.
  final Future<int> Function()? refreshSnapshot;
  @override
  State<AsrJobCard> createState() => _AsrJobCardState();
}

class _AsrJobCardState extends State<AsrJobCard> {
  bool _busy = false, _deleted = false;
  String? _error, _notice;
  Map<String, dynamic>? _receipt;
  String? _receiptAction;
  int? _receiptSnapshotFloor;
  bool _awaitingSnapshotFloor = false;
  Map<String, dynamic> get _job => _receipt ?? widget.job;

  @override
  void didUpdateWidget(AsrJobCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_receipt != null && !_awaitingSnapshotFloor) {
      if (widget.snapshotRevision != null && _receiptSnapshotFloor != null) {
        if (widget.snapshotRevision! >= _receiptSnapshotFloor!) {
          _acceptSnapshot();
        }
      } else if (oldWidget.job != widget.job) {
        // Standalone/legacy callers have no revision; retain their safe fallback.
        final incoming = widget.job['status'];
        final incomingResult = (widget.job['result'] as Map?) ?? {};
        final stale = _receiptAction == 'cancel' &&
                ['queued', 'running'].contains(incoming) ||
            _receiptAction == 'retry' &&
                ['failed', 'incomplete', 'cancelled'].contains(incoming) ||
            _receiptAction == 'recording' &&
                ((_receipt!['result'] as Map?)?['source_deleted'] == true) &&
                incomingResult['source_deleted'] != true;
        if (!stale) _acceptSnapshot();
      }
    }
    if (oldWidget.job['id'] != widget.job['id']) {
      _deleted = false;
      _error = _notice = null;
      _receipt = null;
      _receiptAction = null;
      _receiptSnapshotFloor = null;
      _awaitingSnapshotFloor = false;
    }
  }

  void _acceptSnapshot() {
    _receipt = null;
    _receiptAction = null;
    _receiptSnapshotFloor = null;
    _notice = null;
  }

  bool _can(String flag, bool fallback) =>
      _job[flag] is bool ? _job[flag] == true : fallback;

  Future<bool> _confirm(String action) async {
    final name = '${_job['source_name'] ?? '这条录音'}';
    final (title, explanation, keep, confirm) = switch (action) {
      'cancel' => ('取消这项转写？', '停止本次识别，保留电脑源录音和已有转写结果。', '继续转写', '取消转写'),
      'delete' => ('删除这项任务？', '从转写任务列表移除，保留电脑源录音、转写文本和台账。', '保留任务', '删除任务'),
      _ => (
          '删除电脑源录音？',
          '永久删除这项任务对应的电脑源录音，保留转写文本和台账。若录音位于微力同步等同步文件夹，删除也会同步到其他设备。',
          '保留录音',
          '删除电脑录音'
        ),
    };
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    scrollable: true,
                    title: Text(title),
                    content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name),
                          const SizedBox(height: 12),
                          Text(explanation)
                        ]),
                    actions: [
                      TextButton(
                          autofocus: true,
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(keep)),
                      TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor:
                                  Theme.of(context).colorScheme.error),
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(confirm))
                    ])) ??
        false;
  }

  Future<void> _act(String action) async {
    if (_busy || widget.apiClient == null) return;
    // Include the confirmation in the per-task busy scope to prevent duplicate dialogs.
    setState(() {
      _busy = true;
      _error = _notice = null;
    });
    try {
      if (action != 'retry' && !await _confirm(action)) return;
      if (!mounted) return;
      final api = widget.apiClient!;
      final id = '${_job['id']}';
      final response = await switch (action) {
        'retry' => api.retryAsrJob(id),
        'cancel' => api.cancelAsrJob(id),
        'delete' => api.deleteAsrJob(id),
        _ => api.deleteAsrRecording(id),
      };
      if (!mounted) return;
      if (!response.ok) {
        setState(() => _error = response.error ?? '操作失败，请重试');
        return;
      }
      setState(() {
        if (action == 'delete') _deleted = true;
        if (response.data?['id'] != null) {
          _receipt = {..._job, ...response.data!};
          _receiptAction = action;
          _receiptSnapshotFloor = widget.snapshotRevision == null
              ? null
              : widget.snapshotRevision! + 1;
          _awaitingSnapshotFloor = widget.refreshSnapshot != null;
        }
        _notice = switch (action) {
          'retry' => '已重新加入转写队列',
          'cancel' =>
            response.data?['status'] == 'cancelled' ? '已取消转写' : '正在停止转写，录音保留',
          'delete' => '已删除任务，录音和转写文件保留',
          _ => '电脑源录音已删除，转写文件保留',
        };
      });
      if (action == 'delete') {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_notice!)));
      }
      if (widget.refreshSnapshot != null) {
        final floor = await widget.refreshSnapshot!();
        if (!mounted) return;
        setState(() {
          _receiptSnapshotFloor = floor;
          _awaitingSnapshotFloor = false;
          if (widget.snapshotRevision != null &&
              widget.snapshotRevision! >= floor) {
            _acceptSnapshot();
          }
        });
      } else {
        await widget.onChanged?.call();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _awaitingSnapshotFloor = false;
          _receiptSnapshotFloor = widget.snapshotRevision == null
              ? null
              : widget.snapshotRevision! + 1;
          _error = '操作或刷新失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_deleted) return const SizedBox.shrink();
    final job = _job;
    final result = (job['result'] as Map?) ?? {};
    final progress = (job['progress'] as Map?) ?? {};
    const labels = {
      'queued': '等待转写',
      'running': '正在转写',
      'cancelling': '正在取消，等待识别进程停止',
      'cancelled': '已取消转写',
      'completed': '转写完成',
      'incomplete': '转写不完整',
      'failed': '转写失败'
    };
    const phases = {
      'preparing': '准备转写',
      'waiting_engine': '等待识别引擎空闲',
      'decoding': '准备音频',
      'loading': '加载识别模型',
      'transcribing': '识别语音与时间戳',
      'cpu_fallback': 'GPU 不可用，改用 CPU',
      'tail': '补充识别录音末尾',
      'service': '等待 Qwen 服务返回结果',
      'saving': '识别结束，正在保存文件与台账'
    };
    final status = job['status'];
    final done = progress['completed_chunks'], total = progress['total_chunks'];
    final determinate = progress['phase'] == 'transcribing' &&
        done is num &&
        total is num &&
        total > 0;
    final value =
        determinate ? (done / total).clamp(0.0, 1.0).toDouble() : null;
    final retry = _can(
        'can_retry', ['failed', 'incomplete', 'cancelled'].contains(status));
    final cancel = _can(
        'can_cancel',
        ['queued', 'running'].contains(status) &&
            progress['phase'] != 'saving');
    final delete = _can('can_delete',
        ['completed', 'failed', 'incomplete', 'cancelled'].contains(status));
    final deleteRecording = _can(
        'can_delete_recording',
        ['failed', 'incomplete', 'cancelled'].contains(status) &&
            result['source_deleted'] != true);
    final hasApi = widget.apiClient != null;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${job['source_name']}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(labels[status] ?? '$status'),
              if (['running', 'queued', 'cancelling', 'completed']
                  .contains(status)) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value: status == 'completed'
                        ? 1
                        : status == 'cancelling'
                            ? null
                            : value,
                    semanticsLabel:
                        status == 'cancelling' ? '正在停止转写' : 'ASR 转写进度')
              ],
              if (status == 'running')
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                        '${phases[progress['phase']] ?? '正在转写'}${determinate ? ' · 已完成 $done / $total 分片' : ''}')),
              if (result['segments'] != null)
                Text(
                    '${result['segments']} 段 · ${result['chars']} 字 · 录音 ${result['duration_sec']} 秒 · 转写耗时 ${result['elapsed_sec']} 秒'),
              if ('${result['output_path'] ?? ''}'.isNotEmpty)
                SelectableText('${result['output_path']}'),
              if ('${result['source_note'] ?? ''}'.isNotEmpty)
                Text(
                    '${result['source_note']}${result['ledger_appended'] != null ? ' · 台账${result['ledger_appended'] == true ? '已追加' : '未确认'}' : ''}'),
              if ('${job['error'] ?? ''}'.isNotEmpty)
                Text('${job['error']}',
                    style: TextStyle(
                        color: status == 'cancelled'
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error)),
              if (_notice != null) Text(_notice!, semanticsLabel: _notice),
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (_busy)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(semanticsLabel: '正在提交任务操作')),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (retry && (hasApi || widget.onRetry != null))
                  TextButton(
                      onPressed: _busy
                          ? null
                          : hasApi
                              ? () => _act('retry')
                              : widget.onRetry,
                      child: const Text('手动重试')),
                if (cancel && hasApi)
                  TextButton(
                      onPressed: _busy ? null : () => _act('cancel'),
                      child: const Text('取消转写')),
                if (delete && hasApi)
                  TextButton(
                      onPressed: _busy ? null : () => _act('delete'),
                      child: const Text('删除任务')),
                if (deleteRecording && hasApi)
                  TextButton(
                      style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: _busy ? null : () => _act('recording'),
                      child: const Text('删除电脑录音')),
              ]),
            ])));
  }
}
