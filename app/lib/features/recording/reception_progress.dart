import 'package:flutter/material.dart';

class ReceptionProgress extends StatelessWidget {
  const ReceptionProgress({super.key, required this.recording});
  final Map<String, dynamic> recording;
  @override
  Widget build(BuildContext context) {
    final progress = (recording['reception_progress'] as Map?) ?? {};
    final received = (progress['received_bytes'] as num?) ?? 0;
    final total = (progress['total_bytes'] as num?) ?? 0;
    final phase = recording['upload_status'] == 'uploaded'
        ? 'received'
        : progress['phase'];
    final ratio =
        total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
    const labels = {
      'waiting': '等待手机发送',
      'receiving': '正在接收手机传输数据',
      'saving': '传输数据已收到，正在保存并确认',
      'received': '已完整保存到电脑',
      'interrupted': '传输中断，等待手机重试',
      'failed': '接收失败，等待手机重试',
      'waiting_connection': '等待手机连接或电脑保存确认'
    };
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '${labels[phase] ?? '等待手机发送'}${phase == 'receiving' && ratio != null ? ' · ${(ratio * 100).toStringAsFixed(0)}%' : ''}'),
          const SizedBox(height: 6),
          LinearProgressIndicator(
              value: phase == 'received'
                  ? 1
                  : phase == 'saving'
                      ? null
                      : ratio ?? (phase == 'waiting' ? 0 : null),
              semanticsLabel: '录音接收进度'),
        ]));
  }
}
