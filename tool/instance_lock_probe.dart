// Test-only child process for verifying OS lock ownership and crash recovery.
import 'dart:io';

import 'package:portlink/platform/single_instance_guard.dart';

Future<void> main(List<String> arguments) async {
  try {
    final guard = await SingleInstanceGuard.acquire(arguments.single);
    stdout.writeln('acquired');
    await stdin.first;
    await guard.release();
  } on InstanceAlreadyRunning {
    stdout.writeln('occupied');
    exitCode = 23;
  }
}
