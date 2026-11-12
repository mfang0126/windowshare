#!/bin/bash
# Build WindowShareHost as a .app bundle (menu bar, screen-recording TCC entry).
# Usage: ./Scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) exit 2 ;; esac
APP="build/WindowShareHost.app"

# release: stable signing is required (macOS ties Screen Recording / Accessibility grants to the signature).
SIGN="-"
if [ "$CONFIG" = release ]; then
  ID="${WINDOWSHARE_SIGNING_IDENTITY:-}"
  if ! [[ "$ID" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "error: release needs WINDOWSHARE_SIGNING_IDENTITY=<40-hex certificate SHA1> (see: security find-identity -v -p codesigning). Ad-hoc signing is not allowed for release." >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning | grep -qi "$ID"; then
    echo "error: signing identity $ID not found in keychain (security find-identity -v -p codesigning)." >&2
    exit 1
  fi
  SIGN="$ID"
fi

swift build -c "$CONFIG" --disable-automatic-resolution
BIN="$(swift build -c "$CONFIG" --disable-automatic-resolution --show-bin-path)/WindowShareHost"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowShareHost"
cp host/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s "$SIGN" "$APP"
echo "built: $(pwd)/$APP"
