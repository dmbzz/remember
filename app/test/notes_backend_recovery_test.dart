import 'dart:io';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/features/notes/notes_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首次后端失败后刷新先恢复服务，再加载真实响应列表', (tester) async {
    var preparations = 0;
    var requests = 0;
    final api = ApiClient(baseUrl: 'http://127.0.0.1:8000');
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests++;
      if (requests == 1) {
        handler.resolve(Response(
            requestOptions: request,
            statusCode: 200,
            data: {'code': 500, 'message': '服务暂不可用', 'data': null}));
      } else {
        handler
            .resolve(Response(requestOptions: request, statusCode: 200, data: {
          'code': 0,
          'message': 'ok',
          'data': {
            'items': [
              {
                'note_id': 'recovered-note',
                'topic': '转动的功与能',
                'course_name': '工程力学',
                'class_date': '2026-10-14'
              },
            ],
            'total': 1
          }
        }));
      }
    }));
    await tester.pumpWidget(MaterialApp(
        home: NotesPage(
            apiClient: api, prepareLocalBackend: () async => preparations++)));
    await tester.pumpAndSettle();
    expect(preparations, 1);
    expect(find.textContaining('服务暂不可用'), findsWidgets);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新笔记'));
    await tester.pumpAndSettle();
    expect(preparations, 2);
    expect(requests, 2);
    expect(find.text('转动的功与能'), findsOneWidget);
    expect(find.textContaining('服务暂不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('远端服务器刷新不启动本机服务', (tester) async {
    var preparations = 0;
    final api = ApiClient(baseUrl: 'http://remote.test:8000');
    api.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: {
              'code': 0,
              'message': 'ok',
              'data': {'items': [], 'total': 0}
            }))));
    await tester.pumpWidget(MaterialApp(
        home: NotesPage(
            apiClient: api, prepareLocalBackend: () async => preparations++)));
    await tester.pumpAndSettle();
    expect(preparations, 0);
    expect(tester.takeException(), isNull);
  });
}
