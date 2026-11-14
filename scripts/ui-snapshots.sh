#!/bin/bash
# UI snapshot regression check. Renders the demo screens in every language and appearance from the debug
# build's synthetic fixtures (offscreen, no real accounts) and compares the PNGs pixel by pixel with a
# baseline rendered earlier on this Mac.
#
#   scripts/ui-snapshots.sh baseline [--ref main]   render the baseline into build/ui-baseline/ (replaces it)
#   scripts/ui-snapshots.sh compare                 render build/ui-snapshots/ and compare; exit 1 on a change
#   scripts/ui-snapshots.sh render                  only render build/ui-snapshots/, to look at
#
# baseline --ref <commit> builds that commit in build/ui-baseline-src/ and renders it, so the working
# tree stays as it is; without --ref the baseline is the current checkout.
#
# Options: --langs "en es"   --appearances "light"   --only <text in the snapshot name>   --jobs N
#          --baseline DIR (another baseline folder, relative to the repository)   --no-build
#          --tolerance N (compare: a channel difference that still counts as equal, default 0)
#
# The baseline is not committed: a render depends on this Mac (macOS version, the icons of installed apps,
# the accent color), so a committed set would not match CI or another machine, and a full set is about
# 70 MB. Changed snapshots land in build/ui-diff/ as baseline | current | changed pixels.
#
# render and compare also print WRAPS lines: menus that are taller in some languages, which means text
# wrapped there. That needs no baseline and is information, not a failure.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,22p' scripts/ui-snapshots.sh | sed 's/^# \{0,1\}//' >&2; exit 2; }

COMMAND="${1:-}"; [ $# -gt 0 ] && shift
LANGS="en ko ja es zh-Hans"; APPEARANCES="light dark"; ONLY=""; REF=""; BUILD=1; TOLERANCE=0
BASELINE=build/ui-baseline; CURRENT=build/ui-snapshots; DIFF=build/ui-diff; SOURCE=.
JOBS=$(sysctl -n hw.ncpu); [ "$JOBS" -gt 8 ] && JOBS=8
while [ $# -gt 0 ]; do
    [ "$1" = "--no-build" ] && { BUILD=0; shift; continue; }
    [ $# -ge 2 ] || usage
    case "$1" in
        --langs) LANGS="$2" ;;
        --appearances) APPEARANCES="$2" ;;
        --only) ONLY="$2" ;;
        --jobs) JOBS="$2" ;;
        --ref) REF="$2" ;;
        --baseline) BASELINE="$2" ;;
        --tolerance) TOLERANCE="$2" ;;
        *) usage ;;
    esac
    shift 2
done
case "$COMMAND" in baseline|compare|render) ;; *) usage ;; esac
[ -z "$REF" ] || [ "$COMMAND" = baseline ] || { echo "--ref only applies to baseline" >&2; exit 2; }
if [ "$COMMAND" = compare ] && [ ! -f "$BASELINE/BASELINE.txt" ]; then
    echo "no baseline in $BASELINE — run: scripts/ui-snapshots.sh baseline" >&2; exit 2
fi

# name, height in points, launch arguments. Menus are 360pt wide and fit their content (the height only
# lifts the panel cap); windows are 700pt wide, the detail 460pt.
surfaces() {
    cat <<'EOF'
menu-usage 1600 --menu-preview --ui-fixture usage --tab usage
menu-usage-readme 1600 --menu-preview --ui-fixture usage-readme --tab usage
menu-usage-seven 1600 --menu-preview --ui-fixture usage-seven --tab usage
menu-usage-last-known 1600 --menu-preview --ui-fixture usage-last-known --tab usage
menu-usage-stale 1600 --menu-preview --ui-fixture usage-stale --tab usage
menu-usage-connecting 1600 --menu-preview --ui-fixture usage-connecting --tab usage
menu-usage-guide 1600 --menu-preview --ui-fixture usage-guide --tab usage
menu-usage-readme-guide 1600 --menu-preview --ui-fixture usage-readme-guide --tab usage
menu-usage-gemini 1600 --menu-preview --ui-fixture usage-gemini --tab usage
menu-usage-empty 1600 --menu-preview --ui-fixture usage-empty --tab usage
menu-usage-none 1600 --menu-preview --ui-fixture usage-none --tab usage
menu-usage-long 4200 --menu-preview --ui-fixture usage-long --tab usage
menu-claude 1200 --menu-preview --ui-fixture list --tab claude
menu-codex 1200 --menu-preview --ui-fixture list --tab codex
menu-api 1200 --menu-preview --ui-fixture usage --tab api
main-usage-all 1400 --ui-fixture usage-all --tab usage
main-usage-seven 1400 --ui-fixture usage-seven --tab usage
main-usage-last-known 1400 --ui-fixture usage-last-known --tab usage
main-usage-stale 1400 --ui-fixture usage-stale --tab usage
main-usage-connecting 1400 --ui-fixture usage-connecting --tab usage
main-usage-guide 1400 --ui-fixture usage-guide --tab usage
main-usage-none 1400 --ui-fixture usage-none --tab usage
main-claude-list 850 --ui-fixture list --tab claude
main-claude-success 850 --ui-fixture success --tab claude
main-claude-relogin 850 --ui-fixture relogin --tab claude
main-claude-error 850 --ui-fixture error --tab claude
main-codex 850 --ui-fixture list --tab codex
main-api 850 --ui-fixture usage --tab api
EOF
    # The detail window renders only where the build has --detail.
    if grep -q '"--detail"' "$SOURCE/Sources/ClaudeSwitcher/App.swift"; then
        cat <<'EOF'
detail-codex-work 420 --ui-fixture usage-all --detail codex:found:.codex-work
detail-codex-side 420 --ui-fixture usage-all --detail codex:m-3c4d5e6f
detail-cursor 460 --ui-fixture usage-all --detail cursor:cursor
detail-gemini 460 --ui-fixture usage-seven --detail gemini:current
detail-last-known 420 --ui-fixture usage-last-known --detail codex:standard
EOF
    fi
}

# Renders one snapshot. A render that doesn't quit on its own is stopped once its PNG is written.
shot() {
    local out="$1"; shift
    "$BIN" --snapshot "$out" "$@" >/dev/null 2>&1 &
    local pid=$!
    for _ in $(seq 60); do
        kill -0 "$pid" 2>/dev/null || break
        [ -s "$out" ] && { sleep 0.5; break; }
        sleep 0.25
    done
    kill -9 "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
}

render_into() {
    local out="$1" name height args lang appearance file failed=0
    local expected; expected=$(mktemp)
    mkdir -p "$out"
    while read -r name height args; do
        for lang in $LANGS; do
            for appearance in $APPEARANCES; do
                file="$name-$lang-$appearance"
                case "$file" in *"$ONLY"*) ;; *) continue ;; esac
                echo "$file" >> "$expected"
                rm -f "$out/$file.png"
                while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.1; done
                # shellcheck disable=SC2086  # $args is a list of launch arguments
                shot "$out/$file.png" $args --snapshot-height "$height" --appearance "$appearance" --lang "$lang" &
            done
        done
    done < <(surfaces)
    wait
    [ -s "$expected" ] || { echo "nothing matches --only '$ONLY'" >&2; rm -f "$expected"; exit 2; }
    while read -r file; do
        [ -s "$out/$file.png" ] || { echo "not rendered: $file" >&2; failed=1; }
    done < "$expected"
    echo "$(wc -l < "$expected" | tr -d ' ') snapshots in $out"
    rm -f "$expected"
    [ "$failed" -eq 0 ] || exit 2
}

if [ -n "$REF" ]; then
    COMMIT=$(git rev-parse --verify --quiet "$REF^{commit}") || { echo "no such commit: $REF" >&2; exit 2; }
    SOURCE=build/ui-baseline-src
    mkdir -p "$SOURCE"
    # Replace the sources, keep .build so the next baseline of a nearby commit builds incrementally.
    find "$SOURCE" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
    git archive "$COMMIT" | tar -x -C "$SOURCE"
fi
[ "$BUILD" -eq 0 ] || swift build --package-path "$SOURCE" >&2
BIN="$(swift build --package-path "$SOURCE" --show-bin-path)/ClaudeSwitcher"
[ -x "$BIN" ] || { echo "no debug build at $BIN — run without --no-build" >&2; exit 1; }

mkdir -p build
TOOL=build/ui-snapshot-diff
if [ ! -x "$TOOL" ] || [ scripts/ui-snapshot-diff.swift -nt "$TOOL" ]; then
    xcrun swiftc -O scripts/ui-snapshot-diff.swift -o "$TOOL"
fi

case "$COMMAND" in
    baseline)
        # One baseline is one commit: drop the previous snapshots so none of them outlives this render.
        mkdir -p "$BASELINE"
        rm -f "$BASELINE"/*.png "$BASELINE/BASELINE.txt"
        render_into "$BASELINE"
        {
            if [ -n "$REF" ]; then echo "commit: $COMMIT ($REF)"
            else echo "commit: $(git rev-parse HEAD)$(git diff --quiet HEAD || echo ' + uncommitted changes')"; fi
            echo "macOS: $(sw_vers -productVersion)"
            echo "rendered: $(date '+%Y-%m-%d %H:%M')"
        } > "$BASELINE/BASELINE.txt"
        ;;
    render)
        rm -rf "$CURRENT"
        render_into "$CURRENT"
        # shellcheck disable=SC2086  # $LANGS is a list
        "$TOOL" wraps "$CURRENT" $LANGS
        ;;
    compare)
        rm -rf "$CURRENT"
        render_into "$CURRENT"
        # shellcheck disable=SC2086
        "$TOOL" wraps "$CURRENT" $LANGS
        echo "baseline: $(tr '\n' ' ' < "$BASELINE/BASELINE.txt")"
        "$TOOL" "$BASELINE" "$CURRENT" "$DIFF" --tolerance "$TOLERANCE"
        ;;
esac
