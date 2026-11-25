import 'package:flutter/services.dart';
import '../core/constants.dart';

/// Destructive actions are checked against the private recording directory and
/// current native session. They never delete a computer recording or transcript.
class LocalRecordingActions {
  static const _channel = MethodChannel(AppConstants.channelAudioRecorder);

  static Future<void> deleteFile(String filePath) async {
    final deleted = await _channel
        .invokeMethod<bool>('deleteRecordingFile', {'filePath': filePath});
    if (deleted != true) throw StateError('手机录音未能删除，请重试');
  }

  static Future<void> discardSession(String sessionId) async {
    final deleted = await _channel
        .invokeMethod<bool>('discardRecording', {'sessionId': sessionId});
    if (deleted != true) throw StateError('录音未能删除，请查看手机录音记录');
  }
}
