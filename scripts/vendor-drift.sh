#!/bin/bash
# Checks the vendor CLIs installed on this Mac against what UsageSwitch reads from them, and
# writes a report to docs/private/vendor-drift/ (gitignored). See docs/vendor-drift.md.
#
#   ./scripts/vendor-drift.sh                      report; exits 1 when drift is found
#   ./scripts/vendor-drift.sh --out <folder>       write the report somewhere else
#   ./scripts/vendor-drift.sh --update-snapshot    refreeze the Codex protocol snapshot from the
#                                                  Codex CLI the app runs (--codex <cli>: from that one)
#
# Read-only. The vendor CLIs are run the way the app runs them and use their own sign-ins;
# no credential is opened and nothing that changes an account is called.
set -euo pipefail
cd "$(dirname "$0")/.."
SNAPSHOT=scripts/vendor-drift/codex-protocol.snapshot.json
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# From a worktree the report still goes to the main checkout, which outlives the worktree.
MAIN="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && MAIN="$(dirname "$MAIN")" || MAIN="$PWD"
OUT="$MAIN/docs/private/vendor-drift"
UPDATE=0
CODEX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update-snapshot) UPDATE=1 ;;
    --codex) [ $# -ge 2 ] || usage; CODEX="$2"; shift ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

swift build --product usageswitch-drift >&2
BIN="$(swift build --show-bin-path)/usageswitch-drift"
# An empty private folder for the vendor CLIs to start in; the tool itself writes no file.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/run"

if [ "$UPDATE" -eq 1 ]; then
  if [ -n "$CODEX" ]; then
    "$BIN" --work "$WORK/run" --update-snapshot --codex "$CODEX" > "$WORK/snapshot.json"
  else
    "$BIN" --work "$WORK/run" --update-snapshot > "$WORK/snapshot.json"
  fi
  [ -s "$WORK/snapshot.json" ] || { echo "vendor-drift: no snapshot was produced" >&2; exit 2; }
  cp "$WORK/snapshot.json" "$SNAPSHOT"
  echo "Updated $SNAPSHOT" >&2
  git --no-pager diff --stat -- "$SNAPSHOT" >&2 || true
  exit 0
fi

STATUS=0
"$BIN" --work "$WORK/run" --snapshot "$SNAPSHOT" > "$WORK/report.md" || STATUS=$?
if [ "$STATUS" -gt 1 ]; then
  echo "vendor-drift: the check could not run (exit $STATUS)" >&2
  exit "$STATUS"
fi
mkdir -p -- "$OUT"
REPORT="$OUT/$(date +%Y-%m-%d-%H%M%S).md"
cp -- "$WORK/report.md" "$REPORT"
cp -- "$WORK/report.md" "$OUT/latest.md"
cat -- "$REPORT"
echo "Report: ${REPORT/#$HOME/~}" >&2
exit "$STATUS"
