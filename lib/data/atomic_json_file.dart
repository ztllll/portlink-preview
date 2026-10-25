import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Serializes all in-process users of a path, including different repository instances.
/// Temp files are same-directory; flush + rename never exposes partially written JSON.
final class AtomicJsonFile {
  AtomicJsonFile(String path) : file = File(path).absolute;
  final File file;
  static final Map<String, Future<void>> _queues = {};
  static const maxBytes = 1024 * 1024;

  Future<T> locked<T>(Future<T> Function() operation) async {
    final key = file.path;
    final previous = _queues[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[key] = gate.future;
    await previous;
    try {
      return await operation();
    } finally {
      gate.complete();
      if (identical(_queues[key], gate.future)) _queues.remove(key);
    }
  }

  Future<T?> read<T>(
    T Function(Map<String, dynamic>) decode, {
    bool allowBackupRecovery = true,
  }) async {
    Object? primaryError;
    var primaryExists = false;
    try {
      primaryExists = await file.exists();
      if (primaryExists) return decode(await _readMap(file));
    } on Object catch (error) {
      primaryError = error;
    }
    final backup = File('${file.path}.bak');
    // Trust stores fail closed on a corrupt primary: a stale backup could omit
    // a newer pin and turn a changed key into an ordinary first-use prompt.
    if (allowBackupRecovery && await backup.exists()) {
      try {
        return decode(await _readMap(backup));
      } on Object {
        throw const FormatException('配置及备份均无法读取');
      }
    }
    if (primaryError != null ||
        primaryExists ||
        (!allowBackupRecovery && await backup.exists())) {
      throw const FormatException('配置无法读取，请保留文件并从可信备份恢复');
    }
    return null;
  }

  Future<Map<String, dynamic>> _readMap(File source) async {
    if (await source.length() > maxBytes) throw const FormatException('配置文件过大');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in source.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('配置文件过大');
      }
      bytes.add(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map<String, dynamic>) throw const FormatException('配置根节点无效');
    return data;
  }

  Future<void> write(
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) validate,
  ) async {
    validate(data);
    final encoded = jsonEncode(data);
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('配置文件过大');
    }
    await file.parent.create(recursive: true);
    // Never overwrite the last good backup with a corrupt primary.
    if (await file.exists()) {
      Map<String, dynamic>? old;
      try {
        old = await _readMap(file);
        validate(old);
      } on Object {
        old = null;
      }
      if (old != null) {
        await _replace(File('${file.path}.bak'), jsonEncode(old));
      }
    }
    await _replace(file, encoded);
  }

  Future<void> _replace(File target, String encoded) async {
    final nonce = Random.secure().nextInt(0x7fffffff);
    final temporary = File('${target.path}.tmp.$pid.$nonce');
    try {
      await temporary.writeAsString(encoded, flush: true);
      // dart:io rename replaces an existing regular destination on supported
      // native platforms. Never delete the primary first, even on failure.
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
