import 'package:flutter/material.dart';
import '../../data/api_client.dart';
import 'asr_settings_page.dart';

/// One recording-tab entry; phone access remains limited to tasks and retries.
class AsrSettingsEntry extends StatelessWidget {
  const AsrSettingsEntry(
      {super.key, required this.apiClient, required this.canConfigure});
  final ApiClient apiClient;
  final bool canConfigure;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.transcribe),
          title: const Text('录音自动转写'),
          subtitle: Text(canConfigure ? '模型下载、转写目录与任务状态' : '查看电脑转写任务与重试'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AsrSettingsPage(
                  apiClient: apiClient, editable: canConfigure))),
        ),
      );
}
