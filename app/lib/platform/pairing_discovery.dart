import 'dart:io';
import 'package:flutter/services.dart';

class PairingComputer {
  const PairingComputer(this.host, this.port, {this.serverId, this.name = ''});
  final String host;
  final int port;
  final String? serverId;
  final String name;
  String get baseUrl => 'http://$host:$port';

  static PairingComputer? fromMap(Map value) {
    final host = value['host'];
    final port = value['port'];
    final id = value['server_id'];
    if (host is! String ||
        InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4 ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{16}$').hasMatch(id)) return null;
    return PairingComputer(host, port,
        serverId: id,
        name: '${value['name'] ?? ''}'
            .substring(0, '${value['name'] ?? ''}'.length.clamp(0, 64)));
  }
}

class PairingDiscoveryResult {
  const PairingDiscoveryResult(
      {this.computers = const [],
      this.gateways = const [],
      this.status = 'ok'});
  final List<PairingComputer> computers;
  final List<String> gateways;
  final String status;
}

/// Discovery carries only an application identity and nonce. PINs use unicast HTTP.
class PairingDiscovery {
  static const channel = MethodChannel('class_notes/pairing_discovery');
  Future<PairingDiscoveryResult> discover(String requestId) async {
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>(
          'discover', {'request_id': requestId});
      if (raw == null) {
        return const PairingDiscoveryResult(status: 'unavailable');
      }
      final computers = <PairingComputer>[];
      for (final value in (raw['servers'] as List? ?? const []).take(8)) {
        if (value is Map) {
          final computer = PairingComputer.fromMap(value);
          if (computer != null) computers.add(computer);
        }
      }
      final gateways = (raw['gateways'] as List? ?? const [])
          .whereType<String>()
          .where((v) =>
              InternetAddress.tryParse(v)?.type == InternetAddressType.IPv4)
          .take(4)
          .toList();
      return PairingDiscoveryResult(
          computers: computers,
          gateways: gateways,
          status: '${raw['status'] ?? 'unavailable'}');
    } on MissingPluginException {
      return const PairingDiscoveryResult(status: 'unavailable');
    } on PlatformException {
      return const PairingDiscoveryResult(status: 'unavailable');
    }
  }

  Future<void> cancel(String requestId) async {
    try {
      await channel.invokeMethod<void>('cancel', {'request_id': requestId});
    } on MissingPluginException {
      /* Unsupported hosts have no native socket. */
    } on PlatformException {
      /* Native teardown may already have closed the socket. */
    }
  }
}
