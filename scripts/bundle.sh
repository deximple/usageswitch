#!/bin/bash
# Builds build/UsageSwitch.app (release, universal: Apple silicon and Intel) and signs it.
# Developer ID when this Mac's keychain has that identity; without it, ad-hoc, and it says so.
# SIGN_IDENTITY=- asks for the ad-hoc signature outright. An identity that is there but fails to
# sign stops the build: a release must never come out ad-hoc without anyone asking for it.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
# One multi-arch build: the new build backend emits a single universal product —
# per-arch --show-bin-path no longer exists (both arches share Products/<config>).
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/ClaudeSwitcher"
APP="build/UsageSwitch.app"
EXECUTABLE="$APP/Contents/MacOS/UsageSwitch"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$EXECUTABLE"
# Both slices or no app: a one-architecture build must never pass for the universal one.
# One architecture per call — some lipo versions take a second one for another input file.
for arch in arm64 x86_64; do
  if ! lipo "$EXECUTABLE" -verify_arch "$arch"; then
    echo "error: $EXECUTABLE is not universal: no $arch slice (has: $(lipo -archs "$EXECUTABLE" 2>/dev/null || echo unreadable))" >&2
    rm -rf "$APP"
    exit 1
  fi
done
# SPM copies the Sparkle XCFramework next to the built product; the app loads it from
# Contents/Frameworks via an added rpath. The framework's XPC services ride along.
SPARKLE_SRC="$(dirname "$BIN")/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
  cp -R "$SPARKLE_SRC" "$FRAMEWORK"
  otool -l "$EXECUTABLE" | grep -q '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath '@executable_path/../Frameworks' "$EXECUTABLE"
else
  echo "warning: Sparkle.framework not found at $SPARKLE_SRC — updater disabled" >&2
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Jaekeun Song (4UN6WC576K)}"
# Notarization needs Apple's secure timestamp; TIMESTAMP=none skips it for offline local builds.
TS="--timestamp"; [ "${TIMESTAMP:-}" = none ] && TS="--timestamp=none"
sign() { perl -e 'alarm 90; exec @ARGV' codesign --force --options runtime "$TS" --sign "$IDENTITY" "$@" ; }
# Inside-out: the framework (with its XPC services) before the bundle. The first step is checked
# by hand: called as an `if` condition, `set -e` would not stop at a failed signing.
sign_bundle() {
  if [ -d "$FRAMEWORK" ]; then sign --deep "$FRAMEWORK" || return 1; fi
  sign "$APP"
}
# Ad-hoc, for a Mac without the Developer ID. No hardened runtime: an ad-hoc signature has no Team
# ID, so with it library validation refuses the embedded Sparkle.framework and the app dies at
# launch ("mapping process and mapped file (non-platform) have different Team IDs").
sign_bundle_ad_hoc() {
  if [ -d "$FRAMEWORK" ]; then codesign --force --deep --sign - "$FRAMEWORK"; fi
  codesign --force --sign - "$APP"
}
# The valid signing identities, captured first: `grep -q` on a pipe would SIGPIPE `security`
# under pipefail.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [ "$IDENTITY" = - ]; then
  sign_bundle_ad_hoc
  echo "signed: ad-hoc"
elif ! grep -qF -- "$IDENTITY" <<< "$IDENTITIES"; then
  echo "no valid signing identity \"$IDENTITY\" in the keychain; using ad-hoc signature" >&2
  sign_bundle_ad_hoc
  echo "signed: ad-hoc"
elif sign_bundle; then
  echo "signed: $IDENTITY"
else
  # codesign's own message is above. A keychain prompt nobody answers ends in the 90 s alarm.
  echo "error: signing with \"$IDENTITY\" failed; for an ad-hoc build run: SIGN_IDENTITY=- $0" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
