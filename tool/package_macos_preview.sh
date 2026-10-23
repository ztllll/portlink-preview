#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" != 2 ]]; then
  printf "Usage: bash tool/package_macos_preview.sh /absolute/PortLink.app /absolute/new-output-dir\n" >&2
  exit 64
fi
APP="$1"
OUT="$2"
[[ "$APP" = /* && "$OUT" = /* && -d "$APP" && "$APP" = *.app ]] || { printf "Explicit absolute app and output paths required\n" >&2; exit 64; }
[[ ! -e "$OUT" ]] || { printf "Output already exists; choose a new directory\n" >&2; exit 73; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/verify_macos_bundle.py" "$APP" > /dev/null
mkdir -p "$OUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/PortLink-0.1.0-mac-preview.zip"
VERIFY_DIR="$(mktemp -d /tmp/portlink-package-verify.XXXXXX)"
/usr/bin/ditto -x -k "$OUT/PortLink-0.1.0-mac-preview.zip" "$VERIFY_DIR"
python3 "$SCRIPT_DIR/verify_macos_bundle.py" "$VERIFY_DIR/PortLink.app" > "$OUT/bundle-verification.json"
/usr/bin/shasum -a 256 "$OUT/PortLink-0.1.0-mac-preview.zip" > "$OUT/SHA256SUMS.txt"
printf "Created preview ZIP and reverified extracted bundle. Temporary verification directory: %s\n" "$VERIFY_DIR"
printf "This is not a Developer ID or notarization assertion.\n"
