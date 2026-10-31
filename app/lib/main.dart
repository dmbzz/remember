import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/constants.dart';
import 'core/brand_mark.dart';
import 'core/adaptive_navigation.dart';
import 'core/orientation_capsule.dart';
import 'core/motion.dart';
import 'core/theme.dart';
import 'data/api_client.dart';
import 'data/upload_queue.dart';
import 'data/note_check_controller.dart';
import 'features/notes/note_check_panel.dart';
import 'features/notes/notes_page.dart';
import 'features/pairing/pairing_page.dart';
import 'features/recording/recording_files_page.dart';
import 'features/recording/recording_page.dart';
import 'features/recording/auto_recording_schedule.dart';
import 'features/schedule/schedule_page.dart';
import 'platform/recording_bridge.dart';
import 'platform/recording_bridge_stub.dart';
import 'platform/local_backend_bootstrap.dart';
import 'platform/schedule_widget_bridge.dart';
import 'platform/schedule_file_picker.dart';
import 'platform/local_notes_bridge.dart';
import 'features/schedule/schedule_store.dart';
import 'features/schedule/schedule_settings_page.dart';
import 'features/settings/windows_startup_tile.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    unawaited(LocalBackendBootstrap.ensureRunning());
  }
  // 读取用户持久化的后端地址（设置页可改）；读不到则回退平台默认
  // （桌面端 127.0.0.1，Android 模拟器 10.0.2.2）。
  String? savedBaseUrl;
  String? savedPairingToken;
  try {
    final prefs = await SharedPreferences.getInstance();
    savedBaseUrl = prefs.getString(AppConstants.prefBaseUrl);
    savedPairingToken = prefs.getString(AppConstants.prefPairingToken);
  } catch (_) {}
  // Windows 端始终服务于这台电脑；旧版本保存的远端地址不应阻止本机服务启动。
  if (Platform.isWindows) {
    savedBaseUrl = AppConstants.defaultBaseUrl;
    savedPairingToken = null;
  }
  runApp(ClassNotesApp(
    initialBaseUrl: savedBaseUrl,
    initialPairingToken: savedPairingToken,
  ));
}

class ClassNotesApp extends StatefulWidget {
  /// 启动时读取到的持久化后端地址；为 null 时用平台默认。
  final String? initialBaseUrl;
  final String? initialPairingToken;

  const ClassNotesApp(
      {super.key, this.initialBaseUrl, this.initialPairingToken});

  @override
  State<ClassNotesApp> createState() => _ClassNotesAppState();
}

class _ClassNotesAppState extends State<ClassNotesApp>
    with WidgetsBindingObserver {
  late final ApiClient _apiClient;
  late final RecordingBridge _recordingBridge;
  late final UploadQueue _uploadQueue;
  late final NoteCheckController _noteChecks;
  StreamSubscription<RecordingEvent>? _recordingEvents;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apiClient = ApiClient(
      baseUrl: widget.initialBaseUrl,
      pairingToken: widget.initialPairingToken,
    );
    _recordingBridge =
        Platform.isAndroid ? AndroidRecordingBridge() : StubRecordingBridge();
    _uploadQueue = UploadQueue(apiClient: _apiClient);
    _noteChecks = NoteCheckController(api: _apiClient, enableFileSync: true)
      ..start();
    _apiClient.onConnectionReady = () {
      unawaited(_uploadQueue.reconnect(_recordingBridge));
      _noteChecks.reconnected();
    };
    if (Platform.isAndroid) {
      _recordingEvents = _recordingBridge.eventStream().listen((event) {
        if (event.type != 'autoStopped' || event.payload is! Map) return;
        final item = (event.payload as Map).cast<String, dynamic>();
        final path = item['filePath'] as String? ?? '';
        final course = item['courseId'] as String? ?? '';
        if (path.isNotEmpty && course.isNotEmpty) {
          _uploadQueue.enqueue(
              filePath: path,
              courseId: course,
              lesson: 1,
              classDate: item['classDate'] as String? ?? '');
        }
      });
      unawaited(ScheduleStore.refreshWidget(_apiClient));
      unawaited(_uploadQueue.recoverLocalRecordings(_recordingBridge));
      unawaited(_refreshAutoRecording());
    }
  }

  Future<void> _refreshAutoRecording() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(AutoRecordingSchedule.enabledKey) == true) {
        await AutoRecordingSchedule.sync(_apiClient, _recordingBridge);
      }
    } catch (_) {
      // 录音页的手动同步会展示具体错误；启动不因此阻塞。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _noteChecks.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_uploadQueue.reconnect(_recordingBridge));
      unawaited(_refreshAutoRecording());
    }
  }

  @override
  void dispose() {
    _recordingEvents?.cancel();
    _apiClient.onConnectionReady = null;
    _uploadQueue.dispose();
    _noteChecks.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      debugShowCheckedModeBanner: false,
      home: MainNavigationScaffold(
        apiClient: _apiClient,
        recordingBridge: _recordingBridge,
        uploadQueue: _uploadQueue,
        noteChecks: _noteChecks,
      ),
    );
  }
}

class MainNavigationScaffold extends StatefulWidget {
  final ApiClient apiClient;
  final RecordingBridge recordingBridge;
  final UploadQueue uploadQueue;
  final NoteCheckController? noteChecks;

  const MainNavigationScaffold({
    super.key,
    required this.apiClient,
    required this.recordingBridge,
    required this.uploadQueue,
    this.noteChecks,
  });

  @override
  State<MainNavigationScaffold> createState() => _MainNavigationScaffoldState();
}

class _MainNavigationScaffoldState extends State<MainNavigationScaffold> {
  int _currentIndex = 0;
  final Set<int> _openedTabs = {0};

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      ScheduleWidgetBridge.channel.setMethodCallHandler((call) async {
        if (call.method == 'openSchedule' && mounted) _selectTab(0);
        if (call.method == 'openRecording' && mounted) _selectTab(2);
      });
      unawaited(_openWidgetTab());
    }
  }

  Future<void> _openWidgetTab() async {
    try {
      final tab =
          await ScheduleWidgetBridge.channel.invokeMethod<int>('getLaunchTab');
      if (tab == 2 && mounted) _selectTab(2);
    } catch (_) {/* 普通启动保留课表首页。 */}
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      ScheduleWidgetBridge.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  void _selectTab(int index) {
    if (_currentIndex == index) return;
    setState(() {
      _currentIndex = index;
      _openedTabs.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Platform.isAndroid;

    // 录音标签：安卓=真实录音页；桌面端（Windows）=录音文件/上传队列管理（桌面端不录音）。
    final recordingTab = isAndroid
        ? RecordingPage(
            recordingBridge: widget.recordingBridge,
            uploadQueue: widget.uploadQueue,
            apiClient: widget.apiClient,
          )
        : RecordingFilesPage(
            uploadQueue: widget.uploadQueue,
            apiClient: widget.apiClient,
          );

    final pages = [
      SchedulePage(apiClient: widget.apiClient),
      NotesPage(apiClient: widget.apiClient, noteChecks: widget.noteChecks),
      recordingTab,
      SettingsPage(
        apiClient: widget.apiClient,
        recordingBridge: widget.recordingBridge,
        noteChecks: widget.noteChecks,
      ),
    ];

    final destinations = <(IconData, IconData, String)>[
      (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
      (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
      (Icons.mic_none, Icons.mic, '录音'),
      (Icons.settings_outlined, Icons.settings, '设置'),
    ];
    final content = StudyTabDeck(
      index: _currentIndex,
      children: List.generate(
          pages.length,
          (index) => _openedTabs.contains(index)
              ? pages[index]
              : const SizedBox.shrink()),
    );

    return StudyNavigationLayout(
      content: content,
      destinations: destinations,
      selectedIndex: _currentIndex,
      onSelected: _selectTab,
    );
  }
}

class SettingsPage extends StatefulWidget {
  final ApiClient apiClient;
  final RecordingBridge recordingBridge;
  final NoteCheckController? noteChecks;

  const SettingsPage({
    super.key,
    required this.apiClient,
    required this.recordingBridge,
    this.noteChecks,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isCheckingUpdate = false;
  Map<String, dynamic>? _updateInfo;
  String? _notesRoot;
  String? _recordingsRoot;
  String? _phoneNotesFolder;

  // 课表与学期设置（本地持久化）
  DateTime _semesterStart = DateTime(2026, 8, 31); // v3.3：学期首日为周一 2026-08-31

  @override
  void initState() {
    super.initState();
    _silentCheckUpdate();
    _loadLocalPrefs();
    if (Platform.isWindows) unawaited(_loadWindowsPaths());
    if (Platform.isAndroid) unawaited(_loadPhoneNotesFolder());
  }

  Future<void> _loadWindowsPaths() async {
    final result = await widget.apiClient.getLocalPaths();
    if (mounted && result.ok) {
      setState(() {
        _notesRoot = result.data?['obsidian_root'] as String?;
        _recordingsRoot = result.data?['recordings_root'] as String?;
      });
    }
  }

  Future<void> _chooseWindowsPath(String key) async {
    try {
      final selected = await ScheduleFilePicker.pickDirectory();
      if (selected == null || selected.isEmpty) return;
      final result = await widget.apiClient.saveLocalPaths({key: selected});
      if (!mounted) return;
      if (!result.ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存路径失败：${result.error}')));
        return;
      }
      setState(() {
        _notesRoot = result.data?['obsidian_root'] as String?;
        _recordingsRoot = result.data?['recordings_root'] as String?;
      });
      if (key == 'obsidian_root') LocalNotesBridge.changed.value++;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('路径已保存；已有文件不会移动')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择目录失败：$e')));
      }
    }
  }

  Future<void> _loadPhoneNotesFolder() async {
    try {
      final label = await LocalNotesBridge.folder();
      if (mounted) setState(() => _phoneNotesFolder = label);
    } catch (_) {}
  }

  Future<void> _choosePhoneNotesFolder() async {
    try {
      final label = await LocalNotesBridge.pickFolder();
      if (mounted && label != null) setState(() => _phoneNotesFolder = label);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择目录失败：$e')));
      }
    }
  }

  Future<void> _loadLocalPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cna_semester_start');
      if (!mounted) return;
      setState(() {
        if (raw != null) {
          final parsed = DateTime.tryParse(raw);
          if (parsed != null) _semesterStart = parsed;
        }
      });
    } catch (_) {}
  }

  Future<void> _pickSemesterStart() async {
    try {
      final snapshot = await ScheduleStore.load(widget.apiClient);
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ScheduleSettingsPage(
                  api: widget.apiClient, snapshot: snapshot)));
      if (mounted) await _loadLocalPrefs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法读取课表设置：$e')));
      }
    }
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _silentCheckUpdate() async {
    final res = await widget.apiClient
        .checkAppVersion(currentCode: AppConstants.appVersionCode);
    if (!mounted) return;
    if (res.ok) {
      final info = res.data;
      if (info != null) {
        setState(() {
          _updateInfo = info;
        });
      }
    }
  }

  Future<void> _triggerCheckUpdate({bool showUpToDatePrompt = true}) async {
    setState(() => _isCheckingUpdate = true);

    final res = await widget.apiClient
        .checkAppVersion(currentCode: AppConstants.appVersionCode);
    if (!mounted) return;

    if (!res.ok) {
      setState(() => _isCheckingUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法连接更新服务器：${res.error ?? '未知错误'}')),
      );
      return;
    }

    final info = res.data ?? const <String, dynamic>{};
    final hasUpdate = info['has_update'] as bool? ?? false;
    setState(() {
      _updateInfo = info;
      _isCheckingUpdate = false;
    });

    if (hasUpdate) {
      _showUpdateDialog(info);
    } else if (showUpToDatePrompt) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('当前已是最新版本 (v${AppConstants.appVersion})，无需更新！')),
      );
    }
  }

  void _showUpdateDialog(Map<String, dynamic> info) {
    final version = info['version'] as String? ?? '新版本';
    final releaseNotes = info['release_notes'] as String? ?? '优化系统稳定性与使用体验';
    final downloadUrl = info['download_url'] as String? ?? '/api/app/download';
    final fileSizeBytes = info['file_size_bytes'] as int? ?? 0;
    final sizeMbStr = fileSizeBytes > 0
        ? '${(fileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
        : '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        double downloadProgress = 0.0;
        int receivedBytes = 0;
        int totalBytes = fileSizeBytes;
        bool isDownloading = false;
        String statusText = '发现新版本，点击下方按钮即可一键下载并直接升级：';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.system_update_alt,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('发现新版本 $version'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(statusText,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      releaseNotes,
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                  if (sizeMbStr.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('安装包大小: $sizeMbStr',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                  if (isDownloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                        value: downloadProgress > 0 ? downloadProgress : null),
                    const SizedBox(height: 8),
                    Text(
                      '下载进度: ${(downloadProgress * 100).toStringAsFixed(1)}% '
                      '(${(receivedBytes / 1024 / 1024).toStringAsFixed(1)} MB / ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: [
                if (!isDownloading)
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('稍后再说'),
                  ),
                ElevatedButton.icon(
                  icon: isDownloading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(isDownloading ? '正在下载...' : '应用内一键升级'),
                  onPressed: isDownloading
                      ? null
                      : () async {
                          setDialogState(() {
                            isDownloading = true;
                            statusText = '正在下载更新包，下载完成后将自动调起安装...';
                          });

                          try {
                            final tmpDir = await getTemporaryDirectory();
                            final savePath =
                                '${tmpDir.path}/Remember_update.apk';

                            final ok = await widget.apiClient.downloadApk(
                              downloadUrl: downloadUrl,
                              savePath: savePath,
                              onProgress: (received, total) {
                                if (total > 0) {
                                  setDialogState(() {
                                    receivedBytes = received;
                                    totalBytes = total;
                                    downloadProgress = received / total;
                                  });
                                }
                              },
                            );

                            if (!ok) {
                              setDialogState(() {
                                isDownloading = false;
                                statusText = '下载失败，请检查网络或重试。';
                              });
                              return;
                            }

                            setDialogState(() {
                              statusText = '下载完成！正在调起安装程序...';
                            });

                            final installed = await widget.recordingBridge
                                .installApk(savePath);
                            if (mounted && context.mounted && ctx.mounted) {
                              Navigator.pop(ctx);
                              if (!installed) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('调起安装程序失败，请检查是否赋予安装权限')),
                                );
                              }
                            }
                          } catch (e) {
                            setDialogState(() {
                              isDownloading = false;
                              statusText = '升级过程出错: $e';
                            });
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _sectionLabel(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasNewVersion =
        _updateInfo != null && (_updateInfo!['has_update'] == true);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20 + StudyDockContentInset.of(context), 8,
            20, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设备与文件',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 5),
                Text('管理连接、文件位置与课程设置',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                Divider(
                    color: Theme.of(context).colorScheme.onSurface,
                    thickness: 1.5),
              ],
            ),
          ),
          _sectionLabel(context, '设备连接'),
          Card(
            child: ListTile(
              leading: Icon(
                  Platform.isWindows
                      ? Icons.phonelink_rounded
                      : Icons.devices_rounded,
                  color: Theme.of(context).colorScheme.primary),
              title: Text(Platform.isWindows ? '连接手机' : '连接电脑'),
              subtitle: Text(Platform.isWindows
                  ? '查看连接码，让手机访问这台电脑的课堂资料'
                  : '输入电脑显示的连接码，自动保存地址与访问权限'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          PairingPage(apiClient: widget.apiClient))),
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, '文件位置'),
          if (Platform.isWindows)
            Card(
                child: Column(children: [
              ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('笔记保存路径'),
                  subtitle:
                      Text(_notesRoot ?? '正在读取目录…\n选择 Obsidian 库根目录，内含“课堂笔记”'),
                  isThreeLine: _notesRoot == null,
                  trailing: const Icon(Icons.folder_open),
                  onTap: () => _chooseWindowsPath('obsidian_root')),
              const Divider(height: 1),
              ListTile(
                  leading: const Icon(Icons.mic_none),
                  title: const Text('录音保存路径'),
                  subtitle: Text(_recordingsRoot ?? '正在读取目录…'),
                  trailing: const Icon(Icons.folder_open),
                  onTap: () => _chooseWindowsPath('recordings_root')),
            ])),
          if (Platform.isAndroid)
            Card(
                child: ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('手机笔记保存与读取路径'),
                    subtitle: Text(_phoneNotesFolder == null
                        ? '选择手机笔记目录，供本 APP 同步和离线阅读'
                        : '$_phoneNotesFolder · 由本 APP 增量同步，仅传变化的笔记'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _choosePhoneNotesFolder)),
          const SizedBox(height: 20),
          _sectionLabel(context, '同步与服务'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.dns,
                      color: Theme.of(context).colorScheme.primary),
                  title: const Text('后端服务器地址'),
                  subtitle: Text(widget.apiClient.baseUrl),
                  trailing: const Icon(Icons.edit),
                  onTap: () async {
                    final controller =
                        TextEditingController(text: widget.apiClient.baseUrl);
                    final newUrl = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('修改后端服务地址'),
                        content: TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                              hintText: '如 http://192.168.1.100:8000'),
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('取消')),
                          ElevatedButton(
                            onPressed: () =>
                                Navigator.pop(ctx, controller.text.trim()),
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    );
                    if (newUrl != null && newUrl.isNotEmpty) {
                      setState(() {
                        widget.apiClient.updateBaseUrl(newUrl);
                      });
                      widget.noteChecks?.scopeChanged();
                      // 持久化：重启后仍生效（否则「改了等于没改」——同 auto_record 静默失效类问题）。
                      try {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString(AppConstants.prefBaseUrl, newUrl);
                      } catch (_) {}
                      _silentCheckUpdate();
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('笔记同步'),
                  subtitle: const Text('电脑下发到手机；查看同步结果与内容差异'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.noteChecks == null
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => Scaffold(
                                  appBar: AppBar(title: const Text('笔记同步')),
                                  body: ListView(
                                      padding: const EdgeInsets.all(20),
                                      children: [
                                        NoteCheckPanel(
                                            controller: widget.noteChecks!,
                                            chooseFolder: Platform.isAndroid
                                                ? _choosePhoneNotesFolder
                                                : null),
                                      ])))),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (Platform.isWindows) ...[
            _sectionLabel(context, '启动与通知'),
            const WindowsStartupTile(),
            WindowsStartupTile(
              title: 'ASR 转写通知',
              description: '转写开始、完成或失败时发送 Windows 通知；可随时关闭',
              icon: Icons.notifications_outlined,
              read: () async {
                final result = await widget.apiClient.getDesktopSettings();
                if (!result.ok || result.data?['asr_notifications'] is! bool) {
                  throw StateError('无法读取通知设置');
                }
                return result.data!['asr_notifications'] as bool;
              },
              write: (enabled) async {
                final result =
                    await widget.apiClient.saveDesktopSettings(enabled);
                if (!result.ok ||
                    result.data?['asr_notifications'] != enabled) {
                  throw StateError('通知设置未保存');
                }
                return enabled;
              },
            ),
            const SizedBox(height: 20),
          ],
          _sectionLabel(context, '课程设置'),
          // 课表与学期设置（FR-01 / FR-33 相关）
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.event_available),
                  title: const Text('设定课表'),
                  subtitle: Text('${_formatDate(_semesterStart)}（用于推算当前第几周）'),
                  trailing: const Icon(Icons.edit),
                  onTap: _pickSemesterStart,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, '应用版本'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const RememberBrandMark(size: 32),
                      if (hasNewVersion)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Row(
                    children: [
                      const Flexible(child: Text('检查新版本与应用内更新')),
                      if (hasNewVersion) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'NEW',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    hasNewVersion
                        ? 'Remember · 已安装 v${AppConstants.appVersion}（构建 ${AppConstants.appVersionCode}）\n可更新到 v${_updateInfo!['version']}（构建 ${_updateInfo!['version_code']}）'
                        : 'Remember · 已安装 v${AppConstants.appVersion}（构建 ${AppConstants.appVersionCode}）',
                  ),
                  trailing: _isCheckingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _isCheckingUpdate
                      ? null
                      : () => _triggerCheckUpdate(showUpToDatePrompt: true),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('手动刷新检测更新'),
                          onPressed: _isCheckingUpdate
                              ? null
                              : () =>
                                  _triggerCheckUpdate(showUpToDatePrompt: true),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
