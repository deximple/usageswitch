#!/bin/sh
# Builds the Sparkle update feed from notarized archives.
#
# Usage: scripts/appcast.sh [--upload] <UsageSwitch-x.y.z.zip> [more.zip ...]
#
# Copies each archive into build/appcast-feed/ and runs Sparkle's
# generate_appcast, which EdDSA-signs every item with the private key in the
# login keychain (account "usageswitch" — created once by the owner with
# Sparkle's `generate_keys --account usageswitch`; the private key never
# leaves the keychain and is never committed).
#
# The feed lives at a fixed URL: the "appcast" GitHub release is a machine
# endpoint whose assets are appcast.xml plus every update archive, so all
# enclosure URLs share one prefix — the SUFeedURL baked into Info.plist.
# --upload creates that release if needed and uploads the feed + archives.
set -eu

REPO="deximple/usageswitch"
TAG="appcast"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
FEED_DIR="build/appcast-feed"
SPARKLE_BIN="${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}"
ACCOUNT="usageswitch"

UPLOAD=0
ARCHIVES=""
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        *) ARCHIVES="$ARCHIVES $arg" ;;
    esac
done
# shellcheck disable=SC2086
set -- $ARCHIVES
[ "$#" -gt 0 ] || { echo "usage: $0 [--upload] <archive.zip> [...]" >&2; exit 64; }
[ -x "$SPARKLE_BIN/generate_appcast" ] || {
    echo "generate_appcast not found at $SPARKLE_BIN — run 'swift build' first" >&2; exit 69; }

mkdir -p "$FEED_DIR"
for archive in "$@"; do
    [ -f "$archive" ] || { echo "missing archive: $archive" >&2; exit 66; }
    case "$archive" in
        *.zip|*.dmg|*.tar*|*.tbz*) ;;
        *) echo "not an update archive: $archive" >&2; exit 65 ;;
    esac
    cp "$archive" "$FEED_DIR/"
done

"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" \
    --download-url-prefix "$PREFIX" "$FEED_DIR"
echo "wrote $FEED_DIR/appcast.xml"

if [ "$UPLOAD" -eq 1 ]; then
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
        || gh release create "$TAG" --repo "$REPO" --latest=false \
               --title "Update feed" --notes "Sparkle appcast endpoint. Not a release."
    # shellcheck disable=SC2086
    gh release upload "$TAG" --repo "$REPO" --clobber "$FEED_DIR/appcast.xml" $ARCHIVES
    echo "uploaded feed + archives to $PREFIX"
fi
