#!/bin/bash
# Runs the test suite with coverage and writes docs/evidence/coverage.txt (SwitcherCore only) in the
# main checkout, which outlives a worktree.
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && MAIN="$(dirname "$MAIN")" || MAIN="$PWD"
EVIDENCE="$MAIN/docs/evidence"
mkdir -p "$EVIDENCE"
swift test --enable-code-coverage
BIN_DIR="$(swift build --show-bin-path)"
# Older SwiftPM links one ClaudeSwitcherPackageTests bundle; newer toolchains build one per test target.
objects=()
for bundle in "$BIN_DIR"/*.xctest; do
  binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
  if [ -f "$binary" ]; then
    if [ "${#objects[@]}" -gt 0 ]; then objects+=(-object); fi
    objects+=("$binary")
  fi
done
[ "${#objects[@]}" -gt 0 ] || { echo "no test bundle found under $BIN_DIR" >&2; exit 1; }
# Written next to the report and moved over it, so a failed report keeps the last one.
TMP_OUT="$(mktemp "$EVIDENCE/.coverage.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT
xcrun llvm-cov report "${objects[@]}" \
  -instr-profile "$BIN_DIR/codecov/default.profdata" \
  -ignore-filename-regex='(/Tests/|/Sources/ClaudeSwitcher/|/\.build/)' > "$TMP_OUT"
chmod 644 "$TMP_OUT"
mv -f "$TMP_OUT" "$EVIDENCE/coverage.txt"
cat "$EVIDENCE/coverage.txt"
