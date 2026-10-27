import 'package:flutter/material.dart';
import 'dart:io';

import '../../core/note_opening_route.dart';
import '../../core/shapes.dart';
import '../../core/motion.dart';
import '../../core/pressable_card.dart';
import '../../core/course_palette.dart';
import '../../data/api_client.dart';
import '../../data/note_check_controller.dart';
import 'note_check_panel.dart';
import 'note_detail_page.dart';
import '../pairing/pairing_page.dart';
import '../../platform/local_notes_bridge.dart';
import '../../platform/local_backend_bootstrap.dart';

/// 笔记工作台：课程从实际数据生成，支持即时搜索与明确的失败状态。
class NotesPage extends StatefulWidget {
  final ApiClient apiClient;
  final Future<void> Function()? prepareLocalBackend;
  final NoteCheckController? noteChecks;
  const NotesPage(
      {super.key,
      required this.apiClient,
      this.prepareLocalBackend,
      this.noteChecks});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  List<Map<String, dynamic>> _notes = [];
  bool _isLoading = true;
  String? _error;
  String _selectedCourse = '全部';
  String _query = '';
  int _loadVersion = 0;
  final _cardKeys = <String, GlobalKey>{};
  final _titleKeys = <String, GlobalKey>{};
  final _hiddenTitles = <String, ValueNotifier<bool>>{};
  final _activeTitleNotifiers = <ValueNotifier<bool>>{};

  @override
  void initState() {
    super.initState();
    LocalNotesBridge.changed.addListener(_folderChanged);
    widget.noteChecks?.localRevision.addListener(_checkedLocalNotes);
    _loadNotes();
  }

  @override
  void dispose() {
    LocalNotesBridge.changed.removeListener(_folderChanged);
    widget.noteChecks?.localRevision.removeListener(_checkedLocalNotes);
    for (final hidden in _hiddenTitles.values) {
      if (!_activeTitleNotifiers.contains(hidden)) {
        hidden.dispose();
      }
    }
    super.dispose();
  }

  Rect? _measuredRect(GlobalKey key) {
    final render = key.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  void _folderChanged() => _loadNotes();

  void _checkedLocalNotes() {
    final notes = widget.noteChecks?.localNotes;
    if (mounted && widget.noteChecks?.android == false && notes == null) {
      _loadNotes();
      return;
    }
    if (mounted && notes != null) {
      ++_loadVersion;
      setState(() {
        _notes = notes;
        _isLoading = false;
        _error = null;
      });
    }
  }

  Future<void> _pickLocalFolder() async {
    try {
      await LocalNotesBridge.pickFolder();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择笔记文件夹失败：$e')));
      }
    }
  }

  Future<void> _compareNotes() async {
    final checks = widget.noteChecks;
    if (checks != null) {
      await checks.check();
      if (!mounted) return;
      if (checks.needsFolder) {
        await _pickLocalFolder();
        return;
      }
      if (checks.reports.isNotEmpty) {
        NoteCheckPanel.showDetails(context, checks);
      } else if (checks.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('本轮未核对成功：${checks.error}')));
      }
      return;
    }
    try {
      if (await LocalNotesBridge.folder() == null) {
        await _pickLocalFolder();
        return;
      }
      final local = await LocalNotesBridge.list();
      final remote = await widget.apiClient.getNotesManifest();
      if (!mounted) return;
      if (!remote.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('电脑暂时无法连接，本地笔记照常可读。${remote.error ?? ''}')));
        return;
      }
      final items = (remote.data?['items'] as List?)
              ?.map((item) => (item as Map).cast<String, dynamic>())
              .toList() ??
          [];
      final diff = NoteManifestDiff.compare(local, items);
      showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ListView(shrinkWrap: true, children: [
                    Text('笔记差异检查',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(
                        '一致 ${diff.same} 篇 · 只在手机 ${diff.onlyOnPhone.length} 篇 · 只在电脑 ${diff.onlyOnComputer.length} 篇 · 内容不同 ${diff.different.length} 篇'),
                    const SizedBox(height: 8),
                    const Text('此处为差异检查。文件传输请使用本 APP 的“笔记同步”入口。'),
                    for (final path in diff.onlyOnPhone)
                      ListTile(title: Text(path), subtitle: const Text('只在手机')),
                    for (final path in diff.onlyOnComputer)
                      ListTile(title: Text(path), subtitle: const Text('只在电脑')),
                    for (final path in diff.different)
                      ListTile(title: Text(path), subtitle: const Text('内容不同')),
                  ]))));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('笔记检查失败：$e')));
      }
    }
  }

  Future<void> _loadNotes([int attempt = 0, int? version]) async {
    if (attempt == 0) {
      version = ++_loadVersion;
      setState(() {
        _isLoading = true;
        _error = null;
      });
      // A failed cold start must not require closing and reopening the app.
      // Concurrent startup/refresh calls share one launcher attempt.
      final server = Uri.tryParse(widget.apiClient.baseUrl);
      if (Platform.isWindows &&
          server?.scheme == 'http' &&
          server?.port == 8000 &&
          const ['127.0.0.1', 'localhost', '::1'].contains(server?.host)) {
        await (widget.prepareLocalBackend ??
            LocalBackendBootstrap.ensureRunning)();
        if (!mounted || version != _loadVersion) return;
      }
    }
    final String? folder;
    try {
      folder = Platform.isAndroid ? await LocalNotesBridge.folder() : null;
    } catch (e) {
      if (mounted && version == _loadVersion) {
        setState(() {
          _isLoading = false;
          _error = '读取手机笔记目录失败：$e';
        });
      }
      return;
    }
    if (folder != null) {
      try {
        final notes = await LocalNotesBridge.list();
        if (mounted && version == _loadVersion) {
          setState(() {
            _notes = notes;
            _isLoading = false;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted && version == _loadVersion) {
          setState(() {
            _isLoading = false;
            _error = '读取 $folder 失败：$e';
          });
        }
      }
      return;
    }
    final res = await widget.apiClient.getNotes();
    if (!mounted || version != _loadVersion) return;
    // 启动器会与后端并行打开界面，给后端留出就绪时间。
    final connectionError = (res.error ?? '').startsWith('无法连接后端') ||
        (res.error ?? '').startsWith('连接后端超时');
    if (!res.ok && connectionError && attempt < 15) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted && version == _loadVersion) {
        return _loadNotes(attempt + 1, version);
      }
      return;
    }
    setState(() {
      _isLoading = false;
      if (res.ok) {
        _notes = res.data ?? const [];
        _error = null;
      } else {
        _error = res.error ?? '未知错误';
      }
    });
  }

  Future<void> _openPairing() async {
    final connected = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => PairingPage(apiClient: widget.apiClient)));
    if (mounted && connected == true) _loadNotes();
  }

  List<String> get _courses {
    final values = _notes
        .map((n) => (n['course_name'] ?? '').toString())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return ['全部', ...values];
  }

  List<Map<String, dynamic>> get _visibleNotes {
    final query = _query.trim().toLowerCase();
    return _notes.where((note) {
      final course = (note['course_name'] ?? '').toString();
      final topic = (note['topic'] ?? '').toString();
      return (_selectedCourse == '全部' || course == _selectedCourse) &&
          (query.isEmpty || '$course $topic'.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
                onPressed: _compareNotes,
                tooltip: '检查手机与电脑笔记是否一致',
                icon: const Icon(Icons.fact_check_outlined)),
          PopupMenuButton<String>(
            tooltip: '笔记操作',
            onSelected: (value) {
              if (value == 'folder') _pickLocalFolder();
              if (value == 'connect') _openPairing();
              if (value == 'refresh') _loadNotes();
            },
            itemBuilder: (context) => [
              if (Platform.isAndroid)
                const PopupMenuItem(value: 'folder', child: Text('选择手机笔记文件夹')),
              PopupMenuItem(
                  value: 'connect',
                  child: Text(Platform.isWindows ? '连接手机' : '连接电脑')),
              const PopupMenuItem(value: 'refresh', child: Text('刷新笔记')),
            ],
          ),
        ],
      ),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: RefreshIndicator(
          onRefresh: _loadNotes,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('课堂笔记',
                          style: Theme.of(context).textTheme.headlineLarge),
                      const SizedBox(height: 8),
                      Text(
                          _isLoading
                              ? '正在读取资料…'
                              : '${_notes.length} 篇笔记 · ${_courses.length - 1} 门课程',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ]),
              ),
              Divider(color: colors.onSurface, thickness: 1.5),
              if (widget.noteChecks != null) ...[
                const SizedBox(height: 12),
                NoteCheckPanel(
                    controller: widget.noteChecks!,
                    chooseFolder: Platform.isAndroid ? _pickLocalFolder : null),
              ],
              const SizedBox(height: 20),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: '搜索课程或笔记主题',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 18),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final course in _courses)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(course),
                        selected: _selectedCourse == course,
                        onSelected: (_) =>
                            setState(() => _selectedCourse = course),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 18),
              if (_isLoading)
                const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                _stateCard(
                  context,
                  Icons.cloud_off_rounded,
                  '笔记暂时无法加载',
                  _error!,
                  action: FilledButton.icon(
                      onPressed: _loadNotes,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试')),
                )
              else if (_notes.isEmpty)
                _stateCard(
                    context,
                    Icons.note_add_outlined,
                    '还没有课堂笔记',
                    Platform.isAndroid
                        ? '点击右上角文件夹，选择手机 Obsidian 的课堂笔记目录。'
                        : '录音转写并生成笔记后，会显示在这里。',
                    action: Platform.isAndroid
                        ? FilledButton.icon(
                            onPressed: _pickLocalFolder,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('选择笔记文件夹'))
                        : null)
              else if (_visibleNotes.isEmpty)
                _stateCard(
                    context, Icons.search_off_rounded, '没有匹配的笔记', '换个关键词或课程试试。')
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedSwitcher(
                      duration: StudyMotion.quick(context),
                      child: Text('最近笔记 · ${_visibleNotes.length}',
                          key: ValueKey(_visibleNotes.length),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: colors.onSurface)),
                    ),
                  ),
                ),
                for (var i = 0; i < _visibleNotes.length; i++)
                  _noteCard(context, _visibleNotes[i], i + 1),
              ],
            ],
          ),
        ),
      )),
    );
  }

  Widget _stateCard(
      BuildContext context, IconData icon, String title, String body,
      {Widget? action}) {
    return Card(
        child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
      child: Column(children: [
        Icon(icon,
            size: 42, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 14),
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (action != null) ...[const SizedBox(height: 18), action],
      ]),
    ));
  }

  Widget _noteCard(BuildContext context, Map<String, dynamic> note, int index) {
    final title = (note['topic'] ?? '未命名主题').toString();
    final course = (note['course_name'] ?? '未分类课程').toString();
    final date = (note['class_date'] ?? '').toString();
    final lesson = note['lesson'];
    final noteId = (note['note_id'] ?? '').toString();
    final colors = Theme.of(context).colorScheme;
    final tone = CoursePalette.of(context, course);
    final cardKey = _cardKeys.putIfAbsent(noteId, GlobalKey.new);
    final titleKey = _titleKeys.putIfAbsent(noteId, GlobalKey.new);
    final hidden =
        _hiddenTitles.putIfAbsent(noteId, () => ValueNotifier(false));
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium!
        .copyWith(fontSize: 20, height: 1.45, fontWeight: FontWeight.w600);
    final media = MediaQuery.of(context);
    final titleLines = noteOpeningTitleLines(
        media.size.height -
            StudyShapes.readerInset * 2 -
            kToolbarHeight -
            media.padding.top -
            media.viewInsets.bottom,
        titleStyle,
        media.textScaler);
    return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: PressableCard(
          key: cardKey,
          onTap: noteId.isEmpty
              ? null
              : () {
                  if (_activeTitleNotifiers.contains(hidden)) return;
                  final route = NoteOpeningRoute<void>(
                      sourceContext: context,
                      noteId: noteId,
                      title: title,
                      sourceCardRect: () => _measuredRect(cardKey),
                      sourceTitleRect: () => _measuredRect(titleKey),
                      sourceTitleStyle: titleStyle,
                      maxLines: titleLines,
                      sourceTitleHidden: hidden,
                      builder: (_) => NoteDetailPage(
                          noteId: noteId,
                          title: title,
                          course: course,
                          apiClient: widget.apiClient));
                  _activeTitleNotifiers.add(hidden);
                  Navigator.push(context, route);
                  route.completed.then((_) {
                    _activeTitleNotifiers.remove(hidden);
                    if (!mounted) hidden.dispose();
                  });
                },
          child: Container(
            decoration: BoxDecoration(
                border: Border(left: BorderSide(color: tone.line, width: 4))),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Row(children: [
              SizedBox(
                  width: 32,
                  child: Text(index.toString().padLeft(2, '0'),
                      style: TextStyle(color: tone.ink, fontSize: 14))),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    ValueListenableBuilder<bool>(
                        valueListenable: hidden,
                        builder: (context, hide, _) => Visibility(
                            visible: !hide,
                            maintainState: true,
                            maintainAnimation: true,
                            maintainSize: true,
                            child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 596),
                                child: Text(title,
                                    key: titleKey,
                                    maxLines: titleLines,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle)))),
                    const SizedBox(height: 6),
                    Text(
                        '$course${lesson == null ? '' : ' · 第$lesson课'}${date.isEmpty ? '' : ' · $date'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: colors.onSurfaceVariant)),
                  ])),
              const SizedBox(width: 8),
              Icon(Icons.north_east, size: 16, color: colors.onSurfaceVariant),
            ]),
          ),
        ));
  }
}
