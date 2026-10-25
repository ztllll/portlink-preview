import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/windows/bundle_inspector.dart';

const plugins = '''
list(APPEND FLUTTER_PLUGIN_LIST
  flutter_secure_storage_windows
  screen_retriever_windows
  url_launcher_windows
  window_manager
)
list(APPEND FLUTTER_FFI_PLUGIN_LIST jni)
''';

Uint8List pe({
  String architecture = 'x64',
  List<String> imports = const [],
  List<String> delayed = const [],
}) {
  final bytes = Uint8List(4096);
  final view = ByteData.sublistView(bytes);
  void u16(int at, int value) => view.setUint16(at, value, Endian.little);
  void u32(int at, int value) => view.setUint32(at, value, Endian.little);
  u16(0, 0x5a4d);
  u32(0x3c, 0x80);
  u32(0x80, 0x4550);
  u16(0x84, architecture == 'arm64' ? 0xaa64 : 0x8664);
  u16(0x86, 1);
  u16(0x94, 240);
  const optional = 0x98;
  u16(optional, 0x20b);
  u32(optional + 60, 0x200);
  u32(optional + 108, 16);
  const section = optional + 240;
  u32(section + 8, 0xe00);
  u32(section + 12, 0x1000);
  u32(section + 16, 0xe00);
  u32(section + 20, 0x200);
  var nameOffset = 0x800;
  int name(String value) {
    final offset = nameOffset;
    final encoded = ascii.encode(value);
    bytes.setRange(offset, offset + encoded.length, encoded);
    nameOffset += encoded.length + 1;
    return 0x1000 + offset - 0x200;
  }

  if (imports.isNotEmpty) {
    u32(optional + 112 + 8, 0x1000);
    u32(optional + 116 + 8, (imports.length + 1) * 20);
    for (var i = 0; i < imports.length; i++) {
      u32(0x200 + i * 20 + 12, name(imports[i]));
    }
  }
  if (delayed.isNotEmpty) {
    u32(optional + 112 + 13 * 8, 0x1200);
    u32(optional + 116 + 13 * 8, (delayed.length + 1) * 32);
    for (var i = 0; i < delayed.length; i++) {
      u32(0x400 + i * 32, 1);
      u32(0x400 + i * 32 + 4, name(delayed[i]));
    }
  }
  return bytes;
}

Uint8List elf({int machine = 0x3e}) {
  final bytes = Uint8List(64);
  bytes.setRange(0, 6, [0x7f, 0x45, 0x4c, 0x46, 2, 1]);
  ByteData.sublistView(bytes).setUint16(18, machine, Endian.little);
  return bytes;
}

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'portlink-windows-fixture-',
    );
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });
  File file(String name) => File('${directory.path}/$name');
  void put(String name, [List<int> bytes = const [1]]) {
    final output = file(name);
    output.parent.createSync(recursive: true);
    output.writeAsBytesSync(bytes);
  }

  void manifest({String architecture = 'x64', String path = 'cnativeapi.dll'}) {
    put(
      'data/flutter_assets/NativeAssetsManifest.json',
      utf8.encode(
        jsonEncode({
          'format-version': [1, 0, 0],
          'native-assets': {
            'windows_$architecture': {
              'package:cnativeapi/cnativeapi.dart': ['absolute', path],
            },
          },
        }),
      ),
    );
  }

  void valid({String architecture = 'x64'}) {
    for (final name in [
      'portlink.exe',
      'flutter_windows.dll',
      'cnativeapi.dll',
      for (final plugin in WindowsBundleInspector.pluginNames(plugins))
        '${plugin}_plugin.dll',
    ]) {
      put(
        name,
        pe(
          architecture: architecture,
          imports: ['KERNEL32.dll', 'api-ms-win-core-file-l1-1-0.dll'],
        ),
      );
    }
    put('data/app.so', elf(machine: architecture == 'arm64' ? 0xb7 : 0x3e));
    for (final name in [
      'data/icudtl.dat',
      'data/flutter_assets/AssetManifest.bin',
      for (final state in ['idle', 'ready', 'pending', 'failed'])
        'data/flutter_assets/assets/tray/windows_$state.ico',
    ]) {
      put(name);
    }
    manifest(architecture: architecture);
  }

  Map<String, Object> inspect({String architecture = 'x64'}) =>
      WindowsBundleInspector(
        bundle: directory,
        architecture: architecture,
        generatedPlugins: plugins,
      ).inspect();
  List<String> errors(Map<String, Object> report) =>
      report['errors'] as List<String>;

  test('complete x64 bundle verifies without claiming runtime or signing', () {
    valid();
    final report = inspect();
    expect(report['valid'], isTrue, reason: errors(report).join('\n'));
    expect(
      report['peBinaryCount'],
      7,
    ); // AOT app.so is ELF, checked separately.
    expect(report['nativeAssets'], ['cnativeapi.dll']);
    expect(report['runtimeSmokeTested'], isFalse);
    expect(report['authenticodeVerified'], isFalse);
  });
  test(
    'complete ARM64 bundle uses matching PE and native manifest architecture',
    () {
      valid(architecture: 'arm64');
      expect(inspect(architecture: 'arm64')['valid'], isTrue);
      expect(inspect()['valid'], isFalse);
    },
  );
  test('missing plugin is fatal even with executable and engine present', () {
    valid();
    file('window_manager_plugin.dll').deleteSync();
    expect(errors(inspect()), contains(contains('window_manager_plugin.dll')));
  });
  test('all four state icons are required for Windows tray transitions', () {
    valid();
    file('data/flutter_assets/assets/tray/windows_failed.ico').deleteSync();
    expect(inspect()['valid'], isFalse);
  });
  test('native manifest must name packaged cnativeapi DLL', () {
    valid();
    file('cnativeapi.dll').deleteSync();
    expect(errors(inspect()), contains(contains('Missing native asset')));
  });
  test(
    'absolute tester paths and traversal cannot leak into a portable artifact',
    () {
      valid();
      for (final path in [
        'C:/builder/cnativeapi.dll',
        '/tmp/cnativeapi.dll',
        '../cnativeapi.dll',
        r'..\cnativeapi.dll',
        r'\\host\share\file.dll',
      ]) {
        manifest(path: path);
        expect(inspect()['valid'], isFalse, reason: path);
      }
    },
  );
  test('regular and delay import dependencies must be app-local or known Windows system DLLs', () {
    valid();
    put('portlink.exe', pe(imports: ['VCRUNTIME140.dll']));
    expect(errors(inspect()), contains(contains('vcruntime140.dll')));
    put('vcruntime140.dll', pe());
    expect(inspect()['valid'], isTrue);
    put('portlink.exe', pe(delayed: ['missing_delayed.dll']));
    expect(inspect()['valid'], isFalse);
  });
  test('only optional dartjni delay-load jvm is warned not silently bundled from developer JDK', () {
    valid();
    put('dartjni.dll', pe(delayed: ['jvm.dll']));
    final report = inspect();
    expect(report['valid'], isTrue);
    expect(report['warnings'], contains(contains('jvm.dll')));
    put('dartjni.dll', pe(imports: ['jvm.dll']));
    expect(inspect()['valid'], isFalse);
  });
  test('development credentials and debug kernel are rejected', () {
    valid();
    put('data/profiles.json');
    expect(inspect()['valid'], isFalse);
    file('data/profiles.json').deleteSync();
    put('data/flutter_assets/kernel_blob.bin');
    expect(inspect()['valid'], isFalse);
  });
  test('case-insensitive DLL collisions cannot pass Linux or Mac fixture inspection', () {
    valid();
    put('WINDOW_MANAGER_PLUGIN.dll', pe());
    // Case-insensitive macOS volumes alias rather than duplicate this name.
    final aliases = directory
        .listSync()
        .where(
          (e) => e.path.toLowerCase().endsWith('window_manager_plugin.dll'),
        )
        .length;
    if (aliases > 1) expect(inspect()['valid'], isFalse);
  });
  test('malformed PE and wrong architecture are fatal', () {
    valid();
    put('portlink.exe', [0, 1, 2]);
    expect(inspect()['valid'], isFalse);
    put('portlink.exe', pe(architecture: 'arm64'));
    expect(inspect()['valid'], isFalse);
  });
  test(
    'AOT app.so is verified as ELF64 and cannot hide wrong architecture',
    () {
      valid();
      put('data/app.so', elf());
      expect(inspect()['valid'], isTrue);
      put('data/app.so', elf(machine: 0xb7));
      expect(inspect()['valid'], isFalse);
      put('data/app.so', elf(machine: 0x28));
      expect(inspect()['valid'], isFalse);
      put('data/app.so', pe());
      expect(inspect()['valid'], isFalse);
      put('data/app.so', [0x7f, 0x45, 0x4c]);
      expect(inspect()['valid'], isFalse);
    },
  );
  test(
    'Windows-shipped UI Automation and graphics DLLs are system imports',
    () {
      valid();
      put(
        'flutter_windows.dll',
        pe(
          imports: [
            'uiautomationcore.dll',
            'oleacc.dll',
            'd3d9.dll',
            'dbghelp.dll',
          ],
        ),
      );
      expect(inspect()['valid'], isTrue);
    },
  );
  test('native manifest is mandatory even when cnativeapi DLL exists', () {
    valid();
    file('data/flutter_assets/NativeAssetsManifest.json').deleteSync();
    expect(inspect()['valid'], isFalse);
  });
  test('PE bounds checks reject arbitrary truncated and hostile offsets', () {
    for (final data in [Uint8List(0), Uint8List(64), pe().sublist(0, 100)]) {
      expect(() => PeImage.parse(data), throwsFormatException);
    }
    final hostile = pe();
    ByteData.sublistView(hostile).setUint32(0x3c, 0xffffffff, Endian.little);
    expect(() => PeImage.parse(hostile), throwsFormatException);
  });
  test('PE reader preserves ordinary and delayed import distinction', () {
    final image = PeImage.parse(
      pe(imports: ['kernel32.dll'], delayed: ['jvm.dll']),
    );
    expect(image.architecture, 'x64');
    expect(image.imports.map((e) => e.name), ['kernel32.dll', 'jvm.dll']);
    expect(image.imports.map((e) => e.delayed), [false, true]);
  });
  test('plugin list excludes FFI target name and fails closed on malformed generated source', () {
    expect(WindowsBundleInspector.pluginNames(plugins), hasLength(4));
    expect(() => WindowsBundleInspector.pluginNames(''), throwsFormatException);
    expect(
      () => WindowsBundleInspector.pluginNames(
        'list(APPEND FLUTTER_PLUGIN_LIST ../bad)',
      ),
      throwsFormatException,
    );
  });
  test('safe relative paths reject host drives links and Windows normalization escapes', () {
    for (final path in [
      '',
      '.',
      '..',
      'a/../b',
      'C:foo.dll',
      '/root.dll',
      r'\server\share',
      'a./x',
      'a /x',
    ]) {
      expect(
        WindowsBundleInspector.safeRelativePath(path),
        isFalse,
        reason: path,
      );
    }
    expect(WindowsBundleInspector.safeRelativePath('cnativeapi.dll'), isTrue);
  });
}
