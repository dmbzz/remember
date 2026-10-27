import 'package:flutter/services.dart';

class ScheduleFile {
  final String name;
  final Uint8List bytes;
  const ScheduleFile(this.name, this.bytes);
}

class ScheduleFilePicker {
  static const channel = MethodChannel('class_notes/schedule_import');
  static Future<String?> pickDirectory() =>
      channel.invokeMethod<String>('pickDirectory');
  static Future<ScheduleFile?> pick() async {
    final value = await channel.invokeMapMethod<String, dynamic>('pickIcs');
    if (value == null) return null;
    final name = value['name'] as String;
    final bytes = value['bytes'] as Uint8List;
    if (!name.toLowerCase().endsWith('.ics')) {
      throw const FormatException('请选择 .ics 日历文件');
    }
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const FormatException('课表文件为空或超过 5 MB');
    }
    return ScheduleFile(name, bytes);
  }
}
