#!/usr/bin/env python3
"""Read-only SDK plan; --install requires explicit --accept-sdk-license.
No default download, no fabricated licenses hash, no automatic yes pipe.
"""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, platform, re, shutil, subprocess, sys, tempfile, urllib.request, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent
REPOSITORY = 'https://dl.google.com/android/repository/repository2-1.xml'
BOOTSTRAP = {'url': 'https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip',
             'sha1': 'c3e06a1959762e89167d1cbaa988605f6f7c1d24', 'bytes': 143250852, 'version': '19.0'}
PACKAGES = ['platform-tools', 'platforms;android-36', 'build-tools;36.0.0', 'ndk;28.2.13676358', 'cmake;3.22.1']

def select_java(explicit: str | None) -> pathlib.Path | None:
    if explicit:
        candidate = pathlib.Path(explicit).resolve()
        return candidate if (candidate / 'bin' / 'java').is_file() else None
    candidates = [os.environ.get('JAVA_HOME'), '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home']
    for candidate in candidates:
        if candidate and (pathlib.Path(candidate) / 'bin' / 'java').is_file(): return pathlib.Path(candidate).resolve()
    return None

def validate_jdk(java: pathlib.Path) -> dict:
    versions = {}
    for tool in ('java', 'javac'):
        if not (java / 'bin' / tool).is_file(): raise ValueError('Full JDK17+ required; missing ' + tool)
    for tool in ('java', 'javac'):
        binary = java / 'bin' / tool
        try:
            result = subprocess.run([str(binary), '-version'], capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError('Cannot execute JDK tool: ' + tool) from error
        text = result.stdout + '\n' + result.stderr
        pattern = r'(?:openjdk|java) version "(?:1\.)?(\d+)' if tool == 'java' else r'javac (?:1\.)?(\d+)'
        match = re.search(pattern, text)
        major = int(match.group(1)) if match else 0
        if result.returncode or major < 17: raise ValueError('Full JDK17+ required; invalid ' + tool + ' version')
        versions[tool] = major
    if versions['java'] != versions['javac']: raise ValueError('JDK java/javac major versions differ')
    return versions

def safe_extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    with zipfile.ZipFile(archive) as z:
        seen = set()
        for entry in z.infolist():
            name = entry.filename
            if '\\' in name or name.startswith('/') or any(part in ('', '.', '..') for part in name.rstrip('/').split('/')):
                raise ValueError('noncanonical SDK bootstrap entry')
            target = (destination / name).resolve()
            if target in seen: raise ValueError('duplicate SDK bootstrap entry')
            seen.add(target)
            if not target.is_relative_to(destination.resolve()): raise ValueError('unsafe archive path')
            if ((entry.external_attr >> 16) & 0o170000) == 0o120000: raise ValueError('unexpected symlink in SDK bootstrap')
        z.extractall(destination)
        for entry in z.infolist():
            mode = (entry.external_attr >> 16) & 0o777
            if mode and not entry.is_dir(): (destination / entry.filename).chmod(mode)

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true', help='Download official CLI and run sdkmanager interactively')
    parser.add_argument('--accept-sdk-license', action='store_true', help='Explicit authorization to review/accept required official SDK license interactively')
    parser.add_argument('--sdk-root', type=pathlib.Path, default=WORKSPACE / '.tools' / 'android-sdk')
    parser.add_argument('--java-home')
    args = parser.parse_args(argv)
    sdk = args.sdk_root.resolve(); java = select_java(args.java_home)
    plan = {'sdkRoot': str(sdk), 'javaHome': str(java) if java else None, 'packages': PACKAGES,
            'bootstrap': BOOTSTRAP, 'repository': REPOSITORY, 'downloadsByDefault': False,
            'note': 'Only --install and --accept-sdk-license permit download/interactive license acceptance. Existing SDK is not deleted; system Java is not modified.'}
    if not args.install:
        print(json.dumps(plan, ensure_ascii=False, indent=2)); return 0
    if not args.accept_sdk_license:
        parser.error('--install requires explicit --accept-sdk-license; no downloads or license acceptance performed')
    if platform.system() != 'Darwin': parser.error('This bootstrap is pinned for macOS; use official SDK tools for your host')
    if java is None: parser.error('JDK17+ required; specify --java-home')
    allowed = (WORKSPACE / '.tools').resolve()
    if not sdk.is_relative_to(allowed): parser.error('SDK destination must stay inside the workspace .tools directory')
    environment = dict(os.environ, JAVA_HOME=str(java), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    environment['PATH'] = str(java / 'bin') + os.pathsep + environment.get('PATH', '')
    versions = validate_jdk(java)
    print(json.dumps({'validatedJdk': versions}), flush=True)
    sdkmanager = sdk / 'cmdline-tools' / BOOTSTRAP['version'] / 'bin' / 'sdkmanager'
    if not sdkmanager.is_file():
        with tempfile.TemporaryDirectory(prefix='portlink-sdk-bootstrap-') as folder:
            staging = pathlib.Path(folder); archive = staging / 'commandlinetools.zip'
            with urllib.request.urlopen(BOOTSTRAP['url'], timeout=60) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
            if archive.stat().st_size != BOOTSTRAP['bytes'] or hashlib.sha1(archive.read_bytes()).hexdigest() != BOOTSTRAP['sha1']:
                raise ValueError('Official SDK bootstrap checksum/size mismatch')
            safe_extract(archive, staging / 'extracted')
            destination = sdkmanager.parents[1]
            if destination.exists(): raise FileExistsError('Incomplete destination exists; inspect it manually, never auto-delete')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(staging / 'extracted' / 'cmdline-tools', destination)
    print('Review official SDK prompts in this terminal. This script never auto-answers yes.', flush=True)
    result = subprocess.run([str(sdkmanager), '--sdk_root=' + str(sdk), *PACKAGES], env=environment)
    if result.returncode: return result.returncode
    print(json.dumps({'sdkRoot': str(sdk), 'installedBySdkmanager': PACKAGES, 'next': 'JAVA_HOME and ANDROID_HOME must be passed explicitly to the build process'}, indent=2))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
