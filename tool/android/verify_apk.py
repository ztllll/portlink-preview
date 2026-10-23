#!/usr/bin/env python3
"""Read-only validation of a built debug APK; never installs on a device.
Requires official SDK build-tools aapt/apksigner. Structural success != device acceptance.
"""
import argparse, hashlib, json, pathlib, subprocess, sys, zipfile

def probe(args):
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return {'exitCode': r.returncode, 'stdout': r.stdout.strip(), 'stderr': r.stderr.strip()}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=pathlib.Path)
    parser.add_argument('--sdk-root', required=True, type=pathlib.Path)
    args = parser.parse_args()
    apk = args.apk.resolve(); tools = args.sdk_root.resolve() / 'build-tools' / '36.0.0'
    if not apk.is_file() or apk.suffix != '.apk': parser.error('explicit existing .apk required')
    apksigner = tools / ('apksigner.bat' if sys.platform == 'win32' else 'apksigner')
    aapt = tools / ('aapt.exe' if sys.platform == 'win32' else 'aapt')
    if not apksigner.is_file() or not aapt.is_file(): parser.error('official build-tools36 aapt/apksigner required')
    failed = False
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        if z.testzip() is not None: failed = True
        if 'AndroidManifest.xml' not in names or 'classes.dex' not in names: failed = True
        abis = sorted({n.split('/')[1] for n in names if n.startswith('lib/') and n.endswith('.so') and len(n.split('/')) == 3})
        if 'arm64-v8a' not in abis: failed = True
        required = ['assets/flutter_assets/AssetManifest.bin', 'assets/flutter_assets/NativeAssetsManifest.json']
        missing = [n for n in required if n not in names]
        failed |= bool(missing)
    signature = probe([str(apksigner), 'verify', '--verbose', '--print-certs', str(apk)])
    badging = probe([str(aapt), 'dump', 'badging', str(apk)])
    failed |= signature['exitCode'] != 0 or badging['exitCode'] != 0
    failed |= "name='dev.portlink.portlink'" not in badging['stdout']
    failed |= "sdkVersion:'24'" not in badging['stdout']
    report = {'structureAndSignatureVerified': not failed, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
              'bytes': apk.stat().st_size, 'architectures': abis, 'missingFlutterAssets': missing,
              'signature': signature, 'packageInfo': badging,
              'notice': 'Built debug APK only; not production signing, installed-device or background SSH acceptance.'}
    print(json.dumps(report, ensure_ascii=False, indent=2)); return 1 if failed else 0
if __name__ == '__main__': raise SystemExit(main())
