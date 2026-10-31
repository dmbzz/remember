import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/api_client.dart';
import '../../data/api_result.dart';
import '../../platform/schedule_file_picker.dart';

class AsrModelsPage extends StatefulWidget {
  const AsrModelsPage({super.key, required this.api});
  final ApiClient api;
  @override
  State<AsrModelsPage> createState() => _AsrModelsPageState();
}

class _AsrModelsPageState extends State<AsrModelsPage> {
  static const active = {
    'preparing',
    'environment',
    'dependencies',
    'downloading',
    'verifying',
    'waiting_engine',
    'testing'
  };
  Map<String, dynamic>? _catalog;
  Map<String, dynamic> _operation = {};
  String? _selected, _error, _message, _autoActivate;
  String _channel = 'auto', _device = 'auto';
  bool _loading = true,
      _requesting = false,
      _polling = false,
      _changed = false,
      _pollError = false;
  Timer? _timer;
  final _reference = TextEditingController();
  int _generation = 0;
  bool get _busy =>
      _loading || _requesting || active.contains(_operation['status']);

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && TickerMode.of(context)) _poll();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _pollError = false;
    });
    final result = await widget.api.getAsrModels(refresh: refresh);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _error = result.error;
      if (result.ok) {
        _catalog = result.data!;
        _operation =
            (_catalog!['operation'] as Map? ?? {}).cast<String, dynamic>();
        _selected ??=
            '${(_catalog!['hardware'] as Map?)?['recommended_id'] ?? 'qwen-0.6b'}';
      }
    });
  }

  Future<void> _poll() async {
    if (_polling || _requesting || _loading || _catalog == null) return;
    _polling = true;
    final generation = _generation;
    try {
      final result = await widget.api.getAsrModelOperation();
      if (!mounted || generation != _generation) return;
      if (!result.ok) {
        setState(() {
          _error = '状态刷新失败：${result.error}';
          _pollError = true;
        });
        return;
      }
      final value = result.data!;
      final finished = active.contains(_operation['status']) &&
          !active.contains(value['status']);
      setState(() {
        _operation = value;
        if (_pollError) {
          _error = null;
          _pollError = false;
        }
      });
      if (finished) {
        final fresh = await widget.api.getAsrModels();
        if (!mounted || generation != _generation) return;
        if (fresh.ok) setState(() => _catalog = fresh.data!);
      }
      if (value['status'] == 'ready' && _autoActivate == value['id']) {
        _autoActivate = null;
        await _activate('${value['deployment_id']}');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _perform(
      Future<ApiResult<Map<String, dynamic>>> Function() action,
      {bool install = false}) async {
    if (_busy) return;
    ++_generation;
    setState(() {
      _requesting = true;
      _pollError = false;
      _error = null;
      _message = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _error = result.error;
        if (result.ok) {
          _operation = result.data!;
          if (install) _autoActivate = '${_operation['id']}';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '操作未完成：$e');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _activate(String deployment) async {
    if (_requesting) return;
    ++_generation;
    setState(() {
      _requesting = true;
      _pollError = false;
    });
    try {
      final result = await widget.api.activateAsrModel(deployment);
      if (!mounted) return;
      setState(() {
        _error = result.error;
        if (result.ok) {
          _changed = true;
          _message = '模型已部署并设为转写模型。自动转写开关和原有文件未改动。';
        }
      });
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _testFile(String deployment) async {
    if (_busy) return;
    setState(() => _requesting = true);
    try {
      final file = await ScheduleFilePicker.pickAudio();
      if (!mounted || file == null) return;
      setState(() => _requesting = false);
      await _perform(() => widget.api.testAsrAudio(
          deployment, file.name, file.bytes, _reference.text.trim()));
    } catch (e) {
      if (mounted) setState(() => _error = '无法选择测试音频：$e');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _cancel() async {
    if (_requesting) return;
    ++_generation;
    setState(() {
      _requesting = true;
      _pollError = false;
    });
    final result = await widget.api.cancelAsrModelOperation();
    if (mounted) {
      setState(() {
        _requesting = false;
        _error = result.error;
        _autoActivate = null;
        _message = result.ok ? '正在停止当前操作，已下载分片会保留。' : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
          appBar: AppBar(title: const Text('模型下载与部署')),
          body: _loading && _catalog == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            const Text(
                                '选择模型后，应用会准备独立环境、下载并校验文件，再运行中文样例测试。留在此页会在通过后设为转写模型；离开后可回来点击“使用此模型”。失败保留原配置。首次可能需要数 GB 空间。'),
                            const SizedBox(height: 16),
                            if (_catalog != null) _hardware(context),
                            if (_error != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            if (_message != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(_message!)),
                            if (_catalog == null)
                              TextButton(
                                  onPressed: _load, child: const Text('重新加载')),
                            if (_catalog != null) ...[
                              Wrap(spacing: 12, runSpacing: 12, children: [
                                SizedBox(
                                    width: 300,
                                    child: DropdownButtonFormField<String>(
                                        value: _channel,
                                        isExpanded: true,
                                        isDense: false,
                                        itemHeight: _choiceHeight(context),
                                        decoration: const InputDecoration(
                                            labelText: '下载渠道',
                                            border: OutlineInputBorder()),
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'hf_mirror',
                                              child: Text('HF 镜像（第三方）',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          DropdownMenuItem(
                                              value: 'auto',
                                              child: Text('自动选择',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          DropdownMenuItem(
                                              value: 'modelscope',
                                              child: Text('ModelScope（Qwen）',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          DropdownMenuItem(
                                              value: 'huggingface',
                                              child: Text('Hugging Face',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis))
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (v) =>
                                                setState(() => _channel = v!))),
                                SizedBox(
                                    width: 240,
                                    child: DropdownButtonFormField<String>(
                                        value: _device,
                                        isExpanded: true,
                                        isDense: false,
                                        itemHeight: _choiceHeight(context),
                                        decoration: const InputDecoration(
                                            labelText: '运行设备',
                                            border: OutlineInputBorder()),
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'auto',
                                              child: Text('自动检测',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          DropdownMenuItem(
                                              value: 'cpu',
                                              child: Text('仅 CPU',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis))
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (v) =>
                                                setState(() => _device = v!))),
                              ]),
                              const SizedBox(height: 16),
                              const Text(
                                  '自动渠道：Qwen 使用 ModelScope，Whisper 使用 HF 第三方镜像；运行库使用清华 PyPI 镜像。可手动选择 Hugging Face 官方渠道。'),
                              for (final raw in _catalog!['models'] as List)
                                _model(context,
                                    (raw as Map).cast<String, dynamic>()),
                              const SizedBox(height: 12),
                              if (_channel == 'modelscope' &&
                                  (_selected?.startsWith('whisper') ?? false))
                                const Text('Whisper 请选择自动渠道或 Hugging Face。'),
                              FilledButton.icon(
                                  onPressed: _busy ||
                                          _selected == null ||
                                          (_channel == 'modelscope' &&
                                              _selected!.startsWith('whisper'))
                                      ? null
                                      : () => _perform(
                                          () => widget.api.installAsrModel(
                                              _selected!, _channel, _device),
                                          install: true),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('下载并部署所选模型')),
                              const SizedBox(height: 12),
                              if (_operation.isNotEmpty) _progress(context),
                              const SizedBox(height: 24),
                              Text('已下载模型与音频测试',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const Text(
                                  '测试不会上传到云端、生成课堂笔记或删除原录音。可使用官方中文样例，也可选择60秒以内、20MB以内的音频。'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: _reference,
                                  maxLines: 3,
                                  enabled: !_busy,
                                  decoration: const InputDecoration(
                                      labelText: '参考文字（可选）',
                                      helperText:
                                          '测试自己的音频时填写，可计算忽略标点和空格的字错率 CER',
                                      border: OutlineInputBorder())),
                              for (final raw
                                  in (_catalog!['installations'] as List? ??
                                      []))
                                _installed(context,
                                    (raw as Map).cast<String, dynamic>()),
                            ],
                          ])))));

  Widget _hardware(BuildContext context) {
    final hardware = (_catalog!['hardware'] as Map?) ?? {};
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('硬件自动检测', style: Theme.of(context).textTheme.titleMedium),
              for (final gpu in hardware['gpus'] as List? ?? [])
                Text(
                    '${gpu['name']} · 显存 ${((gpu['memory_mb'] as num) / 1024).toStringAsFixed(1)} GB · 当前可用 ${((gpu['free_mb'] as num) / 1024).toStringAsFixed(1)} GB · 驱动 ${gpu['driver']}'),
              Text('${hardware['message'] ?? ''}'),
              Text('${hardware['vram_note'] ?? ''}',
                  style: Theme.of(context).textTheme.bodySmall),
              TextButton.icon(
                  onPressed: _busy ? null : () => _load(refresh: true),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新检测硬件')),
            ])));
  }

  double _choiceHeight(BuildContext context) {
    final painter = TextPainter(
        text: TextSpan(
            text: 'ModelScope（Qwen）',
            style: Theme.of(context).textTheme.titleMedium),
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

  Widget _model(BuildContext context, Map<String, dynamic> model) {
    final recommended =
        (_catalog!['hardware'] as Map?)?['recommended_id'] == model['id'];
    return Card(
        child: RadioListTile<String>(
            value: '${model['id']}',
            groupValue: _selected,
            onChanged: _busy ? null : (v) => setState(() => _selected = v),
            title: Text('${model['name']}${recommended ? ' · 推荐' : ''}'),
            subtitle: Text(
                '${model['description']}\n建议显存 ≥ ${model['vram_gb']} GB · 模型文件约 ${model['download_gb']} GB（运行库另计）\n${model['license']} · ${model['source']}')));
  }

  Widget _progress(BuildContext context) {
    const names = {
      'preparing': '准备部署',
      'environment': '准备独立运行环境',
      'dependencies': '下载并安装运行库',
      'downloading': '下载并校验模型 / 测试资源',
      'verifying': '验证环境与音频',
      'waiting_engine': '等待转写引擎空闲',
      'testing': '正在识别测试音频',
      'ready': '部署完成，音频测试通过',
      'failed': '操作失败，原配置保留',
      'cancelled': '已取消',
      'interrupted': '上次操作已中断'
    };
    final received = _operation['received_bytes'],
        total = _operation['total_bytes'];
    final ratio = received is num && total is num && total > 0
        ? (received / total).clamp(0.0, 1.0).toDouble()
        : null;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${_operation['model_id']} · ${names[_operation['status']] ?? _operation['status']}'),
              if (active.contains(_operation['status'])) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value:
                        _operation['status'] == 'downloading' ? ratio : null),
                if (ratio != null && _operation['status'] == 'downloading')
                  Text(
                      '${(ratio * 100).toStringAsFixed(0)}% · ${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB'),
                TextButton(
                    onPressed: _requesting ? null : _cancel,
                    child: const Text('取消当前操作')),
              ],
              if (_operation['error'] != null)
                Text('${_operation['error']}',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (_operation['result'] is Map)
                _result((_operation['result'] as Map).cast<String, dynamic>()),
            ])));
  }

  Widget _result(Map<String, dynamic> result) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 8),
        Text(
            '实际设备：${result['device']} · 音频 ${result['duration_sec']}秒 · 耗时 ${result['elapsed_sec']}秒'),
        Text(result['peak_vram_mb'] == null
            ? '显存峰值：此引擎未提供可靠数值'
            : '模型分配显存峰值：${result['peak_vram_mb']} MB'),
        if (result['cer'] is num)
          Text(
              '本段字错率 CER：${((result['cer'] as num) * 100).toStringAsFixed(2)}%（非通用准确率）'),
        SelectableText('${result['text'] ?? ''}'),
      ]);

  Widget _installed(BuildContext context, Map<String, dynamic> value) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '${value['name']} · ${value['verified'] == true ? '测试通过' : '已下载，待测试'}',
                style: Theme.of(context).textTheme.titleMedium),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(() =>
                          widget.api.testAsrModel('${value['deployment_id']}')),
                  child: const Text('测试中文样例')),
              OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _testFile('${value['deployment_id']}'),
                  child: const Text('选择音频测试')),
              FilledButton(
                  onPressed: _busy || value['verified'] != true
                      ? null
                      : () => _activate('${value['deployment_id']}'),
                  child: const Text('使用此模型')),
            ]),
            if (value['last_test'] is Map)
              _result((value['last_test'] as Map).cast<String, dynamic>()),
          ])));
}
