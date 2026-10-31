import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/orientation_capsule.dart';
import '../../data/api_client.dart';
import '../recording/recent_records.dart';
import 'asr_job_card.dart';

/// A separate full-history route. Returning never rebuilds the ASR settings form.
class AsrJobsPage extends StatefulWidget {
  const AsrJobsPage({super.key, required this.apiClient});
  final ApiClient apiClient;
  @override
  State<AsrJobsPage> createState() => _AsrJobsPageState();
}

class _AsrJobsPageState extends State<AsrJobsPage> {
  List<Map<String, dynamic>> _jobs = [];
  bool _reading = false, _loaded = false;
  String? _error;
  Timer? _timer;
  int _epoch = 0;
  int _snapshotRevision = 0;
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

  Future<void> _refresh({bool force = false}) async {
    if (_reading && !force) return;
    final epoch = ++_epoch;
    setState(() => _reading = true);
    final response = await widget.apiClient.getAllAsrJobs();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _reading = false;
      _loaded = true;
      _error = response.error;
      if (response.ok) {
        _jobs = newestRecords(response.data!);
        _snapshotRevision = epoch;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('全部转写任务'), actions: [
        IconButton(
            onPressed: _reading ? null : _refresh,
            tooltip: '刷新全部转写任务',
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(
          padding: EdgeInsets.fromLTRB(20 + StudyDockContentInset.of(context),
              20, 20, 20 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (_reading) const LinearProgressIndicator(),
            if (_error != null)
              Text('任务刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_loaded && _jobs.isEmpty && _error == null)
              const Text('暂无转写任务'),
            for (final job in _jobs)
              AsrJobCard(
                  key: ValueKey('asr-${job['id']}'),
                  job: job,
                  apiClient: widget.apiClient,
                  snapshotRevision: _snapshotRevision,
                  refreshSnapshot: () async {
                    await _refresh(force: true);
                    return _epoch;
                  }),
          ]));
}
