#!/usr/bin/env python3
"""Read-only debug APK structure/signature verification. Never installs an app.
Requires official build-tools36 aapt/apksigner. Success is not device acceptance.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import struct
import subprocess
import sys
import zipfile

ABI_INFO = {'armeabi-v7a': (1, 40, 'android_arm'), 'arm64-v8a': (2, 183, 'android_arm64'),
            'x86_64': (2, 62, 'android_x64')}
MAX_ENTRY = 256 * 1024 * 1024
MAX_EXPANDED = 2 * 1024 * 1024 * 1024

def probe(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return {'exitCode': result.returncode, 'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired):
        return {'exitCode': -1, 'stdout': '', 'stderr': 'Tool execution failed or timed out'}

def elf_info(data, abi):
    """Bounded ELF header/segment validation, not a dynamic linker simulation."""
    if abi not in ABI_INFO:
        raise ValueError('unsupported ABI directory')
    elf_class, machine, _ = ABI_INFO[abi]
    header_size, program_size = (52, 32) if elf_class == 1 else (64, 56)
    if len(data) < header_size or data[:4] != b'\x7fELF':
        raise ValueError('not an ELF shared object')
    if data[4:7] != bytes((elf_class, 1, 1)):
        raise ValueError('ELF class/endian/version differs from ABI')
    kind, actual_machine, version = struct.unpack_from('<HHI', data, 16)
    if kind != 3 or actual_machine != machine or version != 1:
        raise ValueError('ELF shared-object type or machine mismatch')
    if elf_class == 1:
        program_offset = struct.unpack_from('<I', data, 28)[0]
        ehsize, phsize, count = struct.unpack_from('<HHH', data, 40)
    else:
        program_offset = struct.unpack_from('<Q', data, 32)[0]
        ehsize, phsize, count = struct.unpack_from('<HHH', data, 52)
    if ehsize != header_size or phsize != program_size or not 0 < count <= 4096:
        raise ValueError('invalid ELF header/program table size')
    if program_offset < header_size or program_offset + count * phsize > len(data):
        raise ValueError('ELF program table out of bounds')
    loads = 0
    page16k = True
    for index in range(count):
        offset = program_offset + index * phsize
        if elf_class == 1:
            ptype, start, address, _, size, memory, _, align = struct.unpack_from('<IIIIIIII', data, offset)
        else:
            ptype, _, start, address, _, size, memory, align = struct.unpack_from('<IIQQQQQQ', data, offset)
        if start + size > len(data) or ptype == 1 and size > memory:
            raise ValueError('ELF segment out of bounds')
        if align not in (0, 1) and align & (align - 1):
            raise ValueError('ELF segment alignment is not a power of two')
        if ptype == 1:
            loads += 1
            page16k &= align >= 16384 and start % 16384 == address % 16384
    if loads == 0:
        raise ValueError('ELF has no loadable segment')
    return {'abi': abi, 'class': elf_class, 'machine': actual_machine, 'loadSegments': loads, 'elf16KLoadAlignment': page16k}

def safe_name(name):
    return (bool(name) and not name.startswith('/') and '\\' not in name and ':' not in name
            and not any(ord(c) < 32 for c in name)
            and all(part not in ('', '.', '..') for part in name.rstrip('/').split('/')))

def inspect_archive(apk):
    errors, binaries, abis = [], [], set()
    required = ['AndroidManifest.xml', 'classes.dex', 'assets/flutter_assets/AssetManifest.bin',
                'assets/flutter_assets/NativeAssetsManifest.json']
    try:
        with zipfile.ZipFile(apk) as archive:
            entries = archive.infolist()
            if len(entries) > 100000 or sum(e.file_size for e in entries) > MAX_EXPANDED:
                return {'errors': ['APK extraction/read limits exceeded'], 'architectures': [], 'elf': []}
            names, seen = {}, set()
            for entry in entries:
                name = entry.filename
                if not safe_name(name) or name in seen:
                    errors.append('Unsafe or duplicate APK entry: ' + name)
                seen.add(name)
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    errors.append('APK symlink entry is not allowed: ' + name)
                if entry.file_size > MAX_ENTRY:
                    errors.append('APK entry exceeds read limit: ' + name)
                if not entry.is_dir():
                    names[name] = entry
            if errors:
                return {'errors': errors, 'architectures': [], 'elf': []}
            for name in required:
                if name not in names or names[name].file_size == 0:
                    errors.append('Missing or empty APK runtime file: ' + name)
            # Read each entry under bounded aggregate size, checking its CRC.
            for entry in entries:
                if entry.is_dir():
                    continue
                with archive.open(entry) as stream:
                    while stream.read(1024 * 1024):
                        pass
            for name in names:
                parts = name.split('/')
                if len(parts) != 3 or parts[0] != 'lib' or not parts[2].endswith('.so'):
                    continue
                abi = parts[1]
                abis.add(abi)
                try:
                    binaries.append({'path': name, **elf_info(archive.read(name), abi)})
                except (ValueError, struct.error) as error:
                    errors.append('Invalid native ELF ' + name + ': ' + str(error))
            if 'arm64-v8a' not in abis:
                errors.append('No verified arm64-v8a payload')
            manifest_name = required[-1]
            manifest = None
            if manifest_name in names and names[manifest_name].file_size <= 4 * 1024 * 1024:
                try:
                    manifest = json.loads(archive.read(manifest_name))['native-assets']
                except (ValueError, TypeError, KeyError):
                    errors.append('Invalid NativeAssetsManifest')
            else:
                errors.append('NativeAssetsManifest missing or exceeds limit')
            for abi in sorted(abis):
                if abi not in ABI_INFO:
                    continue
                if 'lib/' + abi + '/libflutter.so' not in names:
                    errors.append('Missing Flutter engine for ABI ' + abi)
                assets = manifest.get(ABI_INFO[abi][2]) if isinstance(manifest, dict) else None
                if not isinstance(assets, dict) or 'package:cnativeapi/cnativeapi.dart' not in assets:
                    errors.append('Missing native cnativeapi manifest for ABI ' + abi)
                    continue
                for key, location in assets.items():
                    if (not isinstance(location, list) or len(location) != 2 or location[0] != 'absolute'
                            or not isinstance(location[1], str) or not safe_name(location[1])
                            or '/' in location[1] or not location[1].endswith('.so')):
                        errors.append('Non-bundled native asset path for ' + str(key))
                    elif 'lib/' + abi + '/' + location[1] not in names:
                        errors.append('Missing declared native asset for ' + abi + ': ' + location[1])
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        errors.append('Unreadable APK archive: ' + type(error).__name__)
    alignment = all(item['elf16KLoadAlignment'] for item in binaries) if binaries else False
    return {'errors': errors, 'architectures': sorted(abis), 'elf': binaries,
            'allELF16KLoadAligned': alignment,
            'warnings': [] if alignment else ['Some ELF LOAD segments lack 16KB alignment; verify page-size compatibility and ZIP alignment on actual APK.']}

def signature_command(tools, apk, java_home=None):
    if sys.platform == 'win32':
        home = java_home or os.environ.get('JAVA_HOME')
        if not home:
            raise ValueError('Explicit JAVA_HOME or --java-home required on Windows')
        executable = pathlib.Path(home).resolve() / 'bin/java.exe'
        jar = tools / 'lib/apksigner.jar'
        if not executable.is_file() or not jar.is_file():
            raise ValueError('Windows signature verification requires java.exe and official apksigner.jar')
        return [str(executable), '-jar', str(jar), 'verify', '--verbose', '--print-certs', str(apk)]
    executable = tools / 'apksigner'
    if not executable.is_file():
        raise ValueError('Official apksigner tool missing')
    return [str(executable), 'verify', '--verbose', '--print-certs', str(apk)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=pathlib.Path)
    parser.add_argument('--sdk-root', required=True, type=pathlib.Path)
    parser.add_argument('--java-home', help='Windows JDK for java.exe -jar signature verification; no batch shell')
    args = parser.parse_args()
    apk = args.apk.resolve()
    tools = args.sdk_root.resolve() / 'build-tools' / '36.0.0'
    if not apk.is_file() or apk.suffix != '.apk':
        parser.error('explicit existing .apk required')
    aapt = tools / ('aapt.exe' if sys.platform == 'win32' else 'aapt')
    if not aapt.is_file():
        parser.error('official build-tools36 aapt required')
    try:
        signing_args = signature_command(tools, apk, args.java_home)
    except ValueError as error:
        parser.error(str(error))
    report = inspect_archive(apk)
    signature = probe(signing_args)
    badging = probe([str(aapt), 'dump', 'badging', str(apk)])
    if signature['exitCode'] != 0 or badging['exitCode'] != 0:
        report['errors'].append('Official signature or package-info tool failed')
    package_lines = [line for line in badging['stdout'].splitlines() if line.startswith('package:')]
    sdk_lines = [line for line in badging['stdout'].splitlines() if line.startswith('sdkVersion:')]
    if len(package_lines) != 1 or not re.match(r"^package: name='dev\.portlink\.portlink'(?:\s|$)", package_lines[0]):
        report['errors'].append('Wrong APK application ID')
    if len(sdk_lines) != 1 or sdk_lines[0] != "sdkVersion:'24'":
        report['errors'].append('Unexpected minimum SDK (expected 24)')
    digest = hashlib.sha256()
    with apk.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    report.update({'structureAndSignatureVerified': not report['errors'], 'sha256': digest.hexdigest(),
                   'bytes': apk.stat().st_size, 'signature': signature, 'packageInfo': badging,
                   'notice': 'APK structure/signature check only; not production signing identity, installed-device or background SSH acceptance.'})
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report['errors'] else 0

if __name__ == '__main__':
    raise SystemExit(main())
