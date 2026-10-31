import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import '../platform/pairing_discovery.dart';
import 'api_result.dart';

String normalizePairingDigits(String value) => String.fromCharCodes(
    value.runes.map((v) => v >= 0xff10 && v <= 0xff19 ? v - 0xfee0 : v));

typedef PairingClientFactory = Dio Function(String baseUrl, Duration timeout);

/// Keeps discovery, candidate verification and tokens separate from the live API.
class PairingConnector {
  PairingConnector(
      {PairingDiscovery? discovery, PairingClientFactory? clientFactory})
      : discovery = discovery ?? PairingDiscovery(),
        clientFactory = clientFactory ?? _client;
  final PairingDiscovery discovery;
  final PairingClientFactory clientFactory;
  CancelToken? _active;
  String? _requestId;

  static Dio _client(String url, Duration timeout) => Dio(BaseOptions(
      baseUrl: url,
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
      followRedirects: false,
      maxRedirects: 0,
      headers: {'Accept': 'application/json'}));

  void cancel() {
    _active?.cancel('已取消连接');
    _active = null;
    final request = _requestId;
    _requestId = null;
    if (request != null) unawaited(discovery.cancel(request));
  }

  bool _current(CancelToken token) =>
      identical(_active, token) && !token.isCancelled;
  static Map? _data(Response response) => response.statusCode == 200 &&
          response.data is Map &&
          response.data['code'] == 0 &&
          response.data['data'] is Map
      ? response.data['data'] as Map
      : null;

  static String? _knownUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path) ||
        InternetAddress.tryParse(uri.host)?.type != InternetAddressType.IPv4 ||
        uri.port < 1 ||
        uri.port > 65535) return null;
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  Future<ApiResult<Map<String, String>>> pair(String code,
      {required String knownBaseUrl}) async {
    cancel();
    final token = CancelToken();
    _active = token;
    final value = normalizePairingDigits(code).replaceAll(RegExp(r'\s+'), '');
    final short = RegExp(r'^[0-9]{6}$').hasMatch(value);
    final legacy =
        RegExp(r'^(?:https?://)?(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})#(\d{6})$')
            .firstMatch(value);
    if (!short &&
        (legacy == null ||
            legacy.group(1)!.split('.').any((v) => int.parse(v) > 255) ||
            int.parse(legacy.group(2)!) < 1 ||
            int.parse(legacy.group(2)!) > 65535)) {
      cancel();
      return const ApiResult.failed('请输入电脑显示的6位数字；完整地址请使用“手动连接”。');
    }
    try {
      if (!short) {
        return await _exchange('http://${legacy!.group(1)}:${legacy.group(2)}',
            legacy.group(3)!, token);
      }
      final attempted = <String>{};
      final denied = <String>{}, inFlight = <String>{};
      String? lastError, pinError;
      Future<String?> resolve(String target, String? expectedId) async {
        if (!_current(token) || !attempted.add(target)) return null;
        final client =
            clientFactory(target, const Duration(milliseconds: 1200));
        String? identity = expectedId;
        var claimed = false;
        try {
          if (identity == null) {
            final public =
                await client.get('/api/pairing/identity', cancelToken: token);
            final id = _data(public)?['server_id'];
            if (id is! String || !RegExp(r'^[a-f0-9]{16}$').hasMatch(id)) {
              return null;
            }
            identity = id;
          }
          if (!_current(token) ||
              denied.contains(identity) ||
              !inFlight.add(identity)) return null;
          claimed = true;
          final response = await client.post('/api/pairing/resolve',
              data: {'code': value, 'server_id': identity}, cancelToken: token);
          final id = _data(response)?['server_id'];
          if (id is String && identity == id) return id;
        } on DioException catch (e) {
          if (e.response?.statusCode == 429) {
            lastError = '尝试次数过多，请五分钟后重试。';
            if (identity != null) denied.add(identity);
          }
          if (e.response?.statusCode == 403) {
            pinError = '连接码错误或已过期，请输入电脑当前显示的6位码，或使用“手动连接”。';
            if (identity != null) denied.add(identity);
          }
        } finally {
          if (claimed) inFlight.remove(identity);
          client.close(force: true);
        }
        return null;
      }

      final known = _knownUrl(knownBaseUrl);
      if (known != null) {
        final id = await resolve(known, null);
        if (!_current(token)) return const ApiResult.failed('已取消连接');
        if (id != null) {
          return await _exchange(known, value, token, serverId: id);
        }
      }
      final random = Random.secure();
      final request = List.generate(
              16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      _requestId = request;
      final found = await discovery.discover(request);
      if (!_current(token)) return const ApiResult.failed('已取消连接');
      final candidates = <String, String?>{};
      for (final computer in found.computers.take(8)) {
        candidates[computer.baseUrl] = computer.serverId;
      }
      for (final gateway in found.gateways.take(4)) {
        candidates.putIfAbsent('http://$gateway:8000', () => null);
      }
      final entries = candidates.entries
          .where((v) => !attempted.contains(v.key))
          .take(12)
          .toList();
      final groups = <String, List<MapEntry<String, String?>>>{};
      for (final entry in entries) {
        (groups[entry.value ?? 'url:${entry.key}'] ??= []).add(entry);
      }
      final grouped = groups.values.toList();
      final matches = <String, String>{};
      // One explicit wrong PIN counts once per computer, including multiple NICs.
      for (var start = 0; start < grouped.length; start += 4) {
        await Future.wait(grouped.skip(start).take(4).map((group) async {
          for (final entry in group) {
            if (entry.value != null && denied.contains(entry.value)) break;
            final id = await resolve(entry.key, entry.value);
            if (id != null) {
              matches[entry.key] = id;
              break;
            }
            if (!_current(token)) break;
          }
        }));
        if (!_current(token)) return const ApiResult.failed('已取消连接');
      }
      if (matches.values.toSet().length > 1) {
        return const ApiResult.failed('找到多台使用同一连接码的电脑，请用“手动连接”选择具体地址。');
      }
      if (matches.isNotEmpty) {
        return await _exchange(matches.keys.first, value, token,
            serverId: matches.values.first);
      }
      return ApiResult.failed(lastError ??
          pinError ??
          (found.status == 'no_wifi'
              ? '请连接电脑所在的 Wi-Fi 或电脑热点，再输入6位连接码。'
              : '未找到使用此连接码的电脑。请核对当前6位码及同一 Wi-Fi；也可使用下方“手动连接”。'));
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return const ApiResult.failed('已取消连接');
      return const ApiResult.failed('连接未完成，请重试或使用“手动连接”。');
    } on Object {
      return const ApiResult.failed('自动寻找暂不可用，请重试或使用“手动连接”。');
    } finally {
      if (identical(_active, token)) cancel();
    }
  }

  Future<ApiResult<Map<String, String>>> _exchange(
      String target, String pin, CancelToken token,
      {String? serverId}) async {
    if (!_current(token)) return const ApiResult.failed('已取消连接');
    final client = clientFactory(target, const Duration(seconds: 5));
    try {
      final response = await client.post('/api/pairing/exchange',
          data: {
            'code': pin,
            'device_name': 'Android 手机',
            if (serverId != null) 'server_id': serverId
          },
          cancelToken: token);
      final data = _data(response), access = data?['token'];
      if (access is! String || access.isEmpty) {
        return const ApiResult.failed('电脑返回了无效的配对响应，请重试。');
      }
      final check = await client.get('/api/pairing/check',
          options: Options(headers: {'Authorization': 'Bearer $access'}),
          cancelToken: token);
      if (!_current(token)) return const ApiResult.failed('已取消连接');
      if (_data(check)?['connected'] != true) {
        return const ApiResult.failed('电脑未确认连接成功，原有连接已保留。');
      }
      return ApiResult.ok({'base_url': target, 'token': access});
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return const ApiResult.failed('已取消连接');
      final body = e.response?.data;
      if (body is Map && body['message'] is String) {
        return ApiResult.failed(body['message'] as String);
      }
      return const ApiResult.failed('连接电脑超时或不可达，请确认同一网络，并允许电脑的专用网络访问。');
    } finally {
      client.close(force: true);
    }
  }
}
