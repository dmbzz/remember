import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/api_result.dart';
import 'package:class_notes_assistant/data/note_check_controller.dart';
import 'package:class_notes_assistant/features/notes/note_check_panel.dart';
import 'package:class_notes_assistant/core/theme.dart';

Map<String, dynamic> report() => {
      'same': 2,
      'vault_id': 'vault-1',
      'folder_label': '课堂笔记',
      'phone_checked_at': '2026-10-14T10:00:00Z',
      'computer_checked_at': '2026-10-14T10:00:02Z',
      'only_on_phone': ['物理/手机.md'],
      'only_on_computer': ['工程力学/电脑.md'],
      'different': ['线性代数/矩阵.md'],
    };
List<Map<String, dynamic>> local() => [
      {
        'note_id': 'local:1',
        'relative_path': '物理/力.md',
        'sha256': List.filled(64, 'a').join()
      }
    ];

class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'http://computer.test');
  int calls = 0;
  bool offline = false;
  Completer<ApiResult<Map<String, dynamic>>>? pending;
  @override
  Future<ApiResult<Map<String, dynamic>>> recordNoteCheck(
      Map<String, dynamic> snapshot) async {
    calls++;
    expect(snapshot['items'], isNotEmpty);
    expect((snapshot['items'] as List).first.keys,
        unorderedEquals(['path', 'sha256']));
    if (pending != null) return await pending!.future;
    return offline ? const ApiResult.failed('连接电脑超时') : ApiResult.ok(report());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('class_notes/local_notes'),
            (call) async => call.method == 'identityHash'
                ? 'test-digest-${(call.arguments as Map)['value']}'
                : null);
  });
  test('同一自然日自动只一次，手动可强制，重启与跨天规则正确', () async {
    final api = FakeApi();
    var now = DateTime(2026, 10, 14, 12);
    var reads = 0;
    NoteCheckController build() => NoteCheckController(
        api: api,
        android: true,
        now: () => now,
        folderInfo: () async => {'identity': 'tree:daily', 'label': '课堂笔记'},
        readLocal: () async {
          reads++;
          return local();
        });
    final checks = build();
    await checks.checkIfDue();
    await checks.checkIfDue();
    expect(api.calls, 1);
    expect(reads, 1);
    await checks.check();
    expect(api.calls, 2);
    final restarted = build();
    await restarted.checkIfDue();
    expect(api.calls, 2);
    expect(restarted.reports, isNotEmpty);
    now = DateTime(2026, 10, 15, 8);
    api.offline = true;
    await restarted.checkIfDue();
    expect(api.calls, 3);
    expect(restarted.error, isNotNull);
    api.offline = false;
    await restarted.checkIfDue();
    expect(api.calls, 4);
    expect(restarted.error, isNull);
    await restarted.checkIfDue();
    expect(api.calls, 4);
    checks.dispose();
    restarted.dispose();
  });
  test('失败保留上次核对，并继续提供本地列表；重连可恢复', () async {
    final api = FakeApi();
    var reads = 0;
    final checks = NoteCheckController(
        api: api,
        android: true,
        folderInfo: () async => {'identity': 'tree:1', 'label': '课堂笔记'},
        readLocal: () async {
          reads++;
          return local();
        });
    await checks.check();
    expect(checks.reports.single['same'], 2);
    api.offline = true;
    await checks.check();
    expect(checks.error, contains('超时'));
    expect(checks.reports.single['same'], 2);
    expect(checks.localNotes, isNotEmpty);
    final restarted = NoteCheckController(
        api: api,
        android: true,
        folderInfo: () async => {'identity': 'tree:1', 'label': '课堂笔记'},
        readLocal: () async => local());
    await restarted.check();
    expect(restarted.reports.single['same'], 2);
    expect(restarted.error, isNotNull);
    api.offline = false;
    await checks.check();
    expect(checks.error, isNull);
    expect(reads, 3);
    checks.dispose();
    restarted.dispose();
  });
  test('目录变化与在途旧响应不能显示旧的一致结果', () async {
    final api = FakeApi();
    var identity = 'tree:1';
    final checks = NoteCheckController(
        api: api,
        android: true,
        folderInfo: () async => {'identity': identity, 'label': '课堂笔记'},
        readLocal: () async => local());
    await checks.check();
    api.pending = Completer();
    final old = checks.check();
    await Future<void>.delayed(Duration.zero);
    identity = 'tree:2';
    checks.scopeChanged();
    api.pending!.complete(ApiResult.ok(report()));
    await old;
    expect(checks.reports, isEmpty);
    api.pending = null;
    api.offline = true;
    await checks.check();
    expect(checks.reports, isEmpty);
    expect(checks.error, isNotNull);
    checks.dispose();
  });
  test('并发检查合并，缺目录和坏摘要不能报一致', () async {
    final api = FakeApi()..pending = Completer();
    var reads = 0;
    final checks = NoteCheckController(
        api: api,
        android: true,
        folderInfo: () async => {'identity': 'tree:1', 'label': '课堂笔记'},
        readLocal: () async {
          reads++;
          return local();
        });
    final a = checks.check(), b = checks.check();
    await Future<void>.delayed(Duration.zero);
    api.pending!.complete(ApiResult.ok(report()));
    await Future.wait([a, b]);
    expect(api.calls, 1);
    expect(reads, 1);
    checks.dispose();
    final missing = NoteCheckController(
        api: api,
        android: true,
        folderInfo: () async => null,
        readLocal: () async => throw StateError('不应扫描'));
    await missing.check();
    expect(missing.needsFolder, isTrue);
    expect(missing.reports, isEmpty);
    missing.dispose();
    expect(
        () => NoteCheckController.validatedItems([
              {'relative_path': 'a.md', 'sha256': 'invalid'}
            ]),
        throwsFormatException);
    expect(() => NoteCheckController.validatedItems([...local(), ...local()]),
        throwsFormatException);
  });
  testWidgets('差异可见、错误不伪装成功，窄屏200%字号与详情可操作', (tester) async {
    final font = FontLoader('StudySans')
      ..addFont(Future.value(ByteData.sublistView(
          File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync())));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = oldShadows);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final checks = NoteCheckController(api: FakeApi(), android: true)
      ..reports = [report()]
      ..error = '电脑无法连接，本地笔记仍可读取';
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(390, 844), textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: RepaintBoundary(
                    key: key,
                    child: ListView(
                        children: [NoteCheckPanel(controller: checks)]))))));
    await tester.pumpAndSettle();
    expect(find.textContaining('本轮未核对成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = Directory(
          'build/test-artifacts/note-check')
        ..createSync(recursive: true);
      File('${out.path}/phone-panel-200.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.ensureVisible(find.text('查看差异'));
    await tester.tap(find.text('查看差异'));
    await tester.pumpAndSettle();
    expect(find.text('线性代数/矩阵.md'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    checks.dispose();
    debugDisableShadows = oldShadows;
  });
}
