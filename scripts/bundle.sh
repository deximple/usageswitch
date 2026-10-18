#!/bin/bash
# Builds build/UsageSwitch.app (release, universal: Apple silicon and Intel) and signs it.
# Developer ID first; if unattended signing is impossible (keychain consent), falls back to ad-hoc and says so.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c "$CONFIG" --arch "$ARCH"
  BINS+=("$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/ClaudeSwitcher")
done
APP="build/UsageSwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/UsageSwitch" "${BINS[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Jaekeun Song (4UN6WC576K)}"
# Notarization needs Apple's secure timestamp; TIMESTAMP=none skips it for offline local builds.
TS="--timestamp"; [ "${TIMESTAMP:-}" = none ] && TS="--timestamp=none"
if perl -e 'alarm 90; exec @ARGV' codesign --force --options runtime "$TS" --sign "$IDENTITY" "$APP" 2>build/codesign.log; then
  echo "signed: $IDENTITY"
else
  echo "Developer ID signing unavailable unattended ($(tail -1 build/codesign.log)); using ad-hoc signature" >&2
  codesign --force --options runtime --sign - "$APP"
  echo "signed: ad-hoc"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
