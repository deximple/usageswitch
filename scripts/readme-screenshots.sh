#!/bin/bash
# Regenerates every README screenshot from the app's synthetic fixtures.
# Requires: ./scripts/bundle.sh output (build/UsageSwitch.app) + ffmpeg + swift.
# Output: docs/screenshots/<lang>/{menu-light,menu-dark,all-usage,codex,demo.gif} + docs/screenshots/icon.png
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/UsageSwitch.app/Contents/MacOS/UsageSwitch"
if [ ! -x "$APP" ]; then
    echo "build/UsageSwitch.app is missing — run ./scripts/bundle.sh first" >&2; exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg required for demo.gif" >&2; exit 1; }
OUT=docs/screenshots
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Render a snapshot; the `switching` fixture never terminates, so cap every run.
render() {
    ( "$APP" "$@" & p=$!
      for _ in $(seq 40); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done
      kill -9 "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || : )
}
frame() { swift scripts/frame-screenshot.swift "$1" "$2" "${3:-}"; }
# frame args with an optional --dark
frameDark() { frame "$1" "$2" --dark; }

sips -s format png -Z 256 Resources/AppIcon.icns --out "$OUT/icon.png" >/dev/null

for LANG in en ko ja zh-Hans es; do
    D="$OUT/$LANG"; mkdir -p "$D"
    # menu: snapshot-height lifts the 600pt panel cap; the view self-fits to content
    render --snapshot "$TMP/menu-light.png" --menu-preview --ui-fixture usage-readme --tab usage --snapshot-height 1200 --appearance light --lang "$LANG"
    render --snapshot "$TMP/menu-dark.png"  --menu-preview --ui-fixture usage-readme --tab usage --snapshot-height 1200 --appearance dark  --lang "$LANG"
    render --snapshot "$TMP/all.png"   --ui-fixture usage-seven --tab usage --snapshot-height 1400 --appearance light --lang "$LANG"
    render --snapshot "$TMP/codex.png" --ui-fixture list        --tab codex --snapshot-height 850  --appearance light --lang "$LANG"
    frame "$TMP/menu-light.png" "$D/menu-light.png"
    frameDark "$TMP/menu-dark.png" "$D/menu-dark.png"
    frame "$TMP/all.png"   "$D/all-usage.png"
    frame "$TMP/codex.png" "$D/codex.png"

    # demo.gif: usage list -> guide-expanded list -> switching -> success.
    # The menu's Claude tab can't show the switch checklist, so all four frames
    # are window renders at one equal height.
    render --snapshot "$TMP/f1.png" --ui-fixture usage-readme --tab usage --snapshot-height 1050 --appearance light --lang "$LANG"
    render --snapshot "$TMP/f2.png" --ui-fixture usage-readme-guide --tab usage --snapshot-height 1050 --appearance light --lang "$LANG"
    render --snapshot "$TMP/f3.png" --ui-fixture switching --tab claude --snapshot-height 1050 --appearance light --lang "$LANG"
    render --snapshot "$TMP/f4.png" --ui-fixture success   --tab claude --snapshot-height 1050 --appearance light --lang "$LANG"
    for i in 1 2 3 4; do frame "$TMP/f$i.png" "$TMP/cf$i.png"; done
    # shared canvas: largest framed frame + 40px margin, soft neutral gradient
    CW=$(sips -g pixelWidth "$TMP"/cf*.png | awk '/pixelWidth/{print $2}' | sort -n | tail -1)
    CH=$(sips -g pixelHeight "$TMP"/cf*.png | awk '/pixelHeight/{print $2}' | sort -n | tail -1)
    CW=$((CW + 40)); CH=$((CH + 40))
    for i in 1 2 3 4; do
        ffmpeg -y -v error -f lavfi -i "gradients=size=${CW}x${CH}:c0=0xE9EDF2:c1=0xD5DBE3" \
            -i "$TMP/cf$i.png" -filter_complex "[0][1]overlay=(W-w)/2:(H-h)/2" -frames:v 1 "$TMP/canvas$i.png"
    done
    ffmpeg -y -v error \
        -loop 1 -t 2.8 -i "$TMP/canvas1.png" -loop 1 -t 2.8 -i "$TMP/canvas2.png" \
        -loop 1 -t 2.8 -i "$TMP/canvas3.png" -loop 1 -t 2.8 -i "$TMP/canvas4.png" \
        -filter_complex "[0][1]xfade=transition=fade:duration=0.35:offset=2.45[x1];\
[x1][2]xfade=transition=fade:duration=0.35:offset=4.9[x2];\
[x2][3]xfade=transition=fade:duration=0.35:offset=7.35[v];\
[v]fps=15,scale=740:-1:flags=lanczos,split[a][b];\
[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[o]" \
        -map "[o]" -loop 0 "$D/demo.gif"
    # keep <= 2 MB by lowering fps (never below 8), then fades — never width
    FPS=15
    while [ "$(stat -f%z "$D/demo.gif")" -gt 2000000 ] && [ "$FPS" -gt 8 ]; do
        FPS=$((FPS - 3)); [ "$FPS" -lt 8 ] && FPS=8
        ffmpeg -y -v error -i "$D/demo.gif" -vf "fps=${FPS},split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 "$TMP/demo-small.gif"
        mv "$TMP/demo-small.gif" "$D/demo.gif"
    done
    echo "$LANG done"
done
echo "screenshots written under $OUT"
