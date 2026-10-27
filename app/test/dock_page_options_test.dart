import 'package:class_notes_assistant/core/adaptive_navigation.dart';
import 'package:class_notes_assistant/core/theme.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/upload_queue.dart';
import 'package:class_notes_assistant/features/recording/recording_files_page.dart';
import 'package:class_notes_assistant/features/recording/recording_page.dart';
import 'package:class_notes_assistant/main.dart';
import 'package:class_notes_assistant/platform/recording_bridge_stub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const destinations = [
  (Icons.calendar_today_outlined, Icons.calendar_today, '课表'),
  (Icons.menu_book_outlined, Icons.menu_book, '笔记'),
  (Icons.mic_none, Icons.mic, '录音'),
  (Icons.settings_outlined, Icons.settings, '设置'),
];
final dock = find.byKey(const ValueKey('touch-orientation-capsule'));

void main() {
  for (final page in ['settings', 'files', 'recording']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$page $scale: options clear expanded rail, hover keeps position, bottom reachable', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1100, 700);
        addTearDown(tester.view.reset);
        final api = ApiClient(baseUrl: 'http://dock-test.invalid');
        api.dio.interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
          dynamic data = <String, dynamic>{};
          if (r.path.contains('courses') || r.path.contains('recordings')) {
            data = <Map<String, dynamic>>[];
          }
          h.resolve(Response(requestOptions: r, statusCode: 200,
              data: {'code': 0, 'data': data, 'message': 'ok'}));
        }));
        final queue = UploadQueue(apiClient: api);
        final content = page == 'settings'
            ? SettingsPage(apiClient: api, recordingBridge: StubRecordingBridge())
            : page == 'files'
                ? RecordingFilesPage(uploadQueue: queue, apiClient: api)
                : RecordingPage(recordingBridge: StubRecordingBridge(), uploadQueue: queue, apiClient: api);
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.lightTheme.copyWith(platform: TargetPlatform.windows),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
            home: StudyNavigationLayout(content: content, destinations: destinations,
                selectedIndex: page == 'settings' ? 3 : 2, onSelected: (_) {})));
        await tester.pumpAndSettle();
        final cards = find.byType(Card);
        // The first real card is a full page option, not a mock clearance probe.
        final card = page == 'recording' ? find.byType(DropdownButtonFormField<String>) : cards.first;
        final before = tester.getRect(card);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1000, 600));
        await mouse.moveTo(tester.getCenter(dock));
        await tester.pumpAndSettle();
        final rail = tester.getRect(dock);
        expect(before.left, greaterThan(rail.right + 8));
        expect(tester.getRect(card), before, reason: 'hover must not move options');
        final bodyScroll = find.descendant(of: find.byType(Scaffold).last, matching: find.byType(Scrollable)).first;
        if (page == 'settings') {
          final tile = find.widgetWithText(ListTile, '后端服务器地址');
          await tester.scrollUntilVisible(tile, 160, scrollable: bodyScroll);
          await tester.pumpAndSettle();
          expect(tester.getRect(tile).left, greaterThan(rail.right));
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(find.text('修改后端服务地址'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        // Change to bottom navigation; same page State and scroll must survive.
        final state = tester.state<ScrollableState>(bodyScroll);
        tester.view.physicalSize = const Size(540, 760);
        await mouse.moveTo(const Offset(500, 50));
        await tester.pumpAndSettle();
        expect(identical(state, tester.state(bodyScroll)), isTrue);
        final last = page == 'settings' ? find.text('手动刷新检测更新')
            : page == 'files' ? find.text('暂无待上传的录音文件')
            : find.text('刷新自动录音排期');
        await tester.scrollUntilVisible(last, 250, scrollable: bodyScroll);
        state.position.jumpTo(state.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(last, findsWidgets);
        expect(tester.getRect(last.last).bottom, lessThan(tester.getRect(dock).top), reason: 'last option must scroll above bottom Dock');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        queue.dispose();
        api.dio.close(force: true);
        await mouse.removePointer();
      });
    }
  }
}
