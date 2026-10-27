import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../data/api_client.dart';
import '../../platform/local_backend_bootstrap.dart';
import '../schedule/schedule_store.dart';

class PairingPage extends StatefulWidget {
  final ApiClient apiClient;
  const PairingPage({super.key, required this.apiClient});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final TextEditingController _codeController = TextEditingController();
  Map<String, dynamic>? _info;
  String? _error;
  bool _loading = false;
  bool _connected = false;
  int _remaining = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _loadInfo();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _info == null) return;
        if (_remaining <= 1) {
          _loadInfo();
        } else {
          setState(() => _remaining--);
        }
      });
    } else {
      _checkExisting();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    for (var attempt = 0; attempt < 12; attempt++) {
      final result = await widget.apiClient.getPairingInfo();
      if (!mounted) return;
      if (result.ok) {
        setState(() {
          _info = result.data;
          _remaining =
              (result.data?['expires_in_seconds'] as num?)?.toInt() ?? 0;
          _loading = false;
        });
        return;
      }
      final connectionError = (result.error ?? '').startsWith('无法连接后端') ||
          (result.error ?? '').startsWith('连接后端超时');
      if (!connectionError || attempt == 11) {
        setState(() {
          _error = LocalBackendBootstrap.lastError ?? result.error;
          _loading = false;
        });
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _checkExisting() async {
    if (widget.apiClient.pairingToken == null) return;
    final result = await widget.apiClient.checkPairing();
    if (mounted) setState(() => _connected = result.ok);
  }

  Future<void> _connect() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final paired =
        await widget.apiClient.pairWithComputer(_codeController.text);
    if (!mounted) return;
    if (!paired.ok) {
      setState(() {
        _loading = false;
        _error = paired.error;
      });
      return;
    }

    final oldUrl = widget.apiClient.baseUrl;
    final oldToken = widget.apiClient.pairingToken;
    final newUrl = paired.data!['base_url']!;
    final newToken = paired.data!['token']!;
    widget.apiClient.updateBaseUrl(newUrl);
    widget.apiClient.updatePairingToken(newToken);
    final checked = await widget.apiClient.checkPairing();
    if (!checked.ok) {
      widget.apiClient.updateBaseUrl(oldUrl);
      widget.apiClient.updatePairingToken(oldToken);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = checked.error;
        });
      }
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.prefBaseUrl, newUrl);
      await prefs.setString(AppConstants.prefPairingToken, newToken);
      widget.apiClient.onConnectionReady?.call();
    } catch (error) {
      widget.apiClient.updateBaseUrl(oldUrl);
      widget.apiClient.updatePairingToken(oldToken);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '连接已建立，但保存到手机失败：$error';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _connected = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已连接电脑，之后打开应用会自动使用此连接')),
    );
    if (Platform.isAndroid) {
      unawaited(ScheduleStore.refreshWidget(widget.apiClient));
    }
    Navigator.pop(context, true);
  }

  Future<void> _revoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开所有手机？'),
        content: const Text('已连接手机的访问令牌会立即失效，之后可重新用连接码配对。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('断开')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.apiClient.revokeAllPairings();
    if (!mounted) return;
    if (result.ok) {
      await _loadInfo();
    } else {
      setState(() => _error = result.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Platform.isWindows ? '连接手机' : '连接电脑')),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: Platform.isWindows ? _desktopContent() : _phoneContent(),
        ),
      )),
    );
  }

  List<Widget> _desktopContent() {
    final codes = (_info?['connection_codes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    return [
      _header(Icons.phonelink_rounded, '在手机上输入连接码',
          '让手机和电脑接入同一个 Wi-Fi，打开手机端「连接电脑」。'),
      const SizedBox(height: 18),
      Card(
          child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('连接码', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (_loading && _info == null)
            const LinearProgressIndicator()
          else if (codes.isEmpty)
            const Text('暂未检测到局域网地址。请确认电脑已连接 Wi-Fi 或有线网络。')
          else ...[
            for (final code in codes) ...[
              Text(
                  code.startsWith('192.168.137.1:')
                      ? '电脑热点 · 手机需连接这台电脑的热点'
                      : '当前网络 · 手机需与电脑位于同一网络',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(height: 5),
              Row(children: [
                Expanded(
                    child: SelectableText(code,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accent,
                        ))),
                IconButton(
                  tooltip: '复制这条连接码',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('连接码已复制')));
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ]),
              const SizedBox(height: 15),
            ],
          ],
          const SizedBox(height: 12),
          Text(
              '约 ${(_remaining / 60).floor()} 分 ${(_remaining % 60).toString().padLeft(2, '0')} 秒后更新 · 已连接 ${_info?['paired_devices'] ?? 0} 台手机',
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        ]),
      )),
      const SizedBox(height: 16),
      Row(children: [
        OutlinedButton.icon(
            onPressed: _loading ? null : _loadInfo,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新连接码')),
        const SizedBox(width: 12),
        if ((_info?['paired_devices'] as num? ?? 0) > 0)
          TextButton(onPressed: _revoke, child: const Text('断开所有手机')),
      ]),
      const SizedBox(height: 20),
      const Text('仅在可信的私人局域网使用。若手机连接超时，请检查电脑和手机是否在同一网络，并允许 Windows 防火墙的专用网络访问。',
          style: TextStyle(color: AppTheme.muted, height: 1.5)),
      if (_error != null) ...[const SizedBox(height: 14), _errorCard(_error!)],
    ];
  }

  List<Widget> _phoneContent() => [
        _header(Icons.devices_rounded, '连接到你的电脑',
            '电脑端打开 remember，点击「连接手机」，然后把显示的完整连接码输入这里。'),
        const SizedBox(height: 20),
        Card(
            child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '连接码',
                hintText: '192.168.1.10:8000#123456',
                prefixIcon: Icon(Icons.key_rounded),
              ),
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 16),
            SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loading ? null : _connect,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.link_rounded),
                  label: Text(_loading ? '正在连接…' : '连接电脑'),
                )),
          ]),
        )),
        if (_connected) ...[
          const SizedBox(height: 14),
          const Text('当前手机已连接电脑。输入新连接码可以切换到另一台电脑。',
              style: TextStyle(color: AppTheme.muted)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          _errorCard(_error!)
        ],
        const SizedBox(height: 22),
        const Text('连接时两台设备须处于同一私人局域网。配对完成后，手机会记住电脑地址和访问令牌。',
            style: TextStyle(color: AppTheme.muted, height: 1.5)),
      ];

  Widget _header(IconData icon, String title, String subtitle) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 32),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ])),
        ]),
      );

  Widget _errorCard(String message) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(message,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer))),
      );
}
