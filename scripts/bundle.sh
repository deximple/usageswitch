#!/bin/bash
# Builds build/UsageSwitch.app (release, universal: Apple silicon and Intel) and signs it.
# Developer ID first; if unattended signing is impossible (keychain consent), falls back to ad-hoc and says so.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
# One multi-arch build: the new build backend emits a single universal product —
# per-arch --show-bin-path no longer exists (both arches share Products/<config>).
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/ClaudeSwitcher"
APP="build/UsageSwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/UsageSwitch"
# SPM copies the Sparkle XCFramework next to the built product; the app loads it from
# Contents/Frameworks via an added rpath. The framework's XPC services ride along.
SPARKLE_SRC="$(dirname "$BIN")/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
  cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
  otool -l "$APP/Contents/MacOS/UsageSwitch" | grep -q '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/UsageSwitch"
else
  echo "warning: Sparkle.framework not found at $SPARKLE_SRC — updater disabled" >&2
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Jaekeun Song (4UN6WC576K)}"
# Notarization needs Apple's secure timestamp; TIMESTAMP=none skips it for offline local builds.
TS="--timestamp"; [ "${TIMESTAMP:-}" = none ] && TS="--timestamp=none"
sign() { perl -e 'alarm 90; exec @ARGV' codesign --force --options runtime "$TS" --sign "$IDENTITY" "$@" ; }
# Inside-out: the framework (with its XPC services) before the bundle.
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] && \
  sign --deep "$APP/Contents/Frameworks/Sparkle.framework"
if sign "$APP" 2>build/codesign.log; then
  echo "signed: $IDENTITY"
else
  echo "Developer ID signing unavailable unattended ($(tail -1 build/codesign.log)); using ad-hoc signature" >&2
  codesign --force --options runtime --sign - "$APP"
  echo "signed: ad-hoc"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
