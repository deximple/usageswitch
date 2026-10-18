#!/bin/bash
# Gate 6 audit: secret patterns (counts only, never values), store permissions, writes outside SafeFS,
# keychain API imports. Writes docs/evidence/audit.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/evidence/audit.txt
mkdir -p docs/evidence
STORE="$HOME/Library/Application Support/com.jaysong.usageswitch"
APP="${APP:-/Applications/UsageSwitch.app}"
PATTERN='sk-ant-[A-Za-z0-9_-]{8,}|sessionKey=[A-Za-z0-9%_-]{16,}|magic-link#[A-Za-z0-9_-]{16,}'
count() { grep -EIrc "$PATTERN" "$@" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}'; }
{
  echo "# UsageSwitch audit — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "## 1. Secret patterns (match counts only)"
  echo "git working tree (tracked + untracked, excluding .build/build): $(git ls-files -co --exclude-standard | grep -vE '^(\.build|build)/' | tr '\n' '\0' | xargs -0 grep -EIc "$PATTERN" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
  echo "git history (all commits, patch text): $(git log -p --all 2>/dev/null | grep -Ec "$PATTERN")"
  echo ".goal-task state/design/todo: $(count .goal-task)"
  echo "docs/evidence (text files): $(count docs/evidence)"
  # codex/ and codex-app-data/ hold Codex's own homes (its programs, plugins and OpenAI sign-in), not this app's data.
  echo "switcher store, all files incl. binary (grep -a, no -I): $(grep -Earc --exclude-dir=codex --exclude-dir=codex-app-data "$PATTERN" "$STORE" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
  echo "switcher store raw bytes 'sk-ant-' (cookie values stay encrypted): $(grep -arc --exclude-dir=codex --exclude-dir=codex-app-data 'sk-ant-' "$STORE" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
  echo "Codex homes kept in the store (Codex's own data, not scanned): $(ls "$STORE/codex" 2>/dev/null | wc -l | tr -d ' ')"
  echo
  echo "## 2. Store permissions (expect dirs 700, files 600)"
  echo "non-700 dirs: $(find "$STORE" \( -path "$STORE/codex" -o -path "$STORE/codex-app-data" \) -prune -o -type d ! -perm 700 -print 2>/dev/null | wc -l | tr -d ' ')"
  echo "non-600 files: $(find "$STORE" \( -path "$STORE/codex" -o -path "$STORE/codex-app-data" \) -prune -o -type f ! -perm 600 -print 2>/dev/null | wc -l | tr -d ' ')"
  echo "(codex/ and codex-app-data/ are Codex's own data and keep Codex's permissions; the folders themselves are 700)"
  echo
  echo "## 3. Filesystem writes outside SafeFS (SwitcherCore sources except SafeFS.swift)"
  echo "matches: $(grep -nE 'FileManager\.default\.(createDirectory|removeItem|moveItem|copyItem|createFile|replaceItem|trashItem)|\.write\(to:|[^.a-zA-Z_](rename|renamex_np|unlink|rmdir|mkdir)\(' Sources/SwitcherCore/*.swift Sources/SwitcherCore/Localization/*.swift Sources/SwitcherCore/Codex/*.swift | grep -v "SafeFS.swift" | grep -v "CodexAppControl.swift:.*trashItem" | grep -vE '^[^:]+:[0-9]+:\s*//' | wc -l | tr -d ' ')"
  echo "allowed (Codex tab: its own folder to the Trash, checked by SafeFS first): $(grep -c 'trashItem' Sources/SwitcherCore/Codex/CodexAppControl.swift)"
  grep -nE 'FileManager\.default\.(createDirectory|removeItem|moveItem|copyItem|createFile|replaceItem|trashItem)|\.write\(to:|[^.a-zA-Z_](rename|renamex_np|unlink|rmdir|mkdir)\(' Sources/SwitcherCore/*.swift Sources/SwitcherCore/Localization/*.swift Sources/SwitcherCore/Codex/*.swift | grep -v "SafeFS.swift" | grep -vE '^[^:]+:[0-9]+:\s*//' | sed 's/^/  /'
  echo "SQLite read-write opens (must be preceded by fs.check on a store/staged path):"
  grep -nB2 'mode: .readWrite' Sources/SwitcherCore/*.swift | grep -E 'fs.check|readWrite' | sed 's/^/  /'
  echo
  echo "## 3b. Claude launch/URL paths outside SystemClaudeAppControl (expect 0)"
  # Allowed: the Codex tab opening its sign-in page and "Check for Updates…" opening the releases page (https) in the browser.
  echo "matches: $(grep -nE 'NSWorkspace\.shared\.(open|openApplication)|openApplication\(' Sources/SwitcherCore/*.swift Sources/SwitcherCore/Codex/*.swift Sources/ClaudeSwitcher/*.swift | grep -v 'ClaudeAppControl.swift' | grep -v 'NSWorkspace.shared.open(signInLink)' | grep -v 'NSWorkspace.shared.open(ProductInfo.releasesURL)' | grep -vE '^[^:]+:[0-9]+:\s*//' | wc -l | tr -d ' ')"
  echo "allowed (browser sign-in page): $(grep -nc 'NSWorkspace.shared.open(signInLink)' Sources/ClaudeSwitcher/CodexModel.swift)"
  echo "allowed (releases page, Check for Updates…): $(grep -nc 'NSWorkspace.shared.open(ProductInfo.releasesURL)' Sources/ClaudeSwitcher/SettingsMenu.swift)"
  echo
  echo "## 4. Keychain API imports in shipped binary"
  BIN="$APP/Contents/MacOS/UsageSwitch"
  echo "binary: $BIN"
  echo "SecItem*/SecKeychain* symbols: $(nm -um "$BIN" 2>/dev/null | grep -cE 'SecItem|SecKeychain')"
  echo
  echo "## 5. Code signature"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
  codesign -dvv "$APP" 2>&1 | grep -E 'Authority=Developer ID Application|TeamIdentifier|Runtime|^Identifier=|flags=' | sed 's/^/  /'
} > "$OUT"
cat "$OUT"
