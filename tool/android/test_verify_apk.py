import contextlib
import importlib.util
import io
import json
import pathlib
import struct
import sys
import tempfile
import unittest
import warnings
import zipfile
from unittest.mock import patch

SOURCE = pathlib.Path(__file__).with_name('verify_apk.py')
spec = importlib.util.spec_from_file_location('verify_apk', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def elf(abi='arm64-v8a'):
    cls, machine, _ = module.ABI_INFO[abi]
    size, phsize = (52, 32) if cls == 1 else (64, 56)
    data = bytearray(size + phsize)
    data[:7] = b'\x7fELF' + bytes((cls, 1, 1))
    struct.pack_into('<HHI', data, 16, 3, machine, 1)
    if cls == 1:
        struct.pack_into('<I', data, 28, size)
        struct.pack_into('<HHH', data, 40, size, phsize, 1)
        struct.pack_into('<IIIIIIII', data, size, 1, 0, 0, 0, len(data), len(data), 5, 4096)
    else:
        struct.pack_into('<Q', data, 32, size)
        struct.pack_into('<HHH', data, 52, size, phsize, 1)
        struct.pack_into('<IIQQQQQQ', data, size, 1, 5, 0, 0, 0, len(data), len(data), 4096)
    return bytes(data)

class ApkCheckTest(unittest.TestCase):
    def fixture(self, root, drop=None, abi='arm64-v8a', replace=None, extra=None):
        tools = root / 'sdk/build-tools/36.0.0'
        tools.mkdir(parents=True)
        for tool in ('aapt', 'apksigner'):
            (tools / tool).write_text('fixture')
        apk = root / 'preview.apk'
        native = {'native-assets': {module.ABI_INFO[abi][2]: {
            'package:cnativeapi/cnativeapi.dart': ['absolute', 'libcnativeapi.so']}}}
        entries = {'AndroidManifest.xml': b'fixture', 'classes.dex': b'fixture',
                   'assets/flutter_assets/AssetManifest.bin': b'fixture',
                   'assets/flutter_assets/NativeAssetsManifest.json': json.dumps(native).encode(),
                   'lib/' + abi + '/libflutter.so': elf(abi),
                   'lib/' + abi + '/libcnativeapi.so': elf(abi)}
        entries.update(replace or {})
        with zipfile.ZipFile(apk, 'w') as archive:
            for name, value in entries.items():
                if name != drop:
                    archive.writestr(name, value)
            for name, value in extra or []:
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', UserWarning)
                    archive.writestr(name, value)
        return apk, root / 'sdk'

    def inspect(self, apk, sdk, signature=0, package='dev.portlink.portlink', minimum=24, extra_badging=''):
        def probe(args):
            if 'verify' in args:
                return {'exitCode': signature, 'stdout': 'verified', 'stderr': ''}
            return {'exitCode': 0, 'stdout': "package: name='" + package + "' versionCode='1'\nsdkVersion:'" + str(minimum) + "'\n" + extra_badging, 'stderr': ''}
        output = io.StringIO()
        with patch.object(sys, 'argv', ['verify_apk', str(apk), '--sdk-root', str(sdk)]), patch.object(module, 'probe', probe), contextlib.redirect_stdout(output):
            code = module.main()
        return code, json.loads(output.getvalue())

    def test_valid_structure_elf_and_signature_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            code, report = self.inspect(apk, sdk)
            self.assertEqual(code, 0, report)
            self.assertEqual(len(report['elf']), 2)
            self.assertIn('not production signing', report['notice'])

    def test_x86_only_cannot_claim_arm64(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp), abi='x86_64')
            self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_required_entries_missing(self):
        for name in ['classes.dex', 'AndroidManifest.xml', 'assets/flutter_assets/NativeAssetsManifest.json', 'lib/arm64-v8a/libflutter.so', 'lib/arm64-v8a/libcnativeapi.so']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp), drop=name)
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_bad_or_wrong_abi_shared_objects_rejected(self):
        for bad in [b'not-ELF', elf('x86_64'), elf('armeabi-v7a'), b'\x7fELF']:
            with self.subTest(length=len(bad)), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp), replace={'lib/arm64-v8a/libcnativeapi.so': bad})
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_all_native_libraries_checked_not_only_flutter(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp), extra=[('lib/arm64-v8a/libother.so', b'not-ELF')])
            self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_invalid_native_manifests_rejected(self):
        for value in [b'not-json', b'[]', b'{"native-assets":null}', b'{"native-assets":{}}']:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp), replace={'assets/flutter_assets/NativeAssetsManifest.json': value})
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_native_paths_must_be_bundled_leaf_names(self):
        for value in ['/tmp/libnative.so', '../libnative.so', 'nested/libnative.so', 'C:\\dev\\native.so', 'missing.so']:
            manifest = {'native-assets': {'android_arm64': {'package:cnativeapi/cnativeapi.dart': ['absolute', value]}}}
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp), replace={'assets/flutter_assets/NativeAssetsManifest.json': json.dumps(manifest).encode()})
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_duplicate_and_unsafe_entries_rejected(self):
        for name in ['AndroidManifest.xml', '../escape', '/absolute', 'C:/drive', 'bad\\path']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp), extra=[(name, b'fixture')])
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            entry = zipfile.ZipInfo('link'); entry.create_system = 3; entry.external_attr = 0o120777 << 16
            with zipfile.ZipFile(apk, 'a') as archive:
                archive.writestr(entry, '/tmp/test-only')
            self.assertEqual(self.inspect(apk, sdk)[0], 1)

    def test_elf_bounds_type_and_segments_rejected(self):
        variants = []
        for offset, form, value in [(16, '<H', 2), (18, '<H', 62), (32, '<Q', 0xffffffffffffffff), (56, '<H', 0), (64, '<I', 0), (72, '<Q', 50000)]:
            data = bytearray(elf()); struct.pack_into(form, data, offset, value); variants.append(data)
        for data in variants:
            with self.subTest(data=data[:24]):
                with self.assertRaises(ValueError):
                    module.elf_info(data, 'arm64-v8a')

    def test_reports_16k_elf_alignment_without_claiming_device_compatibility(self):
        data = bytearray(elf())
        self.assertFalse(module.elf_info(data, 'arm64-v8a')['elf16KLoadAlignment'])
        struct.pack_into('<Q', data, 64 + 48, 16384)
        self.assertTrue(module.elf_info(data, 'arm64-v8a')['elf16KLoadAlignment'])

    def test_all_supported_elf_headers(self):
        for abi in module.ABI_INFO:
            self.assertEqual(module.elf_info(elf(abi), abi)['abi'], abi)

    def test_invalid_signature_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            self.assertEqual(self.inspect(apk, sdk, signature=1)[0], 1)

    def test_wrong_package_cannot_be_smuggled_in_other_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            self.assertEqual(self.inspect(apk, sdk, package='wrong.package', extra_badging="application-label:'name=\'dev.portlink.portlink\''")[0], 1)

    def test_wrong_minimum_cannot_be_smuggled_in_other_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            self.assertEqual(self.inspect(apk, sdk, minimum=23, extra_badging="application-label:'sdkVersion:\'24\''")[0], 1)

    def test_duplicate_package_or_sdk_badging_lines_rejected(self):
        for extra in ["package: name='dev.portlink.portlink'", "sdkVersion:'24'"]:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                apk, sdk = self.fixture(pathlib.Path(tmp))
                self.assertEqual(self.inspect(apk, sdk, extra_badging=extra)[0], 1)

    def test_windows_signature_uses_java_jar_not_batch_or_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); tools = root / 'tools'; java = root / 'jdk'
            (tools / 'lib').mkdir(parents=True); (java / 'bin').mkdir(parents=True)
            (tools / 'lib/apksigner.jar').write_text('fixture'); (java / 'bin/java.exe').write_text('fixture')
            apk = root / 'preview&fixture|name.apk'
            with patch.object(module.sys, 'platform', 'win32'):
                args = module.signature_command(tools, apk, str(java))
            self.assertEqual(args[-1], str(apk))
            self.assertTrue(args[0].endswith('java.exe'))
            self.assertIn('-jar', args)
            self.assertFalse(any(arg.endswith('.bat') or arg == 'cmd' for arg in args))

    def test_limits_fail_before_entry_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk, sdk = self.fixture(pathlib.Path(tmp))
            with patch.object(module, 'MAX_ENTRY', 2):
                self.assertEqual(self.inspect(apk, sdk)[0], 1)

if __name__ == '__main__':
    unittest.main()
