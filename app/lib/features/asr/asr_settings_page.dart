import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/api_client.dart';
import '../../platform/schedule_file_picker.dart';
import 'asr_job_card.dart';
import 'asr_jobs_page.dart';
import '../../core/motion.dart';
import '../recording/recent_records.dart';
import 'asr_models_page.dart';

/// ASR settings belong to the receiving PC. Phones can inspect jobs and retry.
class AsrSettingsPage extends StatefulWidget {
  final ApiClient apiClient;
  final bool? editable;
  const AsrSettingsPage({super.key, required this.apiClient, this.editable});
  @override
  State<AsrSettingsPage> createState() => _AsrSettingsPageState();
}

class _AsrSettingsPageState extends State<AsrSettingsPage> {
  final _fields = <String, TextEditingController>{
    for (final key in [
      'output_dir',
      'python_path',
      'model_path',
      'aligner_path',
      'ffmpeg_path',
      'base_url',
      'model',
      'api_key'
    ])
      key: TextEditingController(),
  };
  bool _loading = true, _busy = false, _enabled = false, _delete = false;
  bool _keySet = false, _clearKey = false;
  bool _loadedSettings = false;
  String _mode = 'local_qwen';
  String _managedId = '';
  String? _error, _message, _jobsError;
  List<Map<String, dynamic>> _jobs = [];
  Timer? _jobTimer;
  bool _readingJobs = false;
  int _jobsEpoch = 0;
  int _jobsSnapshotRevision = 0;
  bool get _editable => widget.editable ?? Platform.isWindows;
  double _choiceHeight(BuildContext context) {
    final painter = TextPainter(
        text: TextSpan(
            text: '本机 Qwen 环境', style: Theme.of(context).textTheme.titleMedium),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        maxLines: 1)
      ..layout();
    final height = (painter.height + 16)
        .ceilToDouble()
        .clamp(48.0, double.infinity)
        .toDouble();
    painter.dispose();
    return height;
  }

  @override
  void initState() {
    super.initState();
    for (final c in _fields.values) {
      c.addListener(_changed);
    }
    _load();
    _jobTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && TickerMode.of(context)) unawaited(_refreshJobs());
    });
  }

  void _changed() {
    if (mounted && !_loading && !_busy) {
      setState(() {
        _message = null;
      });
    }
  }

  @override
  void dispose() {
    _jobTimer?.cancel();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });
    if (_editable) {
      final response = await widget.apiClient.getAsrSettings();
      if (!mounted) return;
      if (!response.ok) {
        await _refreshJobs();
        if (!mounted) return;
        setState(() {
          _error = response.error;
          _loading = false;
          _loadedSettings = false;
        });
        return;
      }
      final data = response.data!;
      _loadedSettings = true;
      for (final key in _fields.keys) {
        _fields[key]!.text = '${data[key] ?? ''}';
      }
      _enabled = data['enabled'] == true;
      _delete = data['delete_source'] == true;
      _keySet = data['api_key_set'] == true;
      _mode = '${data['mode'] ?? 'local_qwen'}';
      _managedId = '${data['managed_id'] ?? ''}';
    }
    await _refreshJobs();
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _refreshJobs({bool force = false}) async {
    if (_readingJobs && !force) return;
    final epoch = ++_jobsEpoch;
    _readingJobs = true;
    final response = await widget.apiClient.getAsrJobs();
    if (!mounted || epoch != _jobsEpoch) return;
    _readingJobs = false;
    setState(() {
      _jobsError = response.error;
      if (response.ok) {
        _jobs = newestRecords(response.data!);
        _jobsSnapshotRevision = epoch;
      }
    });
  }

  Map<String, dynamic> _payload() => {
        for (final e in _fields.entries) e.key: e.value.text.trim(),
        'mode': _mode,
        'managed_id': _managedId,
        'enabled': _enabled,
        'delete_source': _delete,
        'min_chars': 1500,
        'clear_api_key': _clearKey,
      };

  Future<void> _openModels() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => AsrModelsPage(api: widget.apiClient)));
    if (changed != true || !mounted) return;
    final response = await widget.apiClient.getAsrSettings();
    if (!mounted) return;
    if (!response.ok) {
      setState(() => _error = response.error);
      return;
    }
    final data = response.data!;
    // Preserve unsaved output, switch and credential drafts when returning.
    for (final key in [
      'python_path',
      'model_path',
      'aligner_path',
      'ffmpeg_path',
      'model'
    ]) {
      _fields[key]!.text = '${data[key] ?? ''}';
    }
    if (_fields['output_dir']!.text.trim().isEmpty) {
      _fields['output_dir']!.text = '${data['output_dir'] ?? ''}';
    }
    setState(() {
      _mode = '${data['mode'] ?? 'local_qwen'}';
      _managedId = '${data['managed_id'] ?? ''}';
      _message = '已更新转写模型；其他未保存设置仍保留。';
    });
  }

  Future<void> _action(String action) async {
    if (_busy || !_loadedSettings) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final response = action == 'detect'
          ? await widget.apiClient.detectAsrSettings()
          : action == 'save'
              ? await widget.apiClient.saveAsrSettings(_payload())
              : await widget.apiClient.testAsrSettings(_payload());
      if (!mounted) return;
      if (!response.ok) {
        setState(() {
          _error = response.error;
        });
        return;
      }
      if (action == 'detect') {
        for (final e in response.data!.entries) {
          if (_fields.containsKey(e.key) && '${e.value}'.isNotEmpty) {
            _fields[e.key]!.text = '${e.value}';
          }
        }
        setState(() {
          _message = '已填写检测到的路径，请测试后保存。';
        });
      } else if (action == 'save') {
        _fields['api_key']!.clear();
        setState(() {
          _keySet = response.data!['api_key_set'] == true;
          _clearKey = false;
          _message = _enabled ? '已保存：新上传的录音将自动入队转写。' : '已保存：自动转写已关闭。';
        });
      } else {
        setState(() {
          _message = '${response.data!['message']}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '操作失败：$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Widget _field(String key, String label,
          {String? hint, bool secret = false}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            enabled: !_busy && _loadedSettings,
            controller: _fields[key],
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: !secret,
            maxLines: 1,
            decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                border: const OutlineInputBorder(),
                suffixIcon: key == 'output_dir'
                    ? IconButton(
                        tooltip: '选择转写文件夹',
                        icon: const Icon(Icons.folder_open),
                        onPressed: _busy || !_loadedSettings
                            ? null
                            : () async {
                                final path =
                                    await ScheduleFilePicker.pickDirectory();
                                if (mounted && path != null) {
                                  _fields[key]!.text = path;
                                }
                              })
                    : null),
          ));

  Future<void> _openAllJobs() async {
    await Navigator.of(context).push(studyReadingRoute(
        context, (_) => AsrJobsPage(apiClient: widget.apiClient)));
    if (mounted) await _refreshJobs(force: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('录音自动转写')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 840),
                    child:
                        ListView(padding: const EdgeInsets.all(20), children: [
                      if (_editable)
                        Card(
                            child: ListTile(
                                leading: const Icon(Icons.download_outlined),
                                title: const Text('模型下载与部署'),
                                subtitle: const Text('自动检测显卡，选择模型并在应用内测试'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: _busy ? null : _openModels)),
                      if (_editable && _error != null && !_loadedSettings)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      if (!_loadedSettings && _editable)
                        TextButton(
                            onPressed: _busy ? null : _load,
                            child: const Text('重新加载设置')),
                      if (_editable && _loadedSettings)
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                  '电脑确认录音上传完整后，用所选模型转写并保存 TXT。电脑关机或手机离线时，录音保留在手机，连回电脑后继续上传。'),
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('上传完成后自动转写'),
                                  subtitle: const Text('设置修改后需点击保存；不会扫描历史录音。'),
                                  value: _enabled,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() {
                                            _enabled = v;
                                            _message = null;
                                          })),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  value: _mode,
                                  isExpanded: true,
                                  isDense: false,
                                  itemHeight: _choiceHeight(context),
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                  decoration: const InputDecoration(
                                      labelText: '接入方式',
                                      border: OutlineInputBorder()),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'local_whisper',
                                        child: Text('应用内 Whisper 模型',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    DropdownMenuItem(
                                        value: 'local_qwen',
                                        child: Text('本机 Qwen 环境',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    DropdownMenuItem(
                                        value: 'qwen_service',
                                        child: Text('Qwen 转写服务',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) {
                                          if (v != null && v != _mode) {
                                            setState(() {
                                              _mode = v;
                                              _managedId = '';
                                              _message = null;
                                            });
                                          }
                                        }),
                              const SizedBox(height: 20),
                              _field('output_dir', '转写文件保存文件夹'),
                              if (_managedId.isNotEmpty) ...[
                                Text('当前模型：${_fields['model']!.text}'),
                                const Text(
                                    '由应用管理运行环境和模型文件；切换或测试模型请进入上方“模型下载与部署”。'),
                              ] else if (_mode == 'local_qwen') ...[
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () => _action('detect'),
                                        icon: const Icon(Icons.search),
                                        label: const Text('检测本机 Qwen'))),
                                _field('python_path', 'Qwen 环境 Python 可执行文件'),
                                _field('model_path', 'Qwen3-ASR-1.7B 模型文件夹'),
                                _field('aligner_path',
                                    'Qwen3-ForcedAligner-0.6B 文件夹'),
                                _field('ffmpeg_path', 'FFmpeg 可执行文件'),
                                const Text(
                                    '使用你已安装的 Qwen 环境。GPU 失败时会降级到同一模型的 CPU，不会自动安装或更换引擎。'),
                              ] else if (_mode == 'local_whisper') ...[
                                const Text('请在“模型下载与部署”中选择已测试通过的 Whisper 模型。'),
                              ] else ...[
                                _field('base_url', '服务基础地址',
                                    hint: '例如 https://你的服务地址/v1'),
                                _field('model', '服务提供的 Qwen 模型名'),
                                _field('api_key',
                                    _keySet ? '密钥已保存；留空沿用' : 'API 密钥（服务未要求可留空）',
                                    secret: true),
                                if (_keySet)
                                  CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('保存时清除已有密钥'),
                                      value: _clearKey,
                                      onChanged: _busy
                                          ? null
                                          : (v) => setState(() {
                                                _clearKey = v == true;
                                                _message = null;
                                              })),
                                const Text(
                                    '服务需支持 audio/transcriptions。缺少时长或可靠时间戳时会保留源音频。'),
                              ],
                              const SizedBox(height: 12),
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('转写后删除电脑源录音'),
                                  subtitle: const Text(
                                      '仅在完整转写、不少于 1500 字、转写文件和台账均落盘后删除。未达门槛会保留并显示原因。'),
                                  value: _delete,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() {
                                            _delete = v;
                                            _message = null;
                                          })),
                              const SizedBox(height: 16),
                              if (_busy)
                                const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: LinearProgressIndicator()),
                              if (_message != null)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Text(_message!,
                                        semanticsLabel: _message)),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Text(_error!,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error))),
                              Wrap(spacing: 12, runSpacing: 12, children: [
                                OutlinedButton(
                                    onPressed:
                                        _busy ? null : () => _action('test'),
                                    child: const Text('测试连接')),
                                FilledButton(
                                    onPressed:
                                        _busy ? null : () => _action('save'),
                                    child: const Text('保存设置')),
                              ]),
                            ])
                      else if (!_editable)
                        const Text('自动转写由接收录音的电脑执行。接入方式和保存目录请在 Windows 端设置。'),
                      if (!_editable && _error != null)
                        Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (!_editable && _busy) const LinearProgressIndicator(),
                      const SizedBox(height: 32),
                      RecentRecordsHeader(
                          title: '最近转写任务',
                          onAll: _openAllJobs,
                          hiddenActive: _jobs
                              .skip(recentRecordLimit)
                              .where((j) => ['running', 'queued', 'cancelling']
                                  .contains(j['status']))
                              .length),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: _refreshJobs,
                              icon: const Icon(Icons.refresh),
                              label: const Text('刷新任务'))),
                      if (_jobsError != null)
                        Text(_jobsError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (_jobs.isEmpty && _jobsError == null)
                        const Text('暂无任务。开启后，新上传的录音会显示在这里。'),
                      for (final job in _jobs.take(recentRecordLimit))
                        _jobCard(job),
                    ]))),
      );

  Widget _jobCard(Map<String, dynamic> job) => AsrJobCard(
      key: ValueKey('asr-${job['id']}'),
      job: job,
      apiClient: widget.apiClient,
      snapshotRevision: _jobsSnapshotRevision,
      refreshSnapshot: () async {
        await _refreshJobs(force: true);
        return _jobsEpoch;
      });
}
