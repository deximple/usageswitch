#!/bin/bash
# Runs the test suite with coverage and writes docs/evidence/coverage.txt (SwitcherCore only).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/evidence
swift test --enable-code-coverage
BIN_DIR="$(swift build --show-bin-path)"
xcrun llvm-cov report "$BIN_DIR/ClaudeSwitcherPackageTests.xctest/Contents/MacOS/ClaudeSwitcherPackageTests" \
  -instr-profile "$BIN_DIR/codecov/default.profdata" -ignore-filename-regex='(/Tests/|/Sources/ClaudeSwitcher/)' \
  | tee docs/evidence/coverage.txt
