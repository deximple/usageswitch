#!/bin/bash
# Notarizes and staples build/UsageSwitch.app, then writes the downloads: build/UsageSwitch-<version>.zip and
# build/UsageSwitch-<version>.dmg (signed, notarized and stapled too).
# Uses a notarytool keychain profile created once with (the password is asked for in a hidden prompt):
#   xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
# and passed as NOTARY_PROFILE=<profile>.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
APP="build/UsageSwitch.app"
SUBMIT_ZIP="build/UsageSwitch-submit.zip"

# Submits a file and waits; on rejection, saves Apple's log next to it and stops.
submit() {
  local file=$1 result=$2
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  local status id
  status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$result")
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$result")
  echo "submission $id ($(basename "$file")): $status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" "${result%.json}-log.json" || true
    echo "notarization failed; details in ${result%.json}-log.json" >&2
    exit 1
  fi
}

codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)   # captured first: grep -q would SIGPIPE codesign under pipefail
if ! grep -q '^Timestamp=' <<< "$SIGNATURE"; then
  echo "no secure timestamp in the signature; rebuild with scripts/bundle.sh (without TIMESTAMP=none)" >&2
  exit 1
fi
IDENTITY=$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<< "$SIGNATURE" | head -1)
[ -n "$IDENTITY" ] || { echo "the app isn't signed with a Developer ID" >&2; exit 1; }

rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
submit "$SUBMIT_ZIP" build/notarize.json
rm -f "$SUBMIT_ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/UsageSwitch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Disk image: the stapled app next to an Applications link, for drag-to-install.
DMG="build/UsageSwitch-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/UsageSwitch.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname UsageSwitch -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
submit "$DMG" build/notarize-dmg.json
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

# Checksums for the release notes: bare filenames, dmg before zip, written by this script.
(cd build && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")") > build/SHA256SUMS.txt
cat build/SHA256SUMS.txt
