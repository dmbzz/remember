import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class ScheduleWidgetBridge {
  static const channel = MethodChannel('class_notes/schedule_widget');
  static Future<void> sync(Map<String, dynamic> data) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('syncSchedule', {'json': jsonEncode(data)});
    }
  }

  static Future<bool> pin() async =>
      Platform.isAndroid &&
      await channel.invokeMethod<bool>('requestPin') == true;
}
