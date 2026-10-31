import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../data/api_client.dart';
import '../../data/pairing_connector.dart';
import '../../platform/local_backend_bootstrap.dart';
import '../schedule/schedule_store.dart';

class ShortPairingCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    String normalize(String value) =>
        normalizePairingDigits(value).replaceAll(RegExp(r'\s+'), '');
    final text = normalize(newValue.text);
    if (!RegExp(r'^[0-9]{0,6}$').hasMatch(text)) return oldValue;
    int position(int offset) => normalize(
            newValue.text.substring(0, offset.clamp(0, newValue.text.length)))
        .length;
    final selection = newValue.selection.isValid
        ? TextSelection(
            baseOffset: position(newValue.selection.baseOffset),
            extentOffset: position(newValue.selection.extentOffset))
        : TextSelection.collapsed(offset: text.length);
    return TextEditingValue(text: text, selection: selection);
  }
}

class PairingPage extends StatefulWidget {
  final ApiClient apiClient;
  final bool? desktop;
  const PairingPage({super.key, required this.apiClient, this.desktop});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> with WidgetsBindingObserver {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _manualController = TextEditingController();
  bool _committing = false;
  int _attempt = 0;
  bool get _desktop => widget.desktop ?? Platform.isWindows;
  Map<String, dynamic>? _info;
  String? _error;
  bool _loading = false;
  bool _connected = false;
  int _remaining = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_desktop) {
      _loadInfo();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _info == null) return;
        if (_remaining <= 1) {
          setState(() => _remaining = 0);
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
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    ++_attempt;
    widget.apiClient.cancelPairing();
    _manualController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_desktop &&
        state != AppLifecycleState.resumed &&
        _loading &&
        !_committing) {
      _cancelConnect();
    }
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
    final generation = _attempt;
    final result = await widget.apiClient.checkPairing();
    if (mounted && generation == _attempt) {
      setState(() => _connected = result.ok);
    }
  }

  bool _active(int attempt) => mounted && attempt == _attempt;

  void _cancelConnect() {
    if (_committing) return;
    ++_attempt;
    widget.apiClient.cancelPairing();
    if (mounted) {
      setState(() {
        _loading = false;
        _error = null;
      });
    }
  }

  Future<void> _connect([String? manual]) async {
    if (_loading) return;
    final value = manual ?? _codeController.text;
    if (manual == null && !RegExp(r'^[0-9]{6}$').hasMatch(value)) {
      setState(() => _error = '请输入电脑显示的6位数字连接码。');
      return;
    }
    final attempt = ++_attempt;
    setState(() {
      _loading = true;
      _error = null;
    });
    final paired = await widget.apiClient.pairWithComputer(value);
    if (!_active(attempt)) return;
    if (!paired.ok) {
      setState(() {
        _loading = false;
        _error = paired.error;
      });
      return;
    }
    // The connector has checked the candidate using its own temporary client.
    // Keep the live connection untouched until both preferences are saved.
    SharedPreferences? prefs;
    String? oldUrl, oldToken;
    bool saving = false;
    Future<void> restore() async {
      if (!saving || prefs == null) return;
      if (oldUrl == null) {
        await prefs.remove(AppConstants.prefBaseUrl);
      } else {
        await prefs.setString(AppConstants.prefBaseUrl, oldUrl);
      }
      if (oldToken == null) {
        await prefs.remove(AppConstants.prefPairingToken);
      } else {
        await prefs.setString(AppConstants.prefPairingToken, oldToken);
      }
    }

    try {
      prefs = await SharedPreferences.getInstance();
      if (!_active(attempt)) return;
      oldUrl = prefs.getString(AppConstants.prefBaseUrl);
      oldToken = prefs.getString(AppConstants.prefPairingToken);
      setState(() => _committing = true);
      saving = true;
      final url = paired.data!['base_url']!, token = paired.data!['token']!;
      if (!await prefs.setString(AppConstants.prefBaseUrl, url) ||
          !await prefs.setString(AppConstants.prefPairingToken, token)) {
        throw StateError('手机未确认保存连接');
      }
      if (!_active(attempt)) {
        await restore();
        return;
      }
      widget.apiClient.updateBaseUrl(url);
      widget.apiClient.updatePairingToken(token);
      saving = false;
      setState(() {
        _committing = false;
        _loading = false;
        _connected = true;
      });
      widget.apiClient.onConnectionReady?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已连接电脑，下次打开自动连接')));
      if (Platform.isAndroid) {
        unawaited(ScheduleStore.refreshWidget(widget.apiClient));
      }
      Navigator.pop(context, true);
    } catch (error) {
      var restored = true;
      try {
        await restore();
      } catch (_) {
        restored = false;
      }
      if (_active(attempt)) {
        setState(() {
          _loading = false;
          _error = !saving
              ? '电脑已连接，但自动刷新未完成，请返回后手动刷新。'
              : restored
                  ? '保存连接失败，原有连接已保留。请重试。'
                  : '手机未能完整保存连接，请重新连接。';
        });
      }
    } finally {
      if (mounted && _committing) setState(() => _committing = false);
    }
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
    return PopScope(
        canPop: !_committing,
        child: Scaffold(
          appBar: AppBar(title: Text(_desktop ? '连接手机' : '连接电脑')),
          body: Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: _desktop ? _desktopContent() : _phoneContent(),
            ),
          )),
        ));
  }

  List<Widget> _desktopContent() {
    final codes = (_info?['connection_codes'] as List? ?? const [])
        .map((v) => '$v')
        .toList();
    final pin = '${_info?['code'] ?? ''}';
    final formatted = RegExp(r'^[0-9]{6}$').hasMatch(pin);
    final valid = formatted && _remaining > 0;
    return [
      _header(
          Icons.phonelink_rounded, '手机输入6位数字即可', '手机和电脑连接同一 Wi-Fi，或让手机连接电脑热点。'),
      const SizedBox(height: 18),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('6 位连接码',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    if (_loading && _info == null)
                      const LinearProgressIndicator()
                    else if (!valid)
                      Text(formatted
                          ? (_loading ? '连接码已过期，正在获取新码…' : '连接码已过期，请刷新。')
                          : '暂时无法取得连接码，请刷新重试。')
                    else
                      Row(children: [
                        Expanded(
                            child: Semantics(
                                label: '连接码 $pin',
                                excludeSemantics: true,
                                child: Wrap(spacing: 16, children: [
                                  for (final group in [
                                    pin.substring(0, 3),
                                    pin.substring(3)
                                  ])
                                    SelectableText(group,
                                        style: TextStyle(
                                            fontSize: 48,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 4,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary)),
                                ]))),
                        IconButton(
                            tooltip: '复制6位数字',
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: pin));
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('6位连接码已复制')));
                              }
                            })
                      ]),
                    const SizedBox(height: 12),
                    const Text('无需输入 IP 地址和端口。手机会自动寻找这台电脑。'),
                    const SizedBox(height: 8),
                    Text(
                        '约 ${(_remaining / 60).floor()} 分 ${(_remaining % 60).toString().padLeft(2, '0')} 秒后更新 · 已连接 ${_info?['paired_devices'] ?? 0} 台手机',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12)),
                  ]))),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 8, children: [
        OutlinedButton.icon(
            onPressed: _loading ? null : _loadInfo,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新连接码')),
        if ((_info?['paired_devices'] as num? ?? 0) > 0)
          TextButton(
              onPressed: _loading ? null : _revoke,
              child: const Text('断开所有手机')),
      ]),
      const SizedBox(height: 16),
      Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
              title: const Text('手动连接地址'),
              subtitle: const Text('手机自动寻找失败时使用'),
              children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (codes.isEmpty) const Text('暂未检测到局域网地址，请确认电脑网络。'),
                          if (!valid && codes.isNotEmpty)
                            const Text('请刷新连接码后再使用手动地址。'),
                          for (final code in valid ? codes : <String>[])
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: SelectableText(code)),
                        ]))
              ])),
      const SizedBox(height: 20),
      Text('仅在可信的私人局域网使用。若自动寻找失败，请允许 Windows 防火墙的专用网络访问，或使用手动连接地址。',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5)),
      if (_error != null) ...[const SizedBox(height: 14), _errorCard(_error!)],
    ];
  }

  List<Widget> _phoneContent() => [
        _header(Icons.devices_rounded, '连接到你的电脑',
            '电脑打开 Remember → 连接手机，输入电脑显示的6位数字。'),
        const SizedBox(height: 20),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                          key: const ValueKey('pairing-short-code'),
                          controller: _codeController,
                          enabled: !_loading,
                          keyboardType: TextInputType.number,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.done,
                          inputFormatters: [ShortPairingCodeFormatter()],
                          onChanged: (_) {
                            if (_error != null) setState(() => _error = null);
                          },
                          decoration: const InputDecoration(
                              labelText: '6位码',
                              hintText: '例如 123456',
                              prefixIcon: Icon(Icons.key_rounded),
                              helperText: '只需6位数字，自动寻找同一网络内的电脑',
                              helperMaxLines: 3),
                          onSubmitted: (_) => _connect()),
                      const SizedBox(height: 16),
                      SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                              onPressed: _loading ? null : () => _connect(),
                              icon: _loading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.link_rounded),
                              label: Text(_committing
                                  ? '正在保存连接…'
                                  : _loading
                                      ? '正在寻找并连接…'
                                      : '连接电脑'))),
                      if (_loading && !_committing)
                        TextButton(
                            onPressed: _cancelConnect,
                            child: const Text('取消连接')),
                    ]))),
        if (_connected) ...[
          const SizedBox(height: 14),
          Text('当前手机已连接电脑。输入新连接码可以切换电脑。',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant))
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          _errorCard(_error!)
        ],
        const SizedBox(height: 16),
        Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
                maintainState: true,
                title: const Text('手动连接'),
                subtitle: const Text('自动寻找失败，或使用旧版完整连接码'),
                children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Column(children: [
                        TextField(
                            key: const ValueKey('pairing-full-code'),
                            controller: _manualController,
                            enabled: !_loading,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                                labelText: '完整码',
                                hintText: '192.168.137.1:8000#123456'),
                            onSubmitted: (_) =>
                                _connect(_manualController.text)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _loading
                                ? null
                                : () => _connect(_manualController.text),
                            child: const Text('按地址连接'))
                      ]))
                ])),
        const SizedBox(height: 22),
        Text('两台设备需处于同一私人局域网。配对后手机会记住电脑，下次自动连接。',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5)),
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
