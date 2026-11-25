import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import '../platform/recording_bridge.dart';
import '../platform/local_recording_actions.dart';

enum UploadStatus {
  pending,
  uploading,
  completed,
  failed,
  deleting,
  deleted,
}

class UploadItem {
  final String id;
  final String filePath;
  String courseId;
  final int lesson;
  final String classDate;
  final DateTime? createdAt;
  int progress; // 0..100
  UploadStatus status;
  String? error;
  String? recordingId;
  String? serverId;
  int durationMs;
  bool retryable;
  int attempts;

  UploadItem({
    required this.id,
    required this.filePath,
    required this.courseId,
    required this.lesson,
    required this.classDate,
    this.createdAt,
    this.progress = 0,
    this.status = UploadStatus.pending,
    this.error,
    this.recordingId,
    this.serverId,
    this.durationMs = 0,
    this.retryable = true,
    this.attempts = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'courseId': courseId,
        'lesson': lesson,
        'classDate': classDate,
        'createdAt': createdAt?.toIso8601String(),
        'progress': progress,
        'status': status.name,
        'error': error,
        'recordingId': recordingId,
        'serverId': serverId,
        'durationMs': durationMs,
        'retryable': retryable,
        'attempts': attempts,
      };

  factory UploadItem.fromJson(Map<String, dynamic> map) => UploadItem(
        id: map['id'] as String,
        filePath: map['filePath'] as String,
        courseId: map['courseId'] as String,
        lesson: map['lesson'] as int? ?? 1,
        classDate: map['classDate'] as String? ?? '',
        createdAt: DateTime.tryParse('${map['createdAt'] ?? ''}'),
        progress: map['progress'] as int? ?? 0,
        status: UploadStatus.values.firstWhere(
          (e) => e.name == map['status'],
          orElse: () => UploadStatus.pending,
        ),
        error: map['error'] as String?,
        recordingId: map['recordingId'] as String?,
        serverId: map['serverId'] as String?,
        durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
        retryable: map['retryable'] as bool? ?? true,
        attempts: map['attempts'] as int? ?? 0,
      );
}

/// 后台断点续传与录音上传队列（架构设计 §2.2 / §3.6）
class UploadQueue {
  final ApiClient apiClient;
  final List<UploadItem> _items = [];
  bool _isProcessing = false;
  bool _checkingConnection = false;
  bool _disposed = false;
  Timer? _retryTimer;
  final Duration retryDelay;
  final Future<void> Function(String filePath) _deleteLocalFile;
  final Set<String> _deletingIds = {};
  Future<void> _persistence = Future.value();
  String? recoveryError;
  int scannedFiles = 0;
  late final Future<void> _ready;
  final StreamController<List<UploadItem>> _streamController =
      StreamController<List<UploadItem>>.broadcast();

  UploadQueue(
      {required this.apiClient,
      this.retryDelay = const Duration(seconds: 20),
      Future<void> Function(String filePath)? deleteLocalFile})
      : _deleteLocalFile = deleteLocalFile ?? LocalRecordingActions.deleteFile {
    _ready = _loadPersistedQueue();
    _ready.then((_) {
      for (final item in _items) {
        if (item.status == UploadStatus.uploading ||
            (item.status == UploadStatus.failed &&
                item.retryable &&
                item.courseId.isNotEmpty)) {
          item.status = UploadStatus.pending;
          item.error = null;
          item.progress = 0;
        }
      }
      _notify();
      processNext();
    });
  }

  List<UploadItem> get items => List.unmodifiable(_items);
  Stream<List<UploadItem>> get queueStream => _streamController.stream;

  Future<void> _loadPersistedQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('class_notes_upload_queue');
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final restored = UploadItem.fromJson(item as Map<String, dynamic>);
          if (!_items.any((entry) => entry.filePath == restored.filePath)) {
            _items.add(restored);
          }
        }
        _notify();
      }
    } catch (_) {}
  }

  Future<void> _persistQueue({bool checked = false}) {
    // Capture each revision before awaiting preferences, and serialize writes.
    // A late upload-progress save must never overwrite a deletion reservation.
    final raw = jsonEncode(_items.map((e) => e.toJson()).toList());
    final write = _persistence.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('class_notes_upload_queue', raw)) {
        throw StateError('无法保存录音同步记录');
      }
    });
    _persistence = write.catchError((Object _) {});
    return checked ? write : _persistence;
  }

  void _notify() {
    if (!_disposed) _streamController.add(List.unmodifiable(_items));
    _persistQueue();
  }

  /// 入队待上传音频文件
  void enqueue({
    required String filePath,
    required String courseId,
    required int lesson,
    required String classDate,
    int durationMs = 0,
  }) {
    if (_items.any((item) => item.filePath == filePath)) return;
    final id = 'upl_${DateTime.now().microsecondsSinceEpoch}';
    final item = UploadItem(
      id: id,
      filePath: filePath,
      courseId: courseId,
      lesson: lesson,
      classDate: classDate,
      durationMs: durationMs,
      createdAt: DateTime.now(),
    );
    _items.add(item);
    _notify();
    processNext();
  }

  /// 扫描原生录音目录，恢复应用被系统结束前尚未入队的自动录音。
  Future<void> recoverLocalRecordings(RecordingBridge bridge) async {
    await _ready;
    try {
      final files = await bridge.listRecordingFiles();
      scannedFiles = files.length;
      recoveryError = null;
      for (final item in files) {
        final path = item['filePath'] as String? ?? '';
        if (path.isEmpty) continue;
        final discardRequested = item['discardRequested'] == true;
        final existing = _items.where((entry) => entry.filePath == path);
        if (existing.isNotEmpty) {
          if (discardRequested &&
              existing.first.status != UploadStatus.deleted &&
              existing.first.status != UploadStatus.uploading) {
            existing.first.status = UploadStatus.deleting;
            existing.first.retryable = false;
            existing.first.error = '删除未完成，已停止同步，请重试删除手机录音';
          }
          if (existing.first.durationMs <= 0) {
            existing.first.durationMs =
                (item['durationMs'] as num?)?.toInt() ?? 0;
          }
          continue;
        }
        if (discardRequested) {
          _items.add(UploadItem(
              id: 'discard_${DateTime.now().microsecondsSinceEpoch}',
              filePath: path,
              courseId: item['courseId'] as String? ?? '',
              lesson: 1,
              classDate: item['classDate'] as String? ?? '',
              createdAt: DateTime.now(),
              status: UploadStatus.deleting,
              retryable: false,
              error: '删除未完成，已停止同步，请重试删除手机录音'));
          continue;
        }
        final courseId = item['courseId'] as String? ?? '';
        if (courseId.isEmpty) {
          _items.add(UploadItem(
              id: 'unmatched_${DateTime.now().microsecondsSinceEpoch}',
              filePath: path,
              courseId: '',
              lesson: 1,
              classDate: item['classDate'] as String? ?? '',
              createdAt: DateTime.now(),
              status: UploadStatus.failed,
              retryable: false,
              error: '无法识别所属课程，请保留手机文件'));
          _notify();
          continue;
        }
        enqueue(
            filePath: path,
            courseId: courseId,
            durationMs: (item['durationMs'] as num?)?.toInt() ?? 0,
            lesson: 1,
            classDate: item['classDate'] as String? ?? '');
      }
      _notify();
    } catch (e) {
      recoveryError = '扫描手机录音失败：$e';
      _notify();
    }
  }

  Future<void> reconnect(RecordingBridge bridge) async {
    await recoverLocalRecordings(bridge);
    await retryWhenConnected();
    await processNext();
  }

  /// Retry failed items only after the same paired computer is reachable.
  Future<void> retryWhenConnected() async {
    await _ready;
    if (_disposed || _checkingConnection || _isProcessing) return;
    final failed = _items
        .where((item) =>
            item.status == UploadStatus.failed &&
            item.retryable &&
            item.courseId.isNotEmpty)
        .toList();
    if (failed.isEmpty) return;
    _checkingConnection = true;
    try {
      if (!(await apiClient.checkPairing()).ok) return;
      for (final item in failed) {
        if (!_items.contains(item) || item.status != UploadStatus.failed) {
          continue;
        }
        item.status = UploadStatus.pending;
        item.error = null;
      }
      _retryTimer?.cancel();
      _notify();
      await processNext();
    } finally {
      _checkingConnection = false;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer?.isActive == true) return;
    final failed = _items.where((item) =>
        item.status == UploadStatus.failed &&
        item.retryable &&
        item.courseId.isNotEmpty);
    if (failed.isEmpty) return;
    final attempt = failed.first.attempts.clamp(1, 4);
    _retryTimer = Timer(
        Duration(
            milliseconds: (retryDelay.inMilliseconds * (1 << (attempt - 1)))
                .clamp(100, 120000)
                .toInt()), () {
      _retryTimer = null;
      unawaited(retryWhenConnected());
    });
  }

  void assignCourse(String id, String courseId) {
    final item = _items.firstWhere((item) => item.id == id);
    if ((item.status != UploadStatus.pending &&
            item.status != UploadStatus.failed) ||
        courseId.isEmpty) return;
    item.courseId = courseId;
    item.recordingId = null;
    item.serverId = null;
    retry(id);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _streamController.close();
  }

  Future<void> _saveNow() async {
    if (!_disposed) _streamController.add(List.unmodifiable(_items));
    await _persistQueue();
  }

  Map<String, dynamic> _okData(Response<dynamic> response) {
    final envelope = response.data;
    if (response.statusCode != 200 ||
        envelope is! Map ||
        envelope['code'] != 0 ||
        envelope['data'] is! Map) {
      throw StateError(envelope is Map
          ? '${envelope['message'] ?? '电脑未确认录音'}'
          : '电脑返回了无效响应');
    }
    return (envelope['data'] as Map).cast<String, dynamic>();
  }

  /// 调度队列逐个执行上传
  Future<void> processNext() async {
    await _ready;
    if (_disposed || _isProcessing) return;

    final pending =
        _items.where((i) => i.status == UploadStatus.pending).toList();
    if (pending.isEmpty) return;

    _isProcessing = true;
    final current = pending.first;
    final revision = apiClient.connectionRevision;
    final endpoint = apiClient.baseUrl;
    final token = apiClient.pairingToken;
    void ensureConnection() {
      if (_disposed ||
          revision != apiClient.connectionRevision ||
          endpoint != apiClient.baseUrl ||
          token != apiClient.pairingToken) {
        throw StateError('电脑连接已变化，请重试；未删除手机录音');
      }
    }

    Options scoped() => Options(extra: {'connectionRevision': revision});

    try {
      current.status = UploadStatus.uploading;
      current.progress = 0;
      current.error = null;
      _notify();

      final file = File(current.filePath);
      if (!await file.exists()) {
        current.status = UploadStatus.failed;
        current.error = '本地文件不存在';
        current.retryable = false;
        _notify();
        _isProcessing = false;
        processNext();
        return;
      }

      final length = await file.length();
      if (length <= 0) throw StateError('录音文件为空，已保留在手机上');
      final digest = (await sha256.bind(file.openRead()).first).toString();
      ensureConnection();
      final identity = _okData(
          await apiClient.dio.get('/api/pairing/check', options: scoped()));
      ensureConnection();
      final serverId = identity['server_id'];
      if (serverId is! String ||
          !RegExp(r'^[a-f0-9]{16}$').hasMatch(serverId)) {
        throw StateError('请先更新电脑端，以校验录音是否完整保存');
      }
      if (current.serverId != null && current.serverId != serverId) {
        throw StateError('这段录音属于另一台电脑；请连回原电脑，或点击“指定课程”转到当前电脑');
      }
      if (current.recordingId != null) {
        try {
          _okData(await apiClient.dio.get(
              '/api/recordings/${current.recordingId}',
              options: scoped()));
        } on DioException catch (e) {
          if (e.response?.statusCode != 404) rethrow;
          ensureConnection();
          // A lost/rebuilt DB is not a permanent transport failure. Explicit
          // course selection resets both IDs using the current computer's list.
          throw StateError('电脑上的原录音记录已失效，请点击“指定课程”重新登记');
        }
        ensureConnection();
      }
      current.serverId = serverId;
      if (current.recordingId == null) {
        // Course IDs are also scoped to a computer; never silently reuse one
        // selected from a previous computer's offline course cache.
        try {
          _okData(await apiClient.dio
              .get('/api/courses/${current.courseId}', options: scoped()));
        } on DioException catch (e) {
          if (e.response?.statusCode != 404) rethrow;
          throw StateError('当前电脑没有这门课程，请点击“指定课程”重新选择');
        }
        ensureConnection();
        await _saveNow();
        ensureConnection();
        final created = _okData(await apiClient.dio
            .post('/api/recordings', options: scoped(), data: {
          'course_id': current.courseId,
          'codec': file.path.toLowerCase().endsWith('.wav') ? 'wav' : 'm4a',
          'size_bytes': length,
          'duration_ms': current.durationMs,
        }));
        current.recordingId = created['id'] as String;
        await _saveNow();
        ensureConnection();
      }
      final id = current.recordingId!;
      Future<bool> verified() async {
        final receipt = _okData(await apiClient.dio.get(
            '/api/recordings/$id/receipt',
            queryParameters: {'sha256': digest, 'size_bytes': length},
            options: scoped()));
        ensureConnection();
        if (receipt['recording_id'] != id ||
            receipt['server_id'] != serverId ||
            receipt['sha256'] != digest ||
            receipt['size_bytes'] != length ||
            receipt['verified'] is! bool) {
          throw StateError('电脑未返回有效的录音校验结果，请更新电脑端后重试');
        }
        return receipt['verified'] == true;
      }

      if (!await verified()) {
        _okData(await apiClient.dio.post('/api/recordings/$id/upload-file',
            data: FormData.fromMap({
              'duration_ms': current.durationMs,
              'file': await MultipartFile.fromFile(file.path,
                  filename: file.uri.pathSegments.last)
            }),
            options: scoped()..contentType = 'multipart/form-data',
            onSendProgress: (sent, total) {
          if (total > 0) {
            current.progress = ((sent / total) * 100).toInt();
            _notify();
          }
        }));
        ensureConnection();
      }
      if (!await verified()) {
        throw StateError('电脑未确认保存完整录音，手机文件已保留');
      }
      if (!await file.exists() ||
          await file.length() != length ||
          (await sha256.bind(file.openRead()).first).toString() != digest) {
        throw StateError('手机录音在上传期间发生变化，未执行删除');
      }
      ensureConnection();
      await file.delete();
      if (await file.exists()) {
        throw StateError('电脑已保存，但手机录音删除失败，请重试');
      }
      current.status = UploadStatus.completed;
      current.progress = 100;
      current.error = null;
    } catch (e) {
      current.status = UploadStatus.failed;
      current.attempts++;
      if (e is DioException) {
        final status = e.response?.statusCode;
        current.retryable = status == null ||
            status >= 500 ||
            [401, 403, 408, 429].contains(status);
        final body = e.response?.data;
        final reason = body is Map
            ? '${body['message'] ?? e.message}'
            : e.message ?? e.type.name;
        current.error =
            '${current.retryable ? '等待电脑连接或重新配对' : '上传被电脑拒绝'}：$reason；手机录音仍保留';
      } else {
        current.retryable = false;
        current.error = '$e；手机录音仍保留';
      }
    } finally {
      _notify();
      _isProcessing = false;
      _scheduleRetry();
      processNext();
    }
  }

  void retry(String id) {
    final item =
        _items.firstWhere((i) => i.id == id, orElse: () => throw Exception());
    if (item.status != UploadStatus.pending &&
        item.status != UploadStatus.failed) return;
    item.status = UploadStatus.pending;
    item.error = null;
    item.progress = 0;
    item.retryable = true;
    _notify();
    processNext();
  }

  void remove(String id) {
    _items.removeWhere((i) =>
        i.id == id &&
        i.status != UploadStatus.uploading &&
        i.status != UploadStatus.deleting &&
        i.status != UploadStatus.deleted);
    _notify();
  }

  bool canDeleteLocalRecording(String id) =>
      !_disposed &&
      !_deletingIds.contains(id) &&
      _items.any((item) =>
          item.id == id &&
          (item.status == UploadStatus.pending ||
              item.status == UploadStatus.failed ||
              item.status == UploadStatus.deleting));

  bool isDeletingLocalRecording(String id) => _deletingIds.contains(id);

  Future<void> deleteLocalRecording(String id) async {
    // Reserve synchronously: neither processNext nor a delayed pairing result
    // may pick up this file once the user has confirmed deletion.
    if (!canDeleteLocalRecording(id)) {
      throw StateError('这段录音正在上传、已经同步或正在删除，请稍后查看');
    }
    final item = _items.firstWhere((item) => item.id == id);
    item.status = UploadStatus.deleting;
    item.retryable = false;
    item.error = null;
    _deletingIds.add(id);
    if (!_disposed) _streamController.add(List.unmodifiable(_items));
    try {
      // Persist intent before deleting. A restart must never resume its upload.
      await _persistQueue(checked: true);
      await _deleteLocalFile(item.filePath);
      item.status = UploadStatus.deleted;
      item.progress = 0;
      await _persistQueue(checked: true);
    } catch (e) {
      item.error = item.status == UploadStatus.deleted
          ? '手机录音已删除，但同步记录保存失败；请重新打开应用检查'
          : '删除未完成，已停止同步，请重试删除手机录音：$e';
      rethrow;
    } finally {
      _deletingIds.remove(id);
      _notify();
      unawaited(processNext());
    }
  }
}
