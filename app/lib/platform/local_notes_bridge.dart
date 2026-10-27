import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalNotesBridge {
  static const channel = MethodChannel('class_notes/local_notes');
  static final changed = ValueNotifier<int>(0);

  static Future<String?> folder() async =>
      Platform.isAndroid ? channel.invokeMethod<String>('getFolder') : null;

  static Future<Map<String, dynamic>?> folderInfo() =>
      channel.invokeMapMethod<String, dynamic>('getFolderInfo');

  static Future<String> identityHash(String value) async =>
      await channel.invokeMethod<String>('identityHash', {'value': value}) ??
      (throw const FormatException('无法确认连接身份'));

  static Future<String?> pickFolder() async {
    if (!Platform.isAndroid) return null;
    final value = await channel.invokeMethod<String>('pickFolder');
    if (value != null) changed.value++;
    return value;
  }

  static Future<List<Map<String, dynamic>>> list() async {
    final result = await channel.invokeMapMethod<String, dynamic>('listNotes');
    final items = result?['items'];
    if (items is! List) throw const FormatException('手机笔记目录返回了无效列表');
    return items.map((item) => (item as Map).cast<String, dynamic>()).toList();
  }

  static Future<Map<String, dynamic>> install(String path, Uint8List bytes,
          String hash, String? expectedHash, String identity,
          {bool keepBackup = true}) async =>
      await channel.invokeMapMethod<String, dynamic>('installNote', {
        'path': path,
        'bytes': bytes,
        'sha256': hash,
        'expectedHash': expectedHash,
        'identity': identity,
        'keepBackup': keepBackup,
      }) ??
      (throw const FormatException('没有收到手机笔记保存确认'));

  static Future<Map<String, dynamic>> installSelected(
          String path,
          Uint8List bytes,
          String hash,
          String? expectedHash,
          String identity) =>
      install(path, bytes, hash, expectedHash, identity, keepBackup: false);

  static Future<Map<String, dynamic>> export(
          String path, String hash, String identity) async =>
      await channel.invokeMapMethod<String, dynamic>(
          'exportNote', {'path': path, 'sha256': hash, 'identity': identity}) ??
      (throw const FormatException('手机未返回完整笔记内容'));

  static Future<String> read(String id) async =>
      await channel.invokeMethod<String>('readNote', {'id': id}) ?? '';
}

class NoteManifestDiff {
  final int same;
  final List<String> onlyOnPhone;
  final List<String> onlyOnComputer;
  final List<String> different;
  const NoteManifestDiff(
      this.same, this.onlyOnPhone, this.onlyOnComputer, this.different);

  static NoteManifestDiff compare(
      List<Map<String, dynamic>> phone, List<Map<String, dynamic>> computer) {
    final local = {
      for (final item in phone)
        '${item['relative_path']}'.replaceAll('\\', '/'): '${item['sha256']}'
    };
    final remote = {
      for (final item in computer)
        '${item['path']}'.replaceAll('\\', '/'): '${item['sha256']}'
    };
    final phoneOnly =
        local.keys.where((path) => !remote.containsKey(path)).toList()..sort();
    final computerOnly =
        remote.keys.where((path) => !local.containsKey(path)).toList()..sort();
    final changed = local.keys
        .where(
            (path) => remote.containsKey(path) && local[path] != remote[path])
        .toList()
      ..sort();
    return NoteManifestDiff(local.length - phoneOnly.length - changed.length,
        phoneOnly, computerOnly, changed);
  }
}
