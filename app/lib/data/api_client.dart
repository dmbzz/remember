import 'package:dio/dio.dart';
import '../core/constants.dart';
import 'api_result.dart';

/// 统一 API 客户端（Dio 封装）。
///
/// **根因修复（§7.2 禁止把没做当成做成了）**：本类所有数据获取方法一律返回
/// [ApiResult]，**绝不把异常吞成空数据**。原先 `catch (_) {} return [];` 会让
/// 「连不上后端」显示成「暂无课程」，用户看不到任何错误——这正是本次「Windows 端
/// 课表刷不出来」的根因之一。失败时 [ApiResult.error] 会带上**实际请求的 URL**，
/// 用户一眼能看出连的是哪个地址。
class ApiClient {
  Future<ApiResult<Map<String, dynamic>>> getDesktopSettings() => _getMap('/api/settings/desktop');
  Future<ApiResult<Map<String, dynamic>>> saveDesktopSettings(bool notify) => _putMap('/api/settings/desktop', data: {'asr_notifications': notify});
  Future<ApiResult<List<Map<String, dynamic>>>> getNoteChoices(
          Map<String, String> scope) =>
      _getList('/api/notes/file-sync/choices', query: scope);
  Future<ApiResult<Map<String, dynamic>>> chooseNoteVersion(
          Map<String, dynamic> value) =>
      _postMap('/api/notes/file-sync/choices', data: value);
  Future<ApiResult<Map<String, dynamic>>> applyNoteChoice(
          String id, Map<String, dynamic> value) =>
      _postMap('/api/notes/file-sync/choices/${Uri.encodeComponent(id)}/apply',
          data: value);
  Future<ApiResult<Map<String, dynamic>>> rejectNoteChoice(
          String id, Map<String, String> scope) =>
      _postMap('/api/notes/file-sync/choices/${Uri.encodeComponent(id)}/reject',
          data: scope);
  Future<ApiResult<Map<String, dynamic>>> getAsrSettings() =>
      _getMap('/api/settings/asr');
  Future<ApiResult<Map<String, dynamic>>> saveAsrSettings(
          Map<String, dynamic> value) =>
      _putMap('/api/settings/asr', data: value);
  Future<ApiResult<Map<String, dynamic>>> testAsrSettings(
          Map<String, dynamic> value) =>
      _postMap('/api/settings/asr/test',
          data: value,
          options: Options(receiveTimeout: const Duration(seconds: 90)));
  Future<ApiResult<Map<String, dynamic>>> detectAsrSettings() =>
      _postMap('/api/settings/asr/detect', data: {});
  Future<ApiResult<List<Map<String, dynamic>>>> getAsrJobs() =>
      _getList('/api/asr/jobs');
  Future<ApiResult<Map<String, dynamic>>> retryAsrJob(String id) =>
      _postMap('/api/asr/jobs/${Uri.encodeComponent(id)}/retry', data: {});

  late final Dio dio;
  String baseUrl;
  String? pairingToken;
  void Function()? onConnectionReady;

  Future<ApiResult<List<Map<String, dynamic>>>> getRecordings() =>
      _getList('/api/recordings');

  /// [baseUrl] 为空时取 [AppConstants.defaultBaseUrl]（按平台）。
  ApiClient({String? baseUrl, this.pairingToken})
      : baseUrl = baseUrl ?? AppConstants.defaultBaseUrl {
    dio = Dio(
      BaseOptions(
        baseUrl: this.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (pairingToken != null && pairingToken!.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $pairingToken';
          }
          return handler.next(options);
        },
      ),
    );
  }

  void updateBaseUrl(String newUrl) {
    baseUrl = newUrl;
    dio.options.baseUrl = newUrl;
  }

  void updatePairingToken(String? token) {
    pairingToken = token;
  }

  Future<ApiResult<Map<String, dynamic>>> getPairingInfo() =>
      _getMap('/api/pairing/info');

  Future<ApiResult<Map<String, dynamic>>> getLocalPaths() =>
      _getMap('/api/settings/local-paths');

  Future<ApiResult<Map<String, dynamic>>> saveLocalPaths(
          Map<String, String> paths) =>
      _putMap('/api/settings/local-paths', data: paths);

  Future<ApiResult<Map<String, dynamic>>> getNotesManifest() =>
      _getMap('/api/notes/local-manifest');

  Future<ApiResult<Map<String, dynamic>>> getNoteFileManifest() =>
      _getMap('/api/notes/file-sync/manifest');

  Future<ApiResult<Map<String, dynamic>>> getNoteFileContent(
          String path, String hash, String vault) =>
      _getMap('/api/notes/file-sync/content',
          query: {'path': path, 'sha256': hash, 'vault_id': vault});

  Future<ApiResult<List<Map<String, dynamic>>>> getNoteChecks() =>
      _getList('/api/notes/local-checks');

  Future<ApiResult<Map<String, dynamic>>> recordNoteCheck(
          Map<String, dynamic> snapshot) =>
      _postMap('/api/notes/local-checks', data: snapshot);

  Future<ApiResult<Map<String, dynamic>>> checkPairing() =>
      _getMap('/api/pairing/check');

  Future<ApiResult<Map<String, dynamic>>> revokeAllPairings() async {
    try {
      final response = await dio.post('/api/pairing/revoke-all');
      if (response.statusCode == 200 &&
          response.data is Map &&
          response.data['code'] == 0) {
        return ApiResult.ok(
            (response.data['data'] as Map).cast<String, dynamic>());
      }
      return ApiResult.failed(_badResponse(response));
    } on DioException catch (error) {
      return ApiResult.failed(_dioError(error));
    }
  }

  /// 在更新当前地址和令牌前，先向目标电脑验证连接码。
  Future<ApiResult<Map<String, String>>> pairWithComputer(
      String connectionCode) async {
    final value = connectionCode.trim().replaceFirst(RegExp(r'^https?://'), '');
    final match = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})#(\d{6})$')
        .firstMatch(value);
    if (match == null ||
        match.group(1)!.split('.').any((part) => int.parse(part) > 255) ||
        int.parse(match.group(2)!) < 1 ||
        int.parse(match.group(2)!) > 65535) {
      return const ApiResult.failed('连接码格式不正确，请输入电脑显示的完整连接码');
    }
    final target = 'http://${match.group(1)}:${match.group(2)}';
    final pairingClient = Dio(BaseOptions(
      baseUrl: target,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ));
    try {
      final response = await pairingClient.post('/api/pairing/exchange', data: {
        'code': match.group(3),
        'device_name': 'Android 手机',
      });
      if (response.statusCode == 200 &&
          response.data is Map &&
          response.data['code'] == 0) {
        final data = response.data['data'];
        final token = data is Map ? data['token'] : null;
        if (token is String && token.isNotEmpty) {
          return ApiResult.ok({'base_url': target, 'token': token});
        }
      }
      return ApiResult.failed('电脑返回了无效的配对响应：$target');
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map && detail['message'] != null) {
        return ApiResult.failed(detail['message'].toString());
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return const ApiResult.failed(
          '连接超时。请确认手机与电脑在同一网络；若连接码是 192.168.137.1，手机必须连接这台电脑的热点。也可以在电脑端试另一条连接码。',
        );
      }
      return ApiResult.failed(
          '无法连接电脑 $target：${error.message ?? error.type.name}');
    } finally {
      pairingClient.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 错误信息构造（一律带上实际请求的 URL，便于用户定位）
  // ---------------------------------------------------------------------------
  String _fullUrl(RequestOptions o) {
    final path = o.path;
    if (path.startsWith('http')) return path;
    final base = o.baseUrl.endsWith('/')
        ? o.baseUrl.substring(0, o.baseUrl.length - 1)
        : o.baseUrl;
    return '$base$path';
  }

  String _dioError(DioException e) {
    final url = _fullUrl(e.requestOptions);
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接后端超时：$url';
      case DioExceptionType.connectionError:
        return '无法连接后端 $url（请确认后端已启动，且地址正确）';
      case DioExceptionType.badResponse:
        if (e.response != null) return _badResponse(e.response!);
        final code = e.response?.statusCode;
        return '后端返回错误（HTTP $code）：$url';
      case DioExceptionType.cancel:
        return '请求已取消：$url';
      case DioExceptionType.badCertificate:
        return '后端证书校验失败：$url';
      default:
        // 含 DioExceptionType.unknown 以及不同 dio 版本新增的类型（如 transformTimeout）。
        return '请求后端失败：$url（${e.message ?? e.type.name}）';
    }
  }

  /// 响应到达了、但业务码非 0 或结构不符。
  String _badResponse(Response res) {
    final url = _fullUrl(res.requestOptions);
    final data = res.data;
    String? msg;
    if (data is Map) {
      msg = (data['message'] ?? data['detail'] ?? data['error'])?.toString();
    }
    return '后端返回异常（HTTP ${res.statusCode}）：$url'
        '${(msg != null && msg.isNotEmpty) ? ' — $msg' : ''}';
  }

  // ---------------------------------------------------------------------------
  // 通用请求（返回 ApiResult，绝不吞异常）
  // ---------------------------------------------------------------------------
  Future<ApiResult<List<Map<String, dynamic>>>> _getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await dio.get(path, queryParameters: query);
      if (res.statusCode == 200 && res.data is Map && res.data['code'] == 0) {
        final payload = res.data['data'];
        final list = payload is List
            ? payload
            : payload is Map && payload['items'] is List
                ? payload['items'] as List
                : throw const FormatException('列表响应缺少 items');
        return ApiResult.ok(list.cast<Map<String, dynamic>>());
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      return ApiResult.failed(_dioError(e));
    } catch (e) {
      return ApiResult.failed('解析后端响应失败：$e');
    }
  }

  Future<ApiResult<Map<String, dynamic>>> _getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await dio.get(path, queryParameters: query);
      if (res.statusCode == 200 && res.data is Map && res.data['code'] == 0) {
        final d = res.data['data'];
        if (d is Map<String, dynamic>) return ApiResult.ok(d);
        if (d is Map) return ApiResult.ok(d.cast<String, dynamic>());
        return ApiResult.failed('后端返回结构异常：${_fullUrl(res.requestOptions)}');
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      return ApiResult.failed(_dioError(e));
    } catch (e) {
      return ApiResult.failed('解析后端响应失败：$e');
    }
  }

  Future<ApiResult<Map<String, dynamic>>> _postMap(
    String path, {
    Object? data,
    Options? options,
  }) async {
    try {
      final res = await dio.post(path, data: data, options: options);
      if (res.statusCode == 200 && res.data is Map && res.data['code'] == 0) {
        final d = res.data['data'];
        if (d is Map<String, dynamic>) return ApiResult.ok(d);
        if (d is Map) return ApiResult.ok(d.cast<String, dynamic>());
        return const ApiResult.ok(<String, dynamic>{});
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      return ApiResult.failed(_dioError(e));
    } catch (e) {
      return ApiResult.failed('解析后端响应失败：$e');
    }
  }

  Future<ApiResult<Map<String, dynamic>>> _putMap(String path,
      {Object? data}) async {
    try {
      final res = await dio.put(path, data: data);
      if (res.statusCode == 200 &&
          res.data is Map &&
          res.data['code'] == 0 &&
          res.data['data'] is Map) {
        return ApiResult.ok((res.data['data'] as Map).cast<String, dynamic>());
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      final body = e.response?.data;
      return ApiResult.failed(body is Map && body['message'] != null
          ? body['message'].toString()
          : _dioError(e));
    } catch (e) {
      return ApiResult.failed('保存失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 业务方法
  // ---------------------------------------------------------------------------

  /// 检查服务端健康状态。
  Future<ApiResult<Map<String, dynamic>>> checkHealth() =>
      _getMap('/api/health');

  /// 获取笔记列表。
  Future<ApiResult<List<Map<String, dynamic>>>> getNotes({String? course}) =>
      _getList('/api/notes', query: {
        if (course != null) 'course': course,
      });

  /// 获取单篇笔记正文（Markdown）。失败时 [ApiResult.error] 带原因。
  Future<ApiResult<String>> getNoteContent(String noteId) async {
    final fullPath = '/api/notes/$noteId/content';
    try {
      final res = await dio.get(fullPath);
      if (res.statusCode == 200 && res.data is Map && res.data['code'] == 0) {
        final markdown = res.data['data']?['markdown'];
        return ApiResult.ok(markdown?.toString() ?? '');
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      return ApiResult.failed(_dioError(e));
    } catch (e) {
      return ApiResult.failed('解析后端响应失败：$e');
    }
  }

  Future<ApiResult<Map<String, dynamic>>> importSchedule({
    required String filename,
    required List<int> bytes,
    required String semester,
    required String semesterStart,
  }) async {
    try {
      final res = await dio.post('/api/schedule/import',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes, filename: filename),
            'semester': semester,
            'semester_start': semesterStart,
            'mode': 'merge',
          }),
          options: Options(contentType: 'multipart/form-data'));
      if (res.statusCode == 200 &&
          res.data is Map &&
          res.data['code'] == 0 &&
          res.data['data'] is Map) {
        return ApiResult.ok((res.data['data'] as Map).cast<String, dynamic>());
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      final body = e.response?.data;
      return ApiResult.failed(body is Map && body['message'] != null
          ? body['message'].toString()
          : _dioError(e));
    } catch (e) {
      return ApiResult.failed('课表导入失败：$e');
    }
  }

  /// 获取当天课表及进行状态。
  Future<ApiResult<Map<String, dynamic>>> getTodaySchedule() =>
      _getMap('/api/schedule/today');

  Future<ApiResult<Map<String, dynamic>>> getScheduleSnapshot() =>
      _getMap('/api/schedule/snapshot');
  Future<ApiResult<Map<String, dynamic>>> getSchedulePreferences() =>
      _getMap('/api/schedule/settings');
  Future<ApiResult<Map<String, dynamic>>> saveSchedulePreferences(
          Map<String, dynamic> data) =>
      _putMap('/api/schedule/settings', data: data);
  Future<ApiResult<Map<String, dynamic>>> saveManualSchedule(
          Map<String, dynamic> data) =>
      _postMap('/api/schedule/manual', data: data);

  /// 获取全量课表条目。
  Future<ApiResult<List<Map<String, dynamic>>>> getScheduleEntries() =>
      _getList('/api/schedule');

  /// 只调动指定日期的一节课，其他周不变。
  Future<ApiResult<Map<String, dynamic>>> rescheduleOccurrence({
    required String entryId,
    required String semesterStart,
    required String sourceDate,
    required String targetDate,
  }) async {
    try {
      final res = await dio.post('/api/schedule/$entryId/reschedule', data: {
        'semester_start': semesterStart,
        'source_date': sourceDate,
        'target_date': targetDate,
      });
      if (res.statusCode == 200 &&
          res.data is Map &&
          res.data['code'] == 0 &&
          res.data['data'] is Map) {
        return ApiResult.ok((res.data['data'] as Map).cast<String, dynamic>());
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      final body = e.response?.data;
      return ApiResult.failed(body is Map && body['message'] != null
          ? body['message'].toString()
          : _dioError(e));
    } catch (e) {
      return ApiResult.failed('调课失败：$e');
    }
  }

  /// 一键应用/导入预设专业课表。
  Future<ApiResult<Map<String, dynamic>>> applyPresetSchedule({
    String presetId = 'engineering_freshman_2026_fall',
  }) =>
      _postMap('/api/schedule/presets/$presetId/apply');

  /// 获取课程列表（含课程级 `auto_record` 开关，v3.3 / FR-33）。
  Future<ApiResult<List<Map<String, dynamic>>>> getCourses(
          {String? semester}) =>
      _getList('/api/courses', query: {
        if (semester != null) 'semester': semester,
      });

  /// 设置某门课程的**自动录音**开关（课程级，FR-33）。
  ///
  /// 成功返回 `ApiResult.ok(true)`；失败返回带原因的 `ApiResult.failed(...)`，
  /// 由 UI 回滚乐观更新并提示（不再静默失败）。
  Future<ApiResult<bool>> setCourseAutoRecord(
      String courseId, bool autoRecord) async {
    try {
      final res = await dio
          .put('/api/courses/$courseId', data: {'auto_record': autoRecord});
      if (res.statusCode == 200 && res.data is Map && res.data['code'] == 0) {
        return const ApiResult.ok(true);
      }
      return ApiResult.failed(_badResponse(res));
    } on DioException catch (e) {
      return ApiResult.failed(_dioError(e));
    } catch (e) {
      return ApiResult.failed('保存失败：$e');
    }
  }

  /// 检查移动端是否有新版本（架构设计：应用内热更新流）。
  Future<ApiResult<Map<String, dynamic>>> checkAppVersion(
          {int currentCode = 1}) =>
      _getMap('/api/app/version', query: {'current_code': currentCode});

  /// 应用内流式下载 APK 并上报实时百分比进度。
  ///
  /// 下载属于「文件落盘」操作，保留 `bool` 返回值即可（UI 已有失败分支）；
  /// 但**不再吞异常**：失败时返回 false 并由调用方提示。
  Future<bool> downloadApk({
    required String downloadUrl,
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final fullUrl = downloadUrl.startsWith('http')
          ? downloadUrl
          : (baseUrl.endsWith('/')
              ? '${baseUrl.substring(0, baseUrl.length - 1)}$downloadUrl'
              : '$baseUrl$downloadUrl');

      final res = await dio.download(
        fullUrl,
        savePath,
        onReceiveProgress: onProgress,
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

