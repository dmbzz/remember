import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:class_notes_assistant/data/pairing_connector.dart';
import 'package:class_notes_assistant/platform/pairing_discovery.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class RealHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

class LoopbackFinder extends PairingDiscovery {
  RawDatagramSocket? socket;
  @override
  Future<PairingDiscoveryResult> discover(String requestId) async {
    final port = int.parse(Platform.environment['CNA_PAIRING_E2E_UDP']!);
    final ready = Completer<PairingDiscoveryResult>();
    final host = InternetAddress(Platform.environment['CNA_PAIRING_E2E_HOST']!);
    socket = await RawDatagramSocket.bind(host, 0);
    final subscription = socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket!.receive();
      if (packet == null || packet.port != port) return;
      final raw = jsonDecode(utf8.decode(packet.data)) as Map;
      expect(raw['nonce'], requestId);
      expect(raw['app'], 'class_notes_assistant');
      expect(raw.containsKey('code'), isFalse);
      expect(raw.containsKey('token'), isFalse);
      final computer =
          PairingComputer.fromMap({...raw, 'host': packet.address.address});
      if (computer != null && !ready.isCompleted)
        ready.complete(PairingDiscoveryResult(computers: [computer]));
    });
    try {
      socket!.send(
          utf8.encode(jsonEncode({
            'app': 'class_notes_assistant',
            'version': 1,
            'nonce': requestId
          })),
          host,
          port);
      return await ready.future.timeout(const Duration(seconds: 3));
    } finally {
      await subscription.cancel();
      socket?.close();
      socket = null;
    }
  }

  @override
  Future<void> cancel(String id) async {
    socket?.close();
    socket = null;
  }
}

void main() {
  final url = Platform.environment['CNA_PAIRING_E2E_URL'];
  test(
      'actual isolated UDP discovery, six-digit HTTP exchange and token revocation',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final dio = Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:17840', validateStatus: (_) => true));
      final phone =
          Dio(BaseOptions(baseUrl: url!, validateStatus: (_) => true));
      try {
        final before = (await dio.get('/api/pairing/info')).data['data'] as Map;
        final connector = PairingConnector(discovery: LoopbackFinder());
        final paired = await connector.pair(before['code'] as String,
            knownBaseUrl: 'none');
        expect(paired.ok, isTrue, reason: paired.error);
        expect(paired.data!['base_url'], url);
        expect(
            (await dio.get('/api/pairing/info')).data['data']['paired_devices'],
            before['paired_devices'] + 1);
        final access = paired.data!['token']!;
        expect(
            (await phone.get('/api/pairing/check',
                    options:
                        Options(headers: {'Authorization': 'Bearer $access'})))
                .statusCode,
            200);
        await dio.post('/api/pairing/revoke-all');
        expect(
            (await phone.get('/api/pairing/check',
                    options:
                        Options(headers: {'Authorization': 'Bearer $access'})))
                .statusCode,
            401);
        final pin = (await dio.get('/api/pairing/info')).data['data']['code'];
        expect(
            (await connector.pair('${url.substring(7)}#$pin',
                    knownBaseUrl: 'none'))
                .ok,
            isTrue);
      } finally {
        dio.close(force: true);
        phone.close(force: true);
      }
    }, RealHttp());
  },
      skip: url == null
          ? 'Requires the task-owned isolated backend; never targets the installed server.'
          : false);
}
