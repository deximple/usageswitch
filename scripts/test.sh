#!/bin/bash
# Runs the test suite with coverage and writes docs/evidence/coverage.txt (SwitcherCore only).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/evidence
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
xcrun llvm-cov report "${objects[@]}" \
  -instr-profile "$BIN_DIR/codecov/default.profdata" \
  -ignore-filename-regex='(/Tests/|/Sources/ClaudeSwitcher/|/\.build/)' \
  | tee docs/evidence/coverage.txt
