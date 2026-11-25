#!/bin/sh
# Builds the Sparkle update feed from notarized archives.
#
# Usage: scripts/appcast.sh [--upload [--replace]] <UsageSwitch-x.y.z.zip> [more.zip ...]
#
# Copies each archive into build/appcast-feed/ and runs Sparkle's
# generate_appcast, which EdDSA-signs every item with the private key in the
# login keychain (account "usageswitch" — created once by the owner with
# Sparkle's `generate_keys --account usageswitch`; the private key never
# leaves the keychain and is never committed).
#
# The feed itself is signed with the same key. Builds from 2.5.1 on set
# SURequireSignedFeed and accept no feed whose signature doesn't verify; older
# builds ignore the signature. generate_appcast has no flag for this — it signs
# the feed only when an archive in it sets SURequireSignedFeed — so a feed it
# leaves unsigned is signed here with sign_update.
#
# The feed lists exactly the archives named on the command line. The previous
# appcast.xml is discarded, and anything else left in build/appcast-feed/ stops
# the script: generate_appcast would turn an older archive into another item,
# and --upload would not publish it. Delta updates are off (--maximum-deltas 0)
# for the same reason.
#
# The feed lives at a fixed URL: the "appcast" GitHub release is a machine
# endpoint whose assets are appcast.xml plus every update archive, so all
# enclosure URLs share one prefix — the SUFeedURL baked into Info.plist.
# --upload creates that release if needed, uploads the archives and only then
# the feed, so the published feed never names a file that is not there yet.
# Nothing is uploaded unless scripts/verify-appcast.swift passes. An archive
# whose name is already published is not overwritten unless --replace is given:
# until the new feed is up, the live feed still carries the old file's signature.
set -eu

REPO="deximple/usageswitch"
TAG="appcast"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
FEED_DIR="build/appcast-feed"
SPARKLE_BIN="${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}"
ACCOUNT="usageswitch"

# Keeps the archive paths as positional parameters, so a path with spaces stays one argument.
UPLOAD=0
REPLACE=0
for arg do
    shift
    case "$arg" in
        --upload) UPLOAD=1 ;;
        --replace) REPLACE=1 ;;
        *) set -- "$@" "$arg" ;;
    esac
done
[ "$#" -gt 0 ] || { echo "usage: $0 [--upload [--replace]] <archive.zip> [...]" >&2; exit 64; }
[ -x "$SPARKLE_BIN/generate_appcast" ] || {
    echo "generate_appcast not found at $SPARKLE_BIN — run 'swift build' first" >&2; exit 69; }

for archive do
    [ -f "$archive" ] || { echo "missing archive: $archive" >&2; exit 66; }
    case "$archive" in
        *.zip|*.dmg|*.tar*|*.tbz*) ;;
        *) echo "not an update archive: $archive" >&2; exit 65 ;;
    esac
    # Two archives with one file name would overwrite each other in the feed folder.
    same=0
    for other do
        if [ "$(basename "$other")" = "$(basename "$archive")" ]; then same=$((same + 1)); fi
    done
    [ "$same" -eq 1 ] || { echo "two archives are named $(basename "$archive")" >&2; exit 65; }
done

mkdir -p "$FEED_DIR"
for entry in "$FEED_DIR"/*; do
    [ -e "$entry" ] || continue   # an empty folder leaves the pattern unexpanded
    name=$(basename "$entry")
    named=0
    for archive do
        if [ "$name" = "$(basename "$archive")" ]; then named=1; fi
    done
    if [ "$name" != appcast.xml ] && [ "$named" -eq 0 ]; then
        echo "$FEED_DIR holds '$name', which is not an archive named on the command line." >&2
        echo "Move the folder aside (it is an earlier release's feed) and run again." >&2
        exit 65
    fi
done
rm -f "$FEED_DIR/appcast.xml"
for archive do
    cp "$archive" "$FEED_DIR/"
done

"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "$PREFIX" "$FEED_DIR"
grep -qF '<!-- sparkle-signatures:' "$FEED_DIR/appcast.xml" \
    || "$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$FEED_DIR/appcast.xml"
echo "wrote $FEED_DIR/appcast.xml"

swift "$(dirname "$0")/verify-appcast.swift" "$FEED_DIR/appcast.xml" --archives "$FEED_DIR" || {
    echo "the feed failed verification — nothing uploaded" >&2; exit 1; }

if [ "$UPLOAD" -eq 1 ]; then
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
        || gh release create "$TAG" --repo "$REPO" --latest=false \
               --title "Update feed" --notes "Sparkle appcast endpoint. Not a release."
    if [ "$REPLACE" -eq 0 ]; then
        published=$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')
        for archive do
            name=$(basename "$archive")
            if printf '%s\n' "$published" | grep -qxF "$name"; then
                echo "$name is already published. Uploading it again would leave the live feed" >&2
                echo "signed for the old file until the new feed is up; pass --replace to do that." >&2
                exit 65
            fi
        done
    fi
    # The copies in the feed folder are the bytes that were just verified.
    for archive do
        shift
        set -- "$@" "$FEED_DIR/$(basename "$archive")"
    done
    gh release upload "$TAG" --repo "$REPO" --clobber "$@"
    gh release upload "$TAG" --repo "$REPO" --clobber "$FEED_DIR/appcast.xml"
    echo "uploaded archives, then the feed, to $PREFIX"
fi
