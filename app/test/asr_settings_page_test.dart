// Independent review driver outside candidate. No real HTTP/config/audio IO.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/api_result.dart';
import 'package:class_notes_assistant/features/asr/asr_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'note_rendering_test.dart' show loadFonts;

class ReviewApi extends ApiClient {
  ReviewApi({this.mode = 'local_qwen'}) : super(baseUrl: 'http://qa-asr.invalid');
  String mode;
  bool failSettings = false, failJobs = false, failRetry = false, queued = false;
  int settingsReads = 0, saves = 0, tests = 0, retries = 0;
  int jobCount = 1;
  Completer<ApiResult<Map<String, dynamic>>>? saving;
  Map<String, dynamic> config() => {'enabled': true, 'mode': mode, 'delete_source': false,
    'output_dir': 'D:/QA/转写文件夹', 'python_path': 'C:/QA/Qwen/Scripts/python.exe',
    'model_path': 'D:/QA/Qwen3-ASR-1.7B', 'aligner_path': 'D:/QA/Qwen3-ForcedAligner-0.6B',
    'ffmpeg_path': 'C:/QA/ffmpeg.exe', 'base_url': 'https://qa-asr.invalid/v1',
    'model': 'Qwen3-ASR-1.7B', 'api_key_set': true};
  @override Future<ApiResult<Map<String, dynamic>>> getAsrSettings() async {
    settingsReads++;
    return failSettings ? const ApiResult.failed('读取配置失败（模拟）') : ApiResult.ok(config());
  }
  @override Future<ApiResult<List<Map<String, dynamic>>>> getAsrJobs() async => failJobs
      ? const ApiResult.failed('任务读取失败（模拟）')
      : ApiResult.ok([for (var index = 1; index <= jobCount; index++) {'id': 'qa-task-$index', 'source_name': jobCount == 1 ? '工程力学_2026-10-18_08-15-00.m4a' : '第$index节工程力学.m4a', 'status': queued ? 'queued' : 'failed', 'error': queued ? '' : '环境不可用，录音已保留。', 'result': {}}]);
  @override Future<ApiResult<Map<String, dynamic>>> saveAsrSettings(Map<String, dynamic> value) async {
    saves++;
    return saving == null ? ApiResult.ok(config()) : await saving!.future;
  }
  @override Future<ApiResult<Map<String, dynamic>>> testAsrSettings(Map<String, dynamic> value) async {
    tests++;
    return const ApiResult.ok({'message': '环境可用；未执行完整音频转写。'});
  }
  @override Future<ApiResult<Map<String, dynamic>>> retryAsrJob(String id) async {
    retries++;
    if (failRetry) return const ApiResult.failed('重试失败（模拟），音频保留');
    queued = true;
    return const ApiResult.ok({'id': 'qa-task', 'status': 'queued'});
  }
}

Future<GlobalKey> mount(WidgetTester tester, ReviewApi api,
    {bool editable = true, Size size = const Size(390, 844), double scale = 2, bool dark = false}) async {
  await tester.runAsync(loadFonts);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: AsrSettingsPage(apiClient: api, editable: editable),
  )));
  await tester.pumpAndSettle();
  return key;
}

Future<void> screenshot(WidgetTester tester, GlobalKey key, String label) async {
  await tester.runAsync(() async {
    final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('build/asr-ui-review')..createSync(recursive: true);
    File('${folder.path}/$label.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final mode in ['local_qwen', 'qwen_service']) {
    testWidgets('独立ASR 390宽200% $mode 无布局错误且按钮可达', (tester) async {
      final api = ReviewApi(mode: mode);
      final key = await mount(tester, api, dark: mode == 'qwen_service');
      expect(tester.takeException(), isNull);
      await screenshot(tester, key, '$mode-top');
      final selected = find.text(mode == 'local_qwen' ? '本机 Qwen 环境' : 'Qwen 转写服务');
      final paragraph = tester.renderObject<RenderParagraph>(selected);
      final text = paragraph.text.toPlainText();
      final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length));
      final control = tester.getRect(find.byType(DropdownButtonFormField<String>));
      final origin = paragraph.localToGlobal(Offset.zero);
      for (final box in boxes) {
        expect(origin.dy + box.bottom, lessThanOrEqualTo(control.bottom + .01), reason: '已选接入方式字形必须完整位于实际控件轮廓内');
      }
      await tester.ensureVisible(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(find.text('保存设置').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot(tester, key, '$mode-actions');
    });
  }
  testWidgets('独立ASR手机只看任务且可重试，不读写电脑配置', (tester) async {
    final api = ReviewApi();
    final key = await mount(tester, api, editable: false, dark: true);
    expect(api.settingsReads, 0);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('保存设置'), findsNothing);
    expect(find.textContaining('工程力学_'), findsOneWidget);
    await tester.ensureVisible(find.text('手动重试'));
    await tester.tap(find.text('手动重试'));
    // A queued job now has an ongoing progress indicator; wait for the response,
    // not for every animation in the page to stop.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(api.retries, 1);
    expect(api.saves, 0);
    expect(find.text('等待转写'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, key, 'phone-readonly');
  });
  testWidgets('独立ASR设置读取失败禁保存，任务仍可读，重试成功去旧错', (tester) async {
    final api = ReviewApi()..failSettings = true;
    await mount(tester, api);
    expect(find.textContaining('读取配置失败'), findsWidgets);
    final buttons = tester.widgetList<FilledButton>(find.byType(FilledButton));
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(find.textContaining('工程力学_'), findsOneWidget);
    api.failSettings = false;
    await tester.ensureVisible(find.text('重新加载设置'));
    await tester.tap(find.text('重新加载设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取配置失败'), findsNothing);
    expect(find.byType(TextField), findsWidgets);
    expect(api.saves, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('独立ASR保存时真实禁用控件，失败就近可见并保留草稿', (tester) async {
    final api = ReviewApi()..saving = Completer<ApiResult<Map<String, dynamic>>>();
    final key = await mount(tester, api);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pump();
    final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'));
    expect(save.onPressed, isNull, reason: 'AbsorbPointer不能代替禁用语义/键盘');
    expect(tester.widgetList<TextField>(find.byType(TextField)).every((field) => field.enabled == false || field.readOnly), isTrue);
    expect(api.saves, 1);
    api.saving!.complete(const ApiResult.failed('保存失败（模拟），原设置未改'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败（模拟）').hitTestable(), findsWidgets);
    expect(tester.widgetList<TextField>(find.byType(TextField)).any((f) => f.controller?.text == 'D:/QA/转写文件夹'), isTrue);
    expect(tester.takeException(), isNull);
    await screenshot(tester, key, 'save-failed-visible');
  });
  testWidgets('独立ASR手机重试失败只显示一份错误，旧任务不伪装成功', (tester) async {
    final api = ReviewApi()..failRetry = true;
    await mount(tester, api, editable: false);
    await tester.ensureVisible(find.text('手动重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试失败（模拟），音频保留'), findsOneWidget);
    expect(find.text('转写失败，音频保留'), findsOneWidget);
    expect(find.text('等待转写'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('独立ASR横屏200%与编辑清除旧保存反馈', (tester) async {
    final api = ReviewApi(mode: 'qwen_service');
    final key = await mount(tester, api, size: const Size(844, 390));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存：'), findsOneWidget);
    final field = find.byType(TextField).first;
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'D:/QA/新的转写目录');
    await tester.pump();
    expect(find.textContaining('已保存：'), findsNothing);
    expect(tester.takeException(), isNull);
    await screenshot(tester, key, 'landscape-200-edit');
  });
  testWidgets('独立ASR任务列表末端重试失败在当前操作位置可见', (tester) async {
    final api = ReviewApi()..failRetry = true..jobCount = 15;
    final key = await mount(tester, api, editable: false);
    final source = find.text('第15节工程力学.m4a');
    await tester.scrollUntilVisible(source, 600, scrollable: find.byType(Scrollable).first);
    final card = find.ancestor(of: source, matching: find.byType(Card));
    final retry = find.descendant(of: card, matching: find.text('手动重试'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await screenshot(tester, key, 'last-job-error');
    expect(find.text('重试失败（模拟），音频保留').hitTestable(), findsWidgets,
        reason: '不能把本次重试失败只显示到长任务列表最上方');
    expect(tester.takeException(), isNull);
  });
}
