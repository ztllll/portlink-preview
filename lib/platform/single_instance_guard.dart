import 'dart:io';

/// A process-lifetime advisory lock, never a PID file or a second TCP listener.
/// Keep the lock file in place: deleting it would let another process lock a new
/// inode while the original process still owns the old one. The OS releases the
/// lock on process death, so a stale file does not prevent the next launch.
final class SingleInstanceGuard {
  SingleInstanceGuard._(this._file, this._key);
  static final Set<String> _held = {};
  final RandomAccessFile _file;
  final String _key;
  bool _released = false;

  static Future<SingleInstanceGuard> acquire(String path) async {
    final file = File(path).absolute;
    final key = file.path;
    // POSIX advisory record locks are per-process, so also serialize callers in
    // our one application isolate. The native lock excludes separate processes.
    if (!_held.add(key)) throw const InstanceAlreadyRunning();
    RandomAccessFile? handle;
    var ownsLock = false;
    try {
      await file.parent.create(recursive: true);
      handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive, 0, 1);
        ownsLock = true;
      } on FileSystemException catch (error) {
        // Only known lock-contention codes mean another instance. Permission or
        // filesystem failures must surface as startup failures, not false claims.
        final code = error.osError?.errorCode;
        if (code == 11 || code == 13 || code == 35 || code == 33) {
          throw const InstanceAlreadyRunning();
        }
        rethrow;
      }
      await handle.truncate(0);
      await handle.writeString('PortLink instance lock\n');
      await handle.flush();
      return SingleInstanceGuard._(handle, key);
    } catch (_) {
      if (ownsLock) {
        try {
          await handle?.unlock(0, 1);
        } catch (_) {}
      }
      await handle?.close();
      _held.remove(key);
      rethrow;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.unlock(0, 1);
    } finally {
      try {
        await _file.close();
      } finally {
        _held.remove(_key);
      }
    }
  }
}

final class InstanceAlreadyRunning implements Exception {
  const InstanceAlreadyRunning();
  @override
  String toString() => '端口连已在运行，请从菜单栏或系统托盘打开原窗口。';
}
