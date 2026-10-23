#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER="${FLUTTER_BIN:-flutter}"
DART="${DART_BIN:-dart}"
"$FLUTTER" pub get
"$DART" format --output=none --set-exit-if-changed lib test
"$FLUTTER" analyze
"$FLUTTER" test --concurrency=1
