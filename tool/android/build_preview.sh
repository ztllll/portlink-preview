#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
ANDROID_HOME="${ANDROID_HOME:-$ROOT/../.tools/android-sdk}"
FLUTTER="${FLUTTER_BIN:-$ROOT/../.tools/flutter/bin/flutter}"
DART="${DART_BIN:-$ROOT/../.tools/flutter/bin/cache/dart-sdk/bin/dart}"
[[ -x "$JAVA_HOME/bin/java" && -d "$ANDROID_HOME/platforms/android-36" && -d "$ANDROID_HOME/ndk/28.2.13676358" ]] || { printf "JDK17 and complete SDK36/NDK28.2 required; no download or license acceptance is automatic.\n" >&2; exit 2; }
export JAVA_HOME ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$ROOT/../.tools/gradle-home}"
"$DART" tool/preflight.dart android
"$FLUTTER" pub get
"$FLUTTER" analyze
"$FLUTTER" test --concurrency=1
"$FLUTTER" build apk --debug
SDK_TOOLS="$ANDROID_HOME/build-tools/36.0.0"
APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
"$SDK_TOOLS/apksigner" verify --verbose --print-certs "$APK"
python3 tool/android/verify_apk.py "$APK" --sdk-root "$ANDROID_HOME"
printf "Debug preview only: %s\n" "$APK"
printf "Debug signing is not production release signing, and build success is not device acceptance.\n"
