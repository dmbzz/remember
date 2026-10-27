import 'package:flutter/services.dart';

/// Android native settings and local reminders. No computer connection needed.
class CourseReminderBridge {
  static const channel = MethodChannel('class_notes/course_reminders');
  static Future<Map<String, dynamic>> status() async {
    try {
      return (await channel.invokeMapMethod<String, dynamic>('status')) ?? {};
    } on MissingPluginException {
      return {};
    }
  }

  static Future<void> refresh() async {
    try {
      await channel.invokeMethod('refresh');
    } on MissingPluginException {
      /* Desktop and tests have no native reminder bridge. */
    }
  }

  static Future<void> test() => channel.invokeMethod('test');
  static Future<void> openExactAlarms() =>
      channel.invokeMethod('openExactAlarms');
  static Future<void> openNotifications() =>
      channel.invokeMethod('openNotifications');
}
