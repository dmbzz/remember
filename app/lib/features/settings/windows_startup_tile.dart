import 'package:flutter/material.dart';
import '../../platform/windows_startup_bridge.dart';

/// Related settings share one outer shape so adjacent rows do not meet at
/// separate rounded corners. The card also clips hover and focus feedback.
class WindowsStartupGroup extends StatelessWidget {
  const WindowsStartupGroup({
    super.key,
    this.readStartup,
    this.writeStartup,
    required this.readNotifications,
    required this.writeNotifications,
  });

  final Future<bool> Function()? readStartup;
  final Future<bool> Function(bool)? writeStartup;
  final Future<bool> Function() readNotifications;
  final Future<bool> Function(bool) writeNotifications;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          WindowsStartupTile(read: readStartup, write: writeStartup),
          const Divider(height: 1, indent: 64, endIndent: 20),
          WindowsStartupTile(
            title: 'ASR 转写通知',
            description: '转写开始、完成或失败时发送 Windows 通知；可随时关闭',
            icon: Icons.notifications_outlined,
            read: readNotifications,
            write: writeNotifications,
          ),
        ]),
      );
}

class WindowsStartupTile extends StatefulWidget {
  const WindowsStartupTile(
      {super.key,
      this.read,
      this.write,
      this.title = '开机自启动',
      this.description = '登录 Windows 后自动打开，并启动本机服务',
      this.icon = Icons.power_settings_new_rounded});
  final Future<bool> Function()? read;
  final Future<bool> Function(bool)? write;
  final String title, description;
  final IconData icon;
  @override
  State<WindowsStartupTile> createState() => _WindowsStartupTileState();
}

class _WindowsStartupTileState extends State<WindowsStartupTile>
    with WidgetsBindingObserver {
  bool? _enabled;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _read();
  }

  Future<void> _read() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final value = await (widget.read ?? WindowsStartupBridge.getEnabled)();
      if (mounted) {
        setState(() {
          _enabled = value;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取${widget.title}状态，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _set(bool value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved =
          await (widget.write ?? WindowsStartupBridge.setEnabled)(value);
      if (mounted) setState(() => _enabled = saved);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试或重新读取当前状态');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile.adaptive(
          secondary: Icon(widget.icon),
          title: Text(widget.title),
          subtitle: Text(widget.description),
          value: _enabled ?? false,
          onChanged: _busy || _enabled == null ? null : _set,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              TextButton(
                  onPressed: _busy ? null : _read, child: const Text('重新读取')),
            ]),
          ),
      ]);
}
