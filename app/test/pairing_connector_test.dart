import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:class_notes_assistant/data/pairing_connector.dart';
import 'package:class_notes_assistant/features/pairing/pairing_page.dart';
import 'package:class_notes_assistant/platform/pairing_discovery.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const one = 'aaaaaaaaaaaaaaaa', two = 'bbbbbbbbbbbbbbbb';

class Finder extends PairingDiscovery {
  Finder(this.result);
  Future<PairingDiscoveryResult> result;
  final requests = <String>[], cancelled = <String>[];
  @override
  Future<PairingDiscoveryResult> discover(String id) {
    requests.add(id);
    return result;
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }
}

class Wire implements HttpClientAdapter {
  Wire(this.handle);
  final Future<ResponseBody> Function(RequestOptions) handle;
  @override
  Future<ResponseBody> fetch(
          RequestOptions o, Stream<Uint8List>? s, Future<void>? cancelFuture) =>
      handle(o);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(Map data, {int status = 200}) => ResponseBody.fromString(
        jsonEncode({
          'code': status == 200 ? 0 : 403,
          'data': data,
          'message': '连接码错误或已过期'
        }),
        status,
        headers: {
          'content-type': ['application/json']
        });
PairingClientFactory factory(List<RequestOptions> calls,
        {bool Function(RequestOptions)? match,
        Map<String, String>? identities,
        bool connected = true}) =>
    (url, timeout) {
      final dio = Dio(BaseOptions(
          baseUrl: url,
          connectTimeout: timeout,
          receiveTimeout: timeout,
          followRedirects: false));
      dio.httpClientAdapter = Wire((o) async {
        calls.add(o);
        if (o.path.endsWith('/identity'))
          return response({
            'server_id': identities?[o.uri.host] ?? one,
            'name': 'PC',
            'port': o.uri.port
          });
        if (o.path.endsWith('/resolve')) {
          if (match != null && !match(o)) return response({}, status: 403);
          return response({
            'server_id': identities?[o.uri.host] ?? one,
            'port': o.uri.port,
            'name': 'PC'
          });
        }
        if (o.path.endsWith('/exchange'))
          return response({'token': 'new-test-token'});
        return response({'connected': connected});
      });
      return dio;
    };
Finder finder(
        {List<PairingComputer> computers = const [],
        List<String> gateways = const [],
        String status = 'ok'}) =>
    Finder(Future.value(PairingDiscoveryResult(
        computers: computers, gateways: gateways, status: status)));

void main() {
  test(
      'six digits retain leading zero and prefer the known PC without discovery',
      () async {
    final calls = <RequestOptions>[];
    final f = finder();
    final c = PairingConnector(discovery: f, clientFactory: factory(calls));
    final value =
        await c.pair('００１ ２３４', knownBaseUrl: 'http://192.168.137.1:8000');
    expect(value.ok, isTrue);
    expect(f.requests, isEmpty);
    expect(calls.map((o) => o.path), [
      '/api/pairing/identity',
      '/api/pairing/resolve',
      '/api/pairing/exchange',
      '/api/pairing/check'
    ]);
    expect((calls[1].data as Map)['code'], '001234');
    expect(calls[0].headers['Authorization'], isNull);
    expect(calls[1].headers['Authorization'], isNull);
    expect(calls.last.headers['Authorization'], 'Bearer new-test-token');
  });
  test('first-time discovery tests codes without creating tokens for wrong PCs',
      () async {
    final calls = <RequestOptions>[];
    final f = finder(computers: const [
      PairingComputer('192.168.1.2', 8000, serverId: one),
      PairingComputer('192.168.1.3', 8000, serverId: two)
    ]);
    final c = PairingConnector(
        discovery: f,
        clientFactory: factory(calls,
            match: (o) => o.uri.host.endsWith('.3'),
            identities: {'192.168.1.3': two}));
    final value = await c.pair('123456', knownBaseUrl: 'not-an-address');
    expect(value.data?['base_url'], 'http://192.168.1.3:8000');
    expect(calls.where((o) => o.path.endsWith('/exchange')).single.uri.host,
        '192.168.1.3');
    expect(f.requests.single, matches(RegExp(r'^[0-9a-f]{32}$')));
  });
  test('two actual computers with one code require an explicit address',
      () async {
    final calls = <RequestOptions>[];
    final f = finder(computers: const [
      PairingComputer('192.168.1.2', 8000, serverId: one),
      PairingComputer('192.168.1.3', 8000, serverId: two)
    ]);
    final c = PairingConnector(
        discovery: f,
        clientFactory: factory(calls,
            identities: {'192.168.1.2': one, '192.168.1.3': two}));
    final value = await c.pair('123456', knownBaseUrl: 'none');
    expect(value.error, contains('多台'));
    expect(calls.where((o) => o.path.endsWith('/exchange')), isEmpty);
  });
  test('several addresses of one computer are not mistaken for a PIN collision',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(computers: const [
          PairingComputer('192.168.1.2', 8000, serverId: one),
          PairingComputer('192.168.1.3', 8000, serverId: one)
        ]),
        clientFactory: factory(calls));
    expect((await c.pair('123456', knownBaseUrl: 'none')).ok, isTrue);
    expect(calls.where((o) => o.path.endsWith('/exchange')).length, 1);
  });
  test('hotspot gateway fallback works even when broadcasts are unavailable',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(gateways: ['192.168.137.1'], status: 'unavailable'),
        clientFactory: factory(calls));
    final value = await c.pair('123456', knownBaseUrl: 'none');
    expect(value.ok, isTrue);
    expect(value.data?['base_url'], 'http://192.168.137.1:8000');
  });
  test('a cancelled discovery cannot make HTTP requests after its late reply',
      () async {
    final pending = Completer<PairingDiscoveryResult>();
    final f = Finder(pending.future);
    final calls = <RequestOptions>[];
    final c = PairingConnector(discovery: f, clientFactory: factory(calls));
    final result = c.pair('123456', knownBaseUrl: 'none');
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    pending.complete(const PairingDiscoveryResult(
        computers: [PairingComputer('192.168.1.2', 8000, serverId: one)]));
    expect((await result).error, contains('取消'));
    expect(calls, isEmpty);
    expect(f.cancelled, isNotEmpty);
  });
  test('manual old full codes remain compatible and do not require resolve',
      () async {
    final calls = <RequestOptions>[];
    final f = finder();
    final c = PairingConnector(discovery: f, clientFactory: factory(calls));
    expect(
        (await c.pair('http:// 192.168.137.1:8000#１２３４５６',
                knownBaseUrl: 'none'))
            .ok,
        isTrue);
    expect(f.requests, isEmpty);
    expect(calls.map((o) => o.path),
        ['/api/pairing/exchange', '/api/pairing/check']);
    expect((calls.first.data as Map).containsKey('server_id'), isFalse);
  });
  for (final code in [
    '12345',
    '1234567',
    'word',
    '999.1.2.3:8000#123456',
    '192.168.1.2:0#123456'
  ]) {
    test('invalid input $code never starts network discovery', () async {
      final calls = <RequestOptions>[];
      final f = finder();
      final c = PairingConnector(discovery: f, clientFactory: factory(calls));
      expect((await c.pair(code, knownBaseUrl: 'none')).ok, isFalse);
      expect(calls, isEmpty);
      expect(f.requests, isEmpty);
    });
  }
  test(
      'wrong and expired short codes remain a code error instead of network success',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(),
        clientFactory: factory(calls, match: (_) => false));
    expect(
        (await c.pair('123456', knownBaseUrl: 'http://192.168.137.1:8000'))
            .error,
        contains('过期'));
  });
  test('the candidate must confirm the new token before returning success',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(), clientFactory: factory(calls, connected: false));
    expect((await c.pair('192.168.137.1:8000#123456', knownBaseUrl: 'none')).ok,
        isFalse);
  });
  test('candidate probing is bounded to eight advertised PCs and four gateways',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(
            computers: List.generate(
                30,
                (i) => PairingComputer('192.168.1.${i + 2}', 8000,
                    serverId: i.toRadixString(16).padLeft(16, '0'))),
            gateways: List.generate(30, (i) => '192.168.2.${i + 2}')),
        clientFactory: factory(calls, match: (_) => false));
    expect((await c.pair('123456', knownBaseUrl: 'none')).ok, isFalse);
    expect(calls.where((v) => v.path.endsWith('/resolve')).length,
        lessThanOrEqualTo(12));
    expect(calls.length, lessThanOrEqualTo(16));
  });
  test(
      'one wrong entry consumes only one guess for a known PC and all its aliases',
      () async {
    final calls = <RequestOptions>[];
    final c = PairingConnector(
        discovery: finder(
            computers: List.generate(
                5,
                (i) =>
                    PairingComputer('192.168.1.${i + 3}', 8000, serverId: one)),
            gateways: ['192.168.1.1']),
        clientFactory: factory(calls, match: (_) => false));
    expect((await c.pair('123456', knownBaseUrl: 'http://192.168.1.2:8000')).ok,
        isFalse);
    expect(calls.where((v) => v.path.endsWith('/resolve')).length, 1);
  });
  test(
      'mid-code edits retain the cursor, and grouped full-width input normalizes',
      () {
    final formatter = ShortPairingCodeFormatter();
    const before = TextEditingValue(
        text: '123456', selection: TextSelection.collapsed(offset: 3));
    final edit = formatter.formatEditUpdate(
        before,
        const TextEditingValue(
            text: '129456', selection: TextSelection.collapsed(offset: 3)));
    expect(edit.text, '129456');
    expect(edit.selection.baseOffset, 3);
    expect(
        formatter
            .formatEditUpdate(
                before,
                const TextEditingValue(
                    text: '１２３ ４５６',
                    selection: TextSelection.collapsed(offset: 7)))
            .text,
        '123456');
    expect(
        formatter.formatEditUpdate(
            before, const TextEditingValue(text: '192.168.1.2:8000#123456')),
        before);
  });
}
