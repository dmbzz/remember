import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/api_client.dart';
import '../../data/api_result.dart';
import '../../platform/local_notes_bridge.dart';
import 'note_markdown.dart';
import 'note_syntax.dart';
import '../../core/note_opening_route.dart';
import '../../core/course_palette.dart';

class NoteDetailPage extends StatefulWidget {
  final String noteId;
  final String title;
  final String course;
  final ApiClient apiClient;
  const NoteDetailPage(
      {super.key,
      required this.noteId,
      required this.title,
      required this.course,
      required this.apiClient});
  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  String? _content;
  List<String> _sections = const [];
  bool _isLoading = true;
  bool _fontReady = false;
  String? _error;
  double _fontSize = 16;
  final _scrollController = ScrollController();
  @override
  void initState() {
    super.initState();
    _fetchContent();
    _restoreReadingSize();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _restoreReadingSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = (prefs.getDouble('cna_reading_font_size') ?? 16)
          .clamp(15, 26)
          .toDouble();
    } catch (error) {
      debugPrint('Reading preferences unavailable; using default size: $error');
    } finally {
      if (mounted) setState(() => _fontReady = true);
    }
  }

  Future<void> _fetchContent() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    ApiResult<String> res;
    if (widget.noteId.startsWith('local:')) {
      try {
        res = ApiResult.ok(await LocalNotesBridge.read(widget.noteId));
      } catch (e) {
        res = ApiResult.failed('手机本地笔记读取失败：$e');
      }
    } else {
      res = await widget.apiClient.getNoteContent(widget.noteId);
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (res.ok) {
        _content = res.data?.isNotEmpty == true ? res.data : '（暂无正文内容）';
        _sections = splitNoteMarkdown(_content!);
      } else {
        _content = null;
        _sections = const [];
        _error = res.error ?? '未知错误';
      }
    });
  }

  void _readingOptions() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => StatefulBuilder(
            builder: (sheetContext, updateSheet) => SafeArea(
                    child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('阅读字号',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 16),
                        Row(children: [
                          const Text('A', style: TextStyle(fontSize: 15)),
                          Expanded(
                              child: Slider(
                            value: _fontSize,
                            min: 15,
                            max: 26,
                            divisions: 11,
                            label: _fontSize.round().toString(),
                            onChanged: (value) {
                              setState(() => _fontSize = value);
                              updateSheet(() {});
                            },
                            onChangeEnd: (value) async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setDouble(
                                  'cna_reading_font_size', value);
                            },
                          )),
                          const Text('A', style: TextStyle(fontSize: 26)),
                        ]),
                        const SizedBox(height: 12),
                        Text('长公式可左右滑动；思维导图可拖动、缩放或展开。',
                            style: Theme.of(context).textTheme.bodySmall),
                      ]),
                ))),
      );
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop()
        },
        child: Scaffold(
          backgroundColor: colors.surface,
          appBar: PreferredSize(
              preferredSize: const Size.fromHeight(kToolbarHeight),
              child: NoteOpeningChrome(
                  child: AppBar(
                      backgroundColor: colors.surface,
                      title: const Text('阅读'),
                      actions: [
                    IconButton(
                        tooltip: '阅读字号',
                        onPressed: _readingOptions,
                        icon: const Icon(Icons.text_fields_rounded)),
                    IconButton(
                        tooltip: '刷新笔记',
                        onPressed: _fetchContent,
                        icon: const Icon(Icons.refresh_rounded)),
                  ]))),
          body: LayoutBuilder(builder: (context, box) {
            final compact = box.maxHeight < 230;
            final headingStyle = Theme.of(context)
                .textTheme
                .headlineMedium!
                .copyWith(
                    fontSize: 20, height: 1.45, fontWeight: FontWeight.w600);
            final titleLines = noteOpeningTitleLines(
                box.maxHeight, headingStyle, MediaQuery.textScalerOf(context));
            return Column(children: [
              NoteOpeningChrome(
                  child: Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Container(
                              width: double.infinity,
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              padding: EdgeInsets.fromLTRB(
                                  20, compact ? 8 : 16, 20, 8),
                              color: colors.surface,
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!compact)
                                      Text(widget.course,
                                          style: TextStyle(
                                              color: CoursePalette.of(
                                                      context, widget.course)
                                                  .ink,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600)),
                                    if (!compact) const SizedBox(height: 10),
                                    NoteOpeningTitleAnchor(
                                        noteId: widget.noteId,
                                        title: widget.title,
                                        maxLines: titleLines,
                                        style: headingStyle),
                                    Divider(height: compact ? 12 : 20),
                                  ]))))),
              Expanded(
                  child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      layoutBuilder: (current, previous) =>
                          SizedBox.expand(child: current),
                      child: _isLoading || !_fontReady
                          ? const Center(
                              key: ValueKey('note-loading'),
                              child: CircularProgressIndicator())
                          : _error != null
                              ? Center(
                                  child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.cloud_off_outlined,
                                                color: colors.onSurfaceVariant,
                                                size: 36),
                                            const SizedBox(height: 16),
                                            Text('笔记加载失败',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleLarge),
                                            const SizedBox(height: 8),
                                            Text(_error!,
                                                textAlign: TextAlign.center),
                                            const SizedBox(height: 20),
                                            FilledButton(
                                                onPressed: _fetchContent,
                                                child: const Text('重新加载')),
                                          ])))
                              : Scrollbar(
                                  key: const ValueKey('note-body-ready'),
                                  controller: _scrollController,
                                  child: SelectionArea(
                                      child: ListView.builder(
                                    controller: _scrollController,
                                    itemCount: _sections.length + 1,
                                    itemBuilder: (context, index) {
                                      final inset =
                                          MediaQuery.sizeOf(context).width > 700
                                              ? 40.0
                                              : 20.0;
                                      return Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                              maxWidth: 680),
                                          child: Container(
                                            width: double.infinity,
                                            margin: EdgeInsets.fromLTRB(
                                                12,
                                                index == 0 ? 8 : 0,
                                                12,
                                                index == _sections.length
                                                    ? 40
                                                    : 0),
                                            padding: EdgeInsets.fromLTRB(
                                                inset,
                                                index == 0 ? inset : 0,
                                                inset,
                                                index == _sections.length
                                                    ? inset
                                                    : 0),
                                            color: colors.surface,
                                            child: index == 0
                                                ? Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                        Wrap(
                                                            spacing: 16,
                                                            runSpacing: 8,
                                                            children: [
                                                              _origin(
                                                                  '课堂',
                                                                  colors
                                                                      .primary),
                                                              _origin(
                                                                  '课件',
                                                                  const Color(
                                                                      0xFF8061B8)),
                                                              _origin(
                                                                  '教材',
                                                                  const Color(
                                                                      0xFF14806A)),
                                                            ]),
                                                        const Divider(
                                                            height: 40),
                                                      ])
                                                : NoteMarkdown(
                                                    data: _sections[index - 1],
                                                    fontSize: _fontSize,
                                                  ),
                                          ),
                                        ),
                                      );
                                    },
                                  ))))),
            ]);
          }),
        ));
  }

  Widget _origin(String label, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 6, color: color),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}
