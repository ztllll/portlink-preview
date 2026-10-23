import 'dart:convert';
import 'dart:io';

import 'src/preflight.dart';

String? locateFlutter(Map<String, String> env) {
  final configured = env['FLUTTER_ROOT'];
  if (configured != null && configured.isNotEmpty) return configured;
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 6; depth++) {
    if (File('${directory.path}/bin/flutter').existsSync() ||
        File('${directory.path}/bin/flutter.bat').existsSync()) {
      return directory.path;
    }
    directory = directory.parent;
  }
  for (final entry in (env['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    final candidate = File(
      '$entry/${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
    );
    if (candidate.existsSync()) {
      return File(candidate.resolveSymbolicLinksSync()).parent.parent.path;
    }
  }
  return null;
}

Future<void> main(List<String> arguments) async {
  final json = arguments.contains('--json');
  final targets = arguments.where((arg) => !arg.startsWith('--')).toList();
  final unsupported = arguments.any(
    (arg) => arg.startsWith('--') && arg != '--json',
  );
  if (unsupported ||
      targets.length > 1 ||
      targets.isNotEmpty &&
          !['macos', 'windows', 'android'].contains(targets.single)) {
    stderr.writeln(
      '用法: dart tool/preflight.dart [macos|windows|android] [--json]',
    );
    exitCode = 64;
    return;
  }
  final target = targets.isEmpty
      ? (Platform.isMacOS
            ? 'macos'
            : Platform.isWindows
            ? 'windows'
            : 'android')
      : targets.single;
  final project = File.fromUri(Platform.script).parent.parent.path;
  try {
    final inspector = BuildPreflight(
      host: Platform.operatingSystem,
      environment: Platform.environment,
      run: realCommandProbe,
      fileExists: (p) => File(p).existsSync(),
      directoryExists: (p) => Directory(p).existsSync(),
      readFile: (p) => File(p).readAsStringSync(),
      portAvailable: loopback3080Available,
      projectRoot: project,
      flutterRoot: locateFlutter(Platform.environment),
    );
    final checks = await inspector.inspect(target);
    final blocked = checks.any((c) => c.level == CheckLevel.blocked);
    if (json) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'target': target,
          'host': Platform.operatingSystem,
          'buildPrerequisitesReady': !blocked,
          'checks': checks.map((c) => c.toJson()).toList(),
          'notice': '只读前置检查，不是原生构建或实机验收证明。',
        }),
      );
    } else {
      stdout.writeln('PortLink 构建前检查 · $target');
      for (final check in checks) {
        stdout.writeln('[${check.level.name.toUpperCase()}] ${check.message}');
      }
      stdout.writeln(
        blocked ? '当前缺少必要构建条件；没有执行安装或构建。' : '前置条件未发现阻断；仍需真实构建与实机验证。',
      );
    }
    exitCode = blocked ? 2 : 0;
  } catch (_) {
    stderr.writeln('构建前检查失败，未执行任何安装或构建。');
    exitCode = 1;
  }
}
