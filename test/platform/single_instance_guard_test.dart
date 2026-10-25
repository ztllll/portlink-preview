import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/platform/single_instance_guard.dart';

String dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    for (final suffix in [
      'dart-sdk/bin/dart',
      'dart-sdk/bin/dart.exe',
      'dart',
      'dart.exe',
    ]) {
      final candidate = File('${directory.path}/$suffix');
      if (candidate.existsSync()) return candidate.path;
    }
    directory = directory.parent;
  }
  throw StateError('Dart executable required for cross-process lock test');
}

void main() {
  late Directory directory;
  late String lockPath;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('portlink-instance-');
    lockPath = '${directory.path}/instance.lock';
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('same isolate refuses duplicate, release is idempotent and stale file is safe', () async {
    final guard = await SingleInstanceGuard.acquire(lockPath);
    await expectLater(
      SingleInstanceGuard.acquire(lockPath),
      throwsA(isA<InstanceAlreadyRunning>()),
    );
    await guard.release();
    await guard.release();
    expect(await File(lockPath).exists(), isTrue);
    final replacement = await SingleInstanceGuard.acquire(lockPath);
    await replacement.release();
  });

  test('separate process cannot take an owned OS lock', () async {
    final guard = await SingleInstanceGuard.acquire(lockPath);
    try {
      final child = await Process.run(dartExecutable(), [
        'tool/instance_lock_probe.dart',
        lockPath,
      ]);
      expect(child.exitCode, 23, reason: child.stderr.toString());
      expect(child.stdout.toString().trim(), 'occupied');
    } finally {
      await guard.release();
    }
  });

  test('process termination releases lock without deleting its file', () async {
    final child = await Process.start(dartExecutable(), [
      'tool/instance_lock_probe.dart',
      lockPath,
    ]);
    final errors = child.stderr.drain<void>();
    try {
      final firstLine = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      expect(firstLine, 'acquired');
      await expectLater(
        SingleInstanceGuard.acquire(lockPath),
        throwsA(isA<InstanceAlreadyRunning>()),
      );
    } finally {
      child.kill();
      await child.exitCode;
      await errors;
    }
    final replacement = await SingleInstanceGuard.acquire(lockPath);
    await replacement.release();
  });
}
