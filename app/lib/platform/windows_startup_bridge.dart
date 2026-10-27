import 'package:flutter/services.dart';

class WindowsStartupBridge {
  static const channel = MethodChannel('class_notes/windows_startup');
  static Future<bool> getEnabled() async {
    final value = await channel.invokeMethod<bool>('getEnabled');
    if (value == null) throw const FormatException('无法读取开机自启动状态');
    return value;
  }

  static Future<bool> setEnabled(bool enabled) async {
    final actual = await channel.invokeMethod<bool>('setEnabled', enabled);
    if (actual != enabled) throw const FormatException('开机自启动设置未保存');
    return actual!;
  }
}
