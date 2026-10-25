import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/src/preflight.dart';

class Fixture {
  final files = <String, String>{
    '/project/pubspec.yaml': '',
    '/project/pubspec.lock': '',
    '/flutter/bin/flutter': '',
    '/flutter/bin/cache/flutter.version.json': jsonEncode({
      'flutterVersion': '3.47.0',
      'dartSdkVersion': '3.13.5',
      'repositoryUrl': 'https://github.com/flutter/flutter',
    }),
  };
  final directories = <String>{};
  final calls = <String>[];
  final responses = <String, ProbeResult>{};
  final environment = <String, String>{};
  bool available = true;
  String? flutter = '/flutter';
  BuildPreflight make(String host) => BuildPreflight(
    host: host,
    environment: environment,
    run: (exe, args) async {
      calls.add(exe);
      return responses[exe] ?? const ProbeResult(-1, '');
    },
    fileExists: files.containsKey,
    directoryExists: directories.contains,
    readFile: (p) => files[p]!,
    portAvailable: () async => available,
    projectRoot: '/project',
    flutterRoot: flutter,
  );
}

CheckLevel level(List<BuildCheck> checks, String id) =>
    checks.singleWhere((c) => c.id == id).level;
void main() {
  test(
    'missing full Xcode and CocoaPods are explicit separate blockers',
    () async {
      final f = Fixture();
      final checks = await f.make('macos').inspect('macos');
      expect(level(checks, 'xcode'), CheckLevel.blocked);
      expect(level(checks, 'plugins'), CheckLevel.blocked);
      expect(f.calls, ['/usr/bin/xcodebuild', 'pod']);
    },
  );
  test(
    '3080 occupied is runtime warning not build failure or network request',
    () async {
      final f = Fixture()..available = false;
      f.responses['/usr/bin/xcodebuild'] = const ProbeResult(0, 'Xcode 26.0');
      f.responses['pod'] = const ProbeResult(0, '1.16.2');
      final checks = await f.make('macos').inspect('macos');
      expect(checks.any((c) => c.level == CheckLevel.blocked), isFalse);
      expect(level(checks, 'port-3080'), CheckLevel.warning);
    },
  );
  test('SPM-integrated project does not require CocoaPods', () async {
    final f = Fixture();
    f.responses['/usr/bin/xcodebuild'] = const ProbeResult(0, 'Xcode 26.0');
    f.files['/project/macos/Runner.xcodeproj/project.pbxproj'] =
        'FlutterGeneratedPluginSwiftPackage';
    final checks = await f.make('macos').inspect('macos');
    expect(level(checks, 'plugins'), CheckLevel.pass);
    expect(f.calls, ['/usr/bin/xcodebuild']);
  });
  test('adb-only Android directory cannot pass as a complete SDK', () async {
    final f = Fixture();
    f.environment['ANDROID_HOME'] = '/adb';
    f.directories.add('/adb/platform-tools');
    f.responses['java'] = const ProbeResult(0, 'openjdk version "17.0.12"');
    final checks = await f.make('macos').inspect('android');
    expect(level(checks, 'jdk'), CheckLevel.pass);
    expect(level(checks, 'android-sdk'), CheckLevel.blocked);
    expect(level(checks, 'android-ndk'), CheckLevel.blocked);
  });
  test('Android platform and pinned NDK plus JDK17 satisfy file prerequisites', () async {
    final f = Fixture();
    f.environment['JAVA_HOME'] = '/jdk';
    f.environment['ANDROID_HOME'] = '/sdk';
    f.responses['/jdk/bin/java'] = const ProbeResult(
      0,
      'openjdk version "21.0.1"',
    );
    f.files['/sdk/platforms/android-36/android.jar'] = '';
    f.directories.addAll([
      '/sdk/build-tools',
      '/sdk/ndk/28.2.13676358',
      '/sdk/licenses',
    ]);
    for (final binary in ['clang', 'llvm-ar', 'ld.lld']) {
      f.files['/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/$binary'] =
          '';
    }
    f.files['/sdk/cmake/3.22.1/bin/cmake'] = '';
    f.files['/sdk/cmdline-tools/latest/bin/sdkmanager'] = '';
    final checks = await f.make('macos').inspect('android');
    expect(checks.any((c) => c.level == CheckLevel.blocked), isFalse);
  });
  test('Java launcher without runtime fails even if command exists', () async {
    final f = Fixture();
    f.responses['java'] = const ProbeResult(1, 'Unable to locate Java Runtime');
    expect(
      level(await f.make('macos').inspect('android'), 'jdk'),
      CheckLevel.blocked,
    );
  });
  test(
    'Windows target on macOS fails host check without invoking Windows tools',
    () async {
      final f = Fixture();
      final checks = await f.make('macos').inspect('windows');
      expect(level(checks, 'host'), CheckLevel.blocked);
      expect(f.calls, isEmpty);
    },
  );
  test(
    'old SDK and malformed cached versions cannot claim readiness',
    () async {
      final f = Fixture();
      f.files['/flutter/bin/cache/flutter.version.json'] = jsonEncode({
        'flutterVersion': '3.46.0',
        'dartSdkVersion': '3.12.0',
      });
      expect(
        level(await f.make('macos').inspect('macos'), 'flutter'),
        CheckLevel.blocked,
      );
      f.files['/flutter/bin/cache/flutter.version.json'] = 'broken';
      expect(
        level(await f.make('macos').inspect('macos'), 'flutter'),
        CheckLevel.blocked,
      );
    },
  );
  test('local pre-release SDK gets source provenance warning', () async {
    final f = Fixture();
    f.files['/flutter/bin/cache/flutter.version.json'] = jsonEncode({
      'flutterVersion': '3.47.1-0.0.pre-1',
      'dartSdkVersion': '3.13.5',
      'repositoryUrl': 'unknown source',
    });
    expect(
      level(await f.make('macos').inspect('macos'), 'sdk-provenance'),
      CheckLevel.warning,
    );
  });
  test('invalid target rejected before any tools run', () async {
    final f = Fixture();
    await expectLater(f.make('macos').inspect('unknown'), throwsArgumentError);
    expect(f.calls, isEmpty);
  });
}
