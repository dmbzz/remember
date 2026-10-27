import 'package:flutter/material.dart';

class AsrJobCard extends StatelessWidget {
  const AsrJobCard({super.key, required this.job, this.onRetry});
  final Map<String, dynamic> job;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final result = (job['result'] as Map?) ?? {};
    final progress = (job['progress'] as Map?) ?? {};
    const labels = {
      'queued': '等待转写',
      'running': '正在转写',
      'completed': '转写完成',
      'incomplete': '转写不完整，音频保留',
      'failed': '转写失败，音频保留'
    };
    const phases = {
      'preparing': '准备转写',
      'waiting_engine': '等待 Qwen 引擎空闲',
      'decoding': '准备音频',
      'loading': '加载 Qwen 模型',
      'transcribing': '识别语音与时间戳',
      'cpu_fallback': 'GPU 不可用，改用 Qwen CPU',
      'tail': '补充识别录音末尾',
      'service': '等待 Qwen 服务返回结果',
      'saving': '识别结束，正在保存文件与台账'
    };
    final done = progress['completed_chunks'], total = progress['total_chunks'];
    final determinate = progress['phase'] == 'transcribing' &&
        done is num &&
        total is num &&
        total > 0;
    final value =
        determinate ? (done / total).clamp(0.0, 1.0).toDouble() : null;
    final status = job['status'];
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${job['source_name']}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(labels[status] ?? '$status'),
              if (status == 'running' ||
                  status == 'queued' ||
                  status == 'completed') ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value: status == 'completed' ? 1 : value,
                    semanticsLabel: 'ASR 转写进度'),
              ],
              if (status == 'running')
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                        '${phases[progress['phase']] ?? '正在转写'}${determinate ? ' · 已完成 $done / $total 分片' : ''}')),
              if (result.isNotEmpty) ...[
                Text(
                    '${result['segments']} 段 · ${result['chars']} 字 · 录音 ${result['duration_sec']} 秒 · 转写耗时 ${result['elapsed_sec']} 秒'),
                SelectableText('${result['output_path']}'),
                Text(
                    '${result['source_note']} · 台账${result['ledger_appended'] == true ? '已追加' : '未确认'}'),
              ],
              if ('${job['error'] ?? ''}'.isNotEmpty)
                Text('${job['error']}',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if ((status == 'failed' || status == 'incomplete') &&
                  onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('手动重试')),
            ])));
  }
}
