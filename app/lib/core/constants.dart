import 'dart:io' show Platform;

/// 应用全局常量与配置项
class AppConstants {
  static const String appName = 'Remember';
  static const String appVersion = '1.0.2';
  static const int appVersionCode = 43;

  /// 默认后端地址（**按平台**取，不能写死一个）。
  ///
  /// 根因说明：原先写死 `http://10.0.2.2:8000`（Android 模拟器访问宿主机的专用地址），
  /// 该地址在 **Windows 桌面端不通**，导致 Windows 端课表「刷不出来」。
  ///
  /// - 桌面端（Windows / Linux / macOS）：走本机回环 `127.0.0.1`；
  /// - Android：`10.0.2.2` 是**模拟器**访问宿主机的地址；**真机**请到「设置 → 后端服务器地址」
  ///   改为电脑的局域网 IP（不写死，用户自填），并会持久化到本地。
  ///
  /// 本工程无 Web 目标（`app/` 下只有 `windows/` 与 `android/`，且 `main.dart` 已直接使用 `dart:io`），
  /// 故此处直接用 `Platform`；若将来新增 Web 目标，需改为条件导入。
  static String get defaultBaseUrl {
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  /// 后端地址的本地持久化键（SharedPreferences）。
  static const String prefBaseUrl = 'cna_base_url';
  static const String prefPairingToken = 'cna_pairing_token';

  // 录音 Platform Channel 名称（严格对照架构设计 §1.6.1）
  static const String channelAudioRecorder = 'class_notes/audio_recorder';
  static const String channelAudioEvents = 'class_notes/audio_recorder_events';

  // 离线存储数据库名称
  static const String localDatabaseName = 'class_notes_local.db';

  // 出处标记
  static const String markerClassroom = '◉课堂';
  static const String markerCourseware = '◉课件';
  static const String markerTextbook = '◉教材';
}
