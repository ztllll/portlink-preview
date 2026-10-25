import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Structural verification only: never starts the application or reads its
/// user profile / Windows Credential Manager. Successful inspection is not an
/// interactive Windows smoke test or proof of Authenticode signing.
final class WindowsBundleInspector {
  WindowsBundleInspector({
    required this.bundle,
    required this.architecture,
    required this.generatedPlugins,
  });
  final Directory bundle;
  final String architecture;
  final String generatedPlugins;
  final errors = <String>[];
  final warnings = <String>[];

  Map<String, Object> inspect() {
    errors.clear();
    warnings.clear();
    if (!{'x64', 'arm64'}.contains(architecture)) {
      throw ArgumentError('Supported architectures: x64, arm64');
    }
    if (!bundle.existsSync()) {
      errors.add('Release bundle directory does not exist');
      return _report(0, []);
    }
    final files = <String, File>{};
    for (final entry in bundle.listSync(recursive: true, followLinks: false)) {
      final name = p
          .relative(entry.path, from: bundle.path)
          .replaceAll(r'\', '/');
      if (entry is Link) {
        errors.add('Symbolic link is not portable: $name');
        continue;
      }
      if (entry is! File) continue;
      final key = name.toLowerCase();
      if (files.containsKey(key)) {
        errors.add('Case-insensitive duplicate path: $name');
      }
      files[key] = entry;
      if (_forbidden(name)) {
        errors.add('Development or sensitive file in bundle: $name');
      }
    }
    final required = <String>[
      'portlink.exe',
      'flutter_windows.dll',
      'data/icudtl.dat',
      'data/app.so',
      'data/flutter_assets/AssetManifest.bin',
      'data/flutter_assets/NativeAssetsManifest.json',
      for (final state in ['idle', 'ready', 'pending', 'failed'])
        'data/flutter_assets/assets/tray/windows_$state.ico',
      for (final plugin in pluginNames(generatedPlugins))
        '${plugin}_plugin.dll',
    ];
    for (final name in required) {
      final file = files[name.toLowerCase()];
      if (file == null || file.lengthSync() == 0) {
        errors.add('Missing or empty runtime file: $name');
      }
    }
    final nativeNames = <String>[];
    final manifestFile = files['data/flutter_assets/nativeassetsmanifest.json'];
    if (manifestFile != null) {
      try {
        if (manifestFile.lengthSync() > 4 * 1024 * 1024) {
          throw const FormatException();
        }
        final manifest = jsonDecode(manifestFile.readAsStringSync());
        final assets = manifest['native-assets']['windows_$architecture'];
        if (assets is! Map ||
            !assets.containsKey('package:cnativeapi/cnativeapi.dart')) {
          throw const FormatException(
            'Missing cnativeapi native asset for architecture',
          );
        }
        for (final entry in assets.entries) {
          final location = entry.value;
          if (location is! List ||
              location.length != 2 ||
              location[0] != 'absolute' ||
              location[1] is! String ||
              !safeRelativePath(location[1] as String)) {
            throw const FormatException(
              'Native asset has host/unsafe/nonbundled path',
            );
          }
          // Flutter encodes a bundled Windows DLL as ["absolute", "name.dll"].
          // It is deliberately not a build-machine absolute filename.
          final name = (location[1] as String).replaceAll(r'\', '/');
          if (!name.toLowerCase().endsWith('.dll') ||
              !files.containsKey(name.toLowerCase())) {
            throw FormatException('Missing native asset: $name');
          }
          nativeNames.add(name);
        }
      } on Object catch (error) {
        errors.add('Invalid native asset manifest: $error');
      }
    }
    var binaries = 0;
    for (final entry in files.entries) {
      if (entry.key == 'data/app.so') {
        // Flutter's Windows AOT snapshot is an ELF64 object, not a PE image.
        final problem = aotElfProblem(entry.value, architecture);
        if (problem != null) {
          errors.add('Invalid AOT snapshot: ${entry.key}: $problem');
        }
        continue;
      }
      if (!entry.key.endsWith('.dll') && !entry.key.endsWith('.exe')) {
        continue;
      }
      binaries++;
      try {
        final binary = PeImage.fromFile(entry.value);
        if (binary.architecture != architecture) {
          errors.add(
            'Wrong PE architecture: ${entry.key} is ${binary.architecture}',
          );
        }
        for (final dependency in binary.imports) {
          final name = dependency.name.toLowerCase();
          if (files.containsKey(name) || systemDll(name)) continue;
          if (dependency.delayed &&
              name == 'jvm.dll' &&
              entry.key == 'dartjni.dll') {
            warnings.add(
              'dartjni.dll delay-loads jvm.dll; JVM features are not used by PortLink. '
              'Do not bundle a developer JDK. Verify normal startup on a clean Windows host.',
            );
          } else {
            errors.add('Unbundled DLL dependency: ${entry.key} -> $name');
          }
        }
      } on Object catch (error) {
        errors.add('Invalid PE binary: ${entry.key}: $error');
      }
    }
    return _report(binaries, nativeNames);
  }

  Map<String, Object> _report(int binaries, List<String> natives) => {
    'schemaVersion': 1,
    'kind': 'windows-bundle-structure',
    'architecture': architecture,
    'valid': errors.isEmpty,
    'peBinaryCount': binaries,
    'nativeAssets': natives,
    'errors': List<String>.of(errors),
    'warnings': List<String>.of(warnings),
    'runtimeSmokeTested': false,
    'authenticodeVerified': false,
  };

  /// Returns null when [file] is a little-endian ELF64 object whose machine
  /// matches [architecture]; otherwise a description of the problem.
  static String? aotElfProblem(File file, String architecture) {
    final header = Uint8List(20);
    final handle = file.openSync();
    try {
      if (handle.readIntoSync(header) < header.length) return 'Truncated ELF';
    } finally {
      handle.closeSync();
    }
    if (header[0] != 0x7f ||
        header[1] != 0x45 ||
        header[2] != 0x4c ||
        header[3] != 0x46) {
      return 'Missing ELF magic';
    }
    if (header[4] != 2 || header[5] != 1) {
      return 'Expected little-endian ELF64';
    }
    final machine = ByteData.sublistView(header).getUint16(18, Endian.little);
    final actual = switch (machine) {
      0x3e => 'x64',
      0xb7 => 'arm64',
      _ => 'unsupported',
    };
    if (actual != architecture) {
      return 'ELF machine is $actual, expected $architecture';
    }
    return null;
  }

  static List<String> pluginNames(String cmake) {
    final match = RegExp(
      r'list\s*\(APPEND\s+FLUTTER_PLUGIN_LIST\s+([\s\S]*?)\)',
    ).firstMatch(cmake);
    if (match == null) {
      throw const FormatException('Missing generated plugin list');
    }
    return match
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((name) => name.isNotEmpty)
        .map((name) {
          if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name)) {
            throw const FormatException('Invalid plugin name');
          }
          return name;
        })
        .toList();
  }

  static bool safeRelativePath(String value) {
    if (value.isEmpty ||
        value.contains(':') ||
        value.startsWith('/') ||
        value.startsWith(r'\') ||
        value.contains(RegExp(r'[\x00-\x1f]'))) {
      return false;
    }
    return value
        .replaceAll(r'\', '/')
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.endsWith('.') &&
              !part.endsWith(' '),
        );
  }

  static bool _forbidden(String path) {
    final parts = path.toLowerCase().split('/');
    return parts.any(
      (part) =>
          {
            '.git',
            '.dart_tool',
            '.env',
            'profiles.json',
            'passwords.json',
            'host_trust.json',
            'kernel_blob.bin',
          }.contains(part) ||
          part.endsWith('.pem') ||
          part.endsWith('.key') ||
          part.endsWith('.bak'),
    );
  }

  /// OS components only. VC runtime is intentionally NOT on this list: the
  /// portable build ships app-local redistributable DLLs and checks their imports.
  static bool systemDll(String name) =>
      name.startsWith('api-ms-win-') ||
      name.startsWith('ext-ms-win-') ||
      const {
        'kernel32.dll',
        'kernelbase.dll',
        'ntdll.dll',
        'user32.dll',
        'gdi32.dll',
        'gdi32full.dll',
        'advapi32.dll',
        'shell32.dll',
        'ole32.dll',
        'oleaut32.dll',
        'combase.dll',
        'comctl32.dll',
        'comdlg32.dll',
        'shlwapi.dll',
        'shcore.dll',
        'dwmapi.dll',
        'uxtheme.dll',
        'imm32.dll',
        'version.dll',
        'winmm.dll',
        'winspool.drv',
        'ws2_32.dll',
        'mswsock.dll',
        'winhttp.dll',
        'wininet.dll',
        'dnsapi.dll',
        'iphlpapi.dll',
        'crypt32.dll',
        'cryptbase.dll',
        'bcrypt.dll',
        'bcryptprimitives.dll',
        'ncrypt.dll',
        'secur32.dll',
        'sspicli.dll',
        'userenv.dll',
        'profapi.dll',
        'rpcrt4.dll',
        'psapi.dll',
        'powrprof.dll',
        'setupapi.dll',
        'cfgmgr32.dll',
        'hid.dll',
        'wintrust.dll',
        'normaliz.dll',
        'msimg32.dll',
        'gdiplus.dll',
        'dwrite.dll',
        'd2d1.dll',
        'd3d11.dll',
        'd3d12.dll',
        'dxgi.dll',
        'dxguid.dll',
        'dcomp.dll',
        'dxcore.dll',
        'opengl32.dll',
        'glu32.dll',
        'd3dcompiler_47.dll',
        'propsys.dll',
        'wtsapi32.dll',
        'wldap32.dll',
        'avrt.dll',
        'dinput8.dll',
        'win32u.dll',
        'ucrtbase.dll',
        'msvcrt.dll',
        'usp10.dll',
        'urlmon.dll',
        // Imported by flutter_windows.dll; Windows-shipped, never app-local.
        'uiautomationcore.dll',
        'oleacc.dll',
        'd3d9.dll',
        'dbghelp.dll',
      }.contains(name);
}

final class PeImport {
  const PeImport(this.name, {this.delayed = false});
  final String name;
  final bool delayed;
}

/// Minimal bounds-checked PE import reader. No shell/dumpbin needed to catch a
/// package that accidentally omitted a plugin, runtime, or native asset DLL.
final class PeImage {
  PeImage(this.architecture, this.imports);
  final String architecture;
  final List<PeImport> imports;
  static PeImage fromFile(File file) {
    if (file.lengthSync() > 512 * 1024 * 1024) {
      throw const FormatException('PE too large');
    }
    return parse(file.readAsBytesSync());
  }

  static PeImage parse(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    void need(int offset, int count) {
      if (offset < 0 || count < 0 || offset + count > bytes.length) {
        throw const FormatException('Truncated PE');
      }
    }

    int u16(int at) {
      need(at, 2);
      return view.getUint16(at, Endian.little);
    }

    int u32(int at) {
      need(at, 4);
      return view.getUint32(at, Endian.little);
    }

    if (u16(0) != 0x5a4d) throw const FormatException('Missing MZ header');
    final pe = u32(0x3c);
    if (u32(pe) != 0x4550) throw const FormatException('Missing PE signature');
    final architecture = switch (u16(pe + 4)) {
      0x8664 => 'x64',
      0xaa64 => 'arm64',
      _ => 'unsupported',
    };
    final sectionCount = u16(pe + 6);
    if (sectionCount > 96) throw const FormatException('Excessive PE sections');
    final optionalSize = u16(pe + 20);
    final optional = pe + 24;
    need(optional, optionalSize);
    if (u16(optional) != 0x20b || optionalSize < 112 + 14 * 8) {
      throw const FormatException('Expected PE32+ executable');
    }
    final directoryCount = u32(optional + 108);
    final sections = optional + optionalSize;
    need(sections, sectionCount * 40);
    int rva(int address) {
      for (var i = 0; i < sectionCount; i++) {
        final section = sections + i * 40;
        final start = u32(section + 12), rawSize = u32(section + 16);
        if (address >= start && address - start < rawSize) {
          final offset = u32(section + 20) + address - start;
          need(offset, 1);
          return offset;
        }
      }
      if (address < u32(optional + 60)) {
        need(address, 1);
        return address;
      }
      throw const FormatException('Unmapped PE address');
    }

    String dllName(int address) {
      final start = rva(address);
      var end = start;
      while (end < bytes.length && end - start < 260 && bytes[end] != 0) {
        end++;
      }
      if (end >= bytes.length || end - start >= 260) {
        throw const FormatException('Unterminated DLL name');
      }
      final name = ascii.decode(bytes.sublist(start, end));
      if (!RegExp(r'^[a-zA-Z0-9_.+-]+$').hasMatch(name)) {
        throw const FormatException('Unsafe DLL import');
      }
      return name;
    }

    final imports = <PeImport>[];
    void table(
      int index,
      int descriptorSize,
      int nameOffset, {
      bool delayed = false,
    }) {
      if (directoryCount <= index) return;
      final address = u32(optional + 112 + index * 8);
      final size = u32(optional + 116 + index * 8);
      if (address == 0 || size == 0) return;
      final start = rva(address);
      need(start, size);
      for (
        var offset = 0;
        offset + descriptorSize <= size && offset < 65536;
        offset += descriptorSize
      ) {
        final descriptor = start + offset;
        final name = u32(descriptor + nameOffset);
        if (name == 0) return;
        if (delayed && (u32(descriptor) & 1) == 0) {
          throw const FormatException('Unsupported VA-based delay imports');
        }
        imports.add(PeImport(dllName(name), delayed: delayed));
      }
      throw const FormatException('Unterminated import table');
    }

    table(1, 20, 12);
    table(13, 32, 4, delayed: true);
    return PeImage(architecture, imports);
  }
}
