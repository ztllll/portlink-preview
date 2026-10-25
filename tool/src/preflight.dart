import 'dart:convert';
import 'dart:io';

enum CheckLevel { pass, warning, blocked }

final class BuildCheck {
  const BuildCheck(this.id, this.level, this.message);
  final String id, message;
  final CheckLevel level;
  Map<String, Object> toJson() => {
    'id': id,
    'level': level.name,
    'message': message,
  };
}

final class ProbeResult {
  const ProbeResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

typedef CommandProbe = Future<ProbeResult> Function(
  String executable,
  List<String> args,
);

/// Read-only diagnosis: never installs tools, invokes Flutter, changes developer
/// settings, sends traffic to 3080 or terminates the existing port owner.
class BuildPreflight {
  BuildPreflight({
    required this.host,
    required this.environment,
    required this.run,
    required this.fileExists,
    required this.directoryExists,
    required this.readFile,
    required this.portAvailable,
    required this.projectRoot,
    required this.flutterRoot,
  });
  final String host, projectRoot;
  final String? flutterRoot;
  final Map<String, String> environment;
  final CommandProbe run;
  final bool Function(String) fileExists, directoryExists;
  final String Function(String) readFile;
  final Future<bool> Function() portAvailable;

  Future<List<BuildCheck>> inspect(String target) async {
    if (!['macos', 'windows', 'android'].contains(target)) {
      throw ArgumentError('Unknown target');
    }
    final checks = <BuildCheck>[];
    final root = flutterRoot;
    if (root == null ||
        (!fileExists('$root/bin/flutter') &&
            !fileExists('$root/bin/flutter.bat'))) {
      checks.add(
        const BuildCheck(
          'flutter',
          CheckLevel.blocked,
          '未找到Flutter SDK；设置FLUTTER_ROOT或将flutter加入PATH。',
        ),
      );
    } else {
      final versionPath = '$root/bin/cache/flutter.version.json';
      if (!fileExists(versionPath)) {
        checks.add(
          const BuildCheck(
            'flutter',
            CheckLevel.warning,
            'SDK存在但无版本缓存；需核验Flutter3.47+与Dart3.13+。',
          ),
        );
      } else {
        try {
          final data =
              jsonDecode(readFile(versionPath)) as Map<String, dynamic>;
          final flutter =
              (data['flutterVersion'] ?? data['frameworkVersion'] ?? '')
                  .toString();
          final dart = (data['dartSdkVersion'] ?? '').toString();
          final valid = _atLeast(flutter, 3, 47) && _atLeast(dart, 3, 13);
          checks.add(
            BuildCheck(
              'flutter',
              valid ? CheckLevel.pass : CheckLevel.blocked,
              'Flutter $flutter / Dart $dart；最低Flutter3.47、Dart3.13。',
            ),
          );
          if (data['repositoryUrl'] == 'unknown source' ||
              flutter.contains('pre')) {
            checks.add(
              const BuildCheck(
                'sdk-provenance',
                CheckLevel.warning,
                '本地或预发布SDK元数据，不能作为官方正式发行校验。',
              ),
            );
          }
        } catch (_) {
          checks.add(
            const BuildCheck(
              'flutter',
              CheckLevel.blocked,
              'SDK版本缓存无效，不能确定兼容性。',
            ),
          );
        }
      }
    }
    checks.add(
      BuildCheck(
        'project',
        fileExists('$projectRoot/pubspec.yaml') &&
                fileExists('$projectRoot/pubspec.lock')
            ? CheckLevel.pass
            : CheckLevel.blocked,
        '项目清单与锁文件必须同时存在。',
      ),
    );
    if (target == 'macos') {
      if (host != 'macos') {
        checks.add(
          const BuildCheck(
            'host',
            CheckLevel.blocked,
            'Mac原生构建需要macOS和完整Xcode。',
          ),
        );
      } else {
        final xcode = await run('/usr/bin/xcodebuild', ['-version']);
        final valid = xcode.exitCode == 0 && xcode.output.contains('Xcode ');
        checks.add(
          BuildCheck(
            'xcode',
            valid ? CheckLevel.pass : CheckLevel.blocked,
            valid
                ? '完整Xcode可执行；仍需许可证和首次组件就绪。'
                : '缺少可用完整Xcode；仅Command Line Tools不足以构建Flutter Mac应用。',
          ),
        );
        final project = '$projectRoot/macos/Runner.xcodeproj/project.pbxproj';
        final spm =
            fileExists(project) &&
            readFile(project).contains('FlutterGeneratedPluginSwiftPackage');
        if (spm) {
          checks.add(
            const BuildCheck(
              'plugins',
              CheckLevel.pass,
              '工程包含Flutter Swift Package集成。',
            ),
          );
        } else {
          final pod = await run('pod', ['--version']);
          checks.add(
            BuildCheck(
              'plugins',
              pod.exitCode == 0 ? CheckLevel.pass : CheckLevel.blocked,
              pod.exitCode == 0 ? 'CocoaPods可用，仍需实际解析原生插件。' : '工程未集成Flutter Swift Package且没有CocoaPods；须安装CocoaPods或完成SPM迁移。',
            ),
          );
        }
        checks.add(
          const BuildCheck(
            'signing',
            CheckLevel.warning,
            '此工具不验证签名/Keychain授权；公开分发仍需Developer ID、公证和实机验收。',
          ),
        );
      }
    } else if (target == 'android') {
      final javaHome = environment['JAVA_HOME'];
      final executable = javaHome == null
          ? 'java'
          : '$javaHome/bin/${host == 'windows' ? 'java.exe' : 'java'}';
      final java = await run(executable, ['-version']);
      final match = RegExp(r'version "(?:1\.)?(\d+)').firstMatch(java.output);
      final major = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
      checks.add(
        BuildCheck(
          'jdk',
          java.exitCode == 0 && major >= 17
              ? CheckLevel.pass
              : CheckLevel.blocked,
          major >= 17 && java.exitCode == 0
              ? '检测到JDK $major（最低17），仍需Gradle兼容验证。'
              : '未找到可用JDK17+；仅java启动器不代表已安装运行时。',
        ),
      );
      final sdk = _androidSdk();
      if (sdk == null) {
        checks.add(
          const BuildCheck(
            'android-sdk',
            CheckLevel.blocked,
            '未设置Android SDK；需ANDROID_HOME/ANDROID_SDK_ROOT或项目sdk.dir。',
          ),
        );
      } else {
        final valid =
            fileExists('$sdk/platforms/android-36/android.jar') &&
            directoryExists('$sdk/build-tools');
        checks.add(
          BuildCheck(
            'android-sdk',
            valid ? CheckLevel.pass : CheckLevel.blocked,
            valid
                ? 'Android36平台和build-tools目录存在；版本/许可证仍需实际验证。'
                : '缺少Android36平台或build-tools；platform-tools/adb不能替代完整编译SDK。',
          ),
        );
        final tag = host == 'macos'
            ? 'darwin-x86_64'
            : host == 'windows'
            ? 'windows-x86_64'
            : 'linux-x86_64';
        final suffix = host == 'windows' ? '.exe' : '';
        final bin = '$sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/$tag/bin';
        final ndk =
            directoryExists('$sdk/ndk/28.2.13676358') &&
            fileExists('$bin/clang$suffix') &&
            fileExists('$bin/llvm-ar$suffix') &&
            fileExists('$bin/ld.lld$suffix');
        checks.add(
          BuildCheck(
            'android-ndk',
            ndk ? CheckLevel.pass : CheckLevel.blocked,
            ndk
                ? '默认NDK28.2.13676358与clang/ar/ld工具存在。'
                : '缺少NDK28.2.13676358或clang/ar/ld，原生Dart资产需要完整编译工具链。',
          ),
        );
        final managerName = host == 'windows' ? 'sdkmanager.bat' : 'sdkmanager';
        final manager =
            fileExists('$sdk/cmdline-tools/latest/bin/$managerName') ||
            fileExists('$sdk/tools/bin/$managerName');
        checks.add(
          BuildCheck(
            'android-manager',
            manager ? CheckLevel.pass : CheckLevel.warning,
            manager
                ? 'sdkmanager可执行文件存在。'
                : '未找到sdkmanager；如SDK采用版本号目录，请显式核验组件与许可证。',
          ),
        );
        final cmakeName = host == 'windows' ? 'cmake.exe' : 'cmake';
        final cmake = fileExists('$sdk/cmake/3.22.1/bin/$cmakeName');
        checks.add(
          BuildCheck(
            'android-cmake',
            cmake ? CheckLevel.pass : CheckLevel.blocked,
            cmake
                ? '项目CI固定的Android CMake3.22.1存在。'
                : '缺少Android CMake3.22.1，请通过sdkmanager安装并核验。',
          ),
        );
        checks.add(
          BuildCheck(
            'android-licenses',
            directoryExists('$sdk/licenses')
                ? CheckLevel.pass
                : CheckLevel.warning,
            'SDK许可证需由用户或获授权CI接受；此工具不会自动接受条款。',
          ),
        );
      }
      checks.add(
        const BuildCheck(
          'device',
          CheckLevel.warning,
          '原生编译后仍须真机验证通知、切浏览器和停止；此工具不连接设备。',
        ),
      );
    } else {
      if (host != 'windows') {
        checks.add(
          const BuildCheck(
            'host',
            CheckLevel.blocked,
            'Windows应用必须在Windows主机构建，Mac不能直接产出EXE。',
          ),
        );
      } else {
        final programFiles =
            environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
        final vswhere =
            '$programFiles/Microsoft Visual Studio/Installer/vswhere.exe';
        final vs = await run(vswhere, [
          '-latest',
          '-products',
          '*',
          '-requires',
          'Microsoft.VisualStudio.Workload.NativeDesktop',
          'Microsoft.VisualStudio.Component.VC.ATL',
          '-property',
          'installationPath',
        ]);
        final valid = vs.exitCode == 0 && vs.output.trim().isNotEmpty;
        checks.add(
          BuildCheck(
            'visual-studio',
            valid ? CheckLevel.pass : CheckLevel.blocked,
            valid
                ? '检测到Visual Studio C++桌面与ATL组件。'
                : '缺少Visual Studio C++桌面/ATL组件，或无法通过vswhere核实。',
          ),
        );
      }
      checks.add(
        const BuildCheck(
          'windows-validation',
          CheckLevel.warning,
          'Windows凭据、托盘、文件锁、原子替换与JNI依赖必须在Windows验证。',
        ),
      );
    }
    final available = await portAvailable();
    checks.add(
      BuildCheck(
        'port-3080',
        available ? CheckLevel.pass : CheckLevel.warning,
        available
            ? '127.0.0.1:3080当前空闲，检查后状态可能变化。'
            : '127.0.0.1:3080已占用；不发送流量或停止占用者，冲突不阻止编译但阻止正式转发。',
      ),
    );
    return checks;
  }

  String? _androidSdk() {
    for (final name in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final value = environment[name];
      if (value != null && value.isNotEmpty) return value;
    }
    final properties = '$projectRoot/android/local.properties';
    if (fileExists(properties)) {
      for (final line in readFile(properties).split('\n')) {
        if (line.startsWith('sdk.dir=')) {
          return line
              .substring(8)
              .trim()
              .replaceAll(r'\:', ':')
              .replaceAll(r'\\', r'\');
        }
      }
    }
    return null;
  }

  static bool _atLeast(String version, int major, int minor) {
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(version);
    if (match == null) return false;
    final a = int.parse(match.group(1)!);
    final b = int.parse(match.group(2)!);
    return a > major || a == major && b >= minor;
  }
}

Future<ProbeResult> realCommandProbe(
  String executable,
  List<String> arguments,
) async {
  Process? process;
  try {
    process = await Process.start(
      executable,
      arguments,
      runInShell: Platform.isWindows,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    return ProbeResult(code, '${await output}\n${await errors}');
  } catch (_) {
    process?.kill();
    return const ProbeResult(-1, '');
  }
}

Future<bool> loopback3080Available() async {
  try {
    final listener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      3080,
      shared: false,
    );
    await listener.close();
    return true;
  } on SocketException {
    return false;
  }
}
