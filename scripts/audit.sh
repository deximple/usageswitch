#!/bin/bash
# Gate 6 audit: secret patterns (counts only, never values), store permissions, writes outside SafeFS,
# keychain API imports. Writes docs/evidence/audit.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/evidence/audit.txt
SOURCE_ONLY=0
for arg in "$@"; do case "$arg" in --source-only) SOURCE_ONLY=1 ;; esac; done
mkdir -p docs/evidence
STORE="$HOME/Library/Application Support/com.jaysong.usageswitch"
APP="${APP:-/Applications/UsageSwitch.app}"
PATTERN='sk-ant-[A-Za-z0-9_-]{8,}|sessionKey=[A-Za-z0-9%_-]{16,}|magic-link#[A-Za-z0-9_-]{16,}|ya29\.[0-9A-Za-z_-]{20,}|1//[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}|sk-(proj-)?[A-Za-z0-9]{20,}|xai-[A-Za-z0-9]{20,}|GOCSPX-[A-Za-z0-9_-]{10,}'
count() { grep -EIrc "$PATTERN" "$@" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}'; }
AUDIT_FAIL=0
{
  echo "# UsageSwitch audit — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  if [ "$SOURCE_ONLY" -eq 0 ]; then
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
  fi
  echo
  echo "## 3. Filesystem writes outside SafeFS (all of Sources/, with an in-script allowlist)"
  WRITE_RE='\.(createDirectory|removeItem|moveItem|copyItem|createFile|replaceItem|trashItem|createSymbolicLink|setAttributes)\(|\.write\(to(File)?:|FileHandle\(forWritingTo|forUpdating|O_CREAT|\b(chmod|fchmod|ftruncate|symlink)\(|[^.a-zA-Z_](rename|renamex_np|unlink|rmdir|mkdir)\('
  # Allowlist: <file>:<reason>. Entries are matched as path suffixes.
  # Every allowed match is a write that still goes through SafeFS checks or is a
  # deliberately raw open with O_NOFOLLOW on an allowlisted path.
  allow() {
    case "$1" in
      *CodexAppControl.swift:*trashItem*) return 0 ;;          # own folder to Trash after fs.check
      *Switcher.swift:*O_CREAT*) return 0 ;;                   # lock file: O_CREAT|O_NOFOLLOW
      *LockedStoreFile.swift:*O_CREAT*) return 0 ;;            # same lock pattern
      *SuggestionStorage.swift:*O_CREAT*) return 0 ;;          # append-only suggestion log, O_NOFOLLOW
      *SuggestionStorage.swift:*fchmod*) return 0 ;;           # the same descriptor's 0600
      *App.swift:*write*) return 0 ;;                          # --snapshot dev PNG dump
      *fs.createDirectory*|*fs.write*|*fs.remove*|*fs.move*|*fs.copy*|*fs.swap*|      *fs.restrictPermissions*|*fs.check*|*fs.isAllowed*|*fs.createSymbolicLink*) return 0 ;;  # fs. goes through SafeFS
      *afterOperation*) return 0 ;;                            # test-seam comment/member in SafeFS users
      *sandbox.fs.*) return 0 ;;
    esac
    return 1
  }
  RAW=$(grep -rnE --include='*.swift' "$WRITE_RE" Sources/ \
        | grep -v 'SafeFS\.swift' | grep -v 'ModelTFSnapshot' | grep -v 'Strings+' \
        | grep -vE 'func (rename|renamex_np|unlink|rmdir|mkdir|chmod|fchmod|ftruncate|symlink)\s*\(')
  UNALLOWED=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in *://*) continue ;; esac   # comment-only lines
    allow "$line" || UNALLOWED="$UNALLOWED$line\n"
  done <<< "$RAW"
  UNCOUNT=$(printf '%b' "$UNALLOWED" | grep -c . || true)
  echo "unallowed matches: $UNCOUNT (expect 0; any line here is a write outside SafeFS)"
  printf '%b' "$UNALLOWED" | sed 's/^/  /'
  AUDIT_FAIL="$UNCOUNT"
  echo "SQLite read-write opens (must be preceded by fs.check on a store/staged path):"
  grep -nB2 'mode: .readWrite' Sources/SwitcherCore/*.swift | grep -E 'fs.check|readWrite' | sed 's/^/  /'
  echo
  echo "## 3b. Claude launch/URL paths outside SystemClaudeAppControl (expect 0)"
  # Allowed: the Codex tab opening its sign-in page and "Check for Updates…" opening the releases page (https) in the browser.
  echo "matches: $(grep -nE 'NSWorkspace\.shared\.(open|openApplication)|openApplication\(' Sources/SwitcherCore/*.swift Sources/SwitcherCore/Codex/*.swift Sources/ClaudeSwitcher/*.swift | grep -v 'ClaudeAppControl.swift' | grep -v 'NSWorkspace.shared.open(signInLink)' | grep -v 'NSWorkspace.shared.open(ProductInfo.releasesURL)' | grep -vE '^[^:]+:[0-9]+:\s*//' | wc -l | tr -d ' ')"
  echo "allowed (browser sign-in page): $(grep -nc 'NSWorkspace.shared.open(signInLink)' Sources/ClaudeSwitcher/CodexModel.swift)"
  echo "allowed (releases page, Check for Updates…): $(grep -nc 'NSWorkspace.shared.open(ProductInfo.releasesURL)' Sources/ClaudeSwitcher/SettingsMenu.swift)"
  echo
  if [ "$SOURCE_ONLY" -eq 0 ]; then
  echo "## 4. Keychain API imports in shipped binary (expect: SecItemAdd, SecItemCopyMatching, SecItemDelete — 3)"
  BIN="$APP/Contents/MacOS/UsageSwitch"
  echo "binary: $BIN"
  echo "SecItem*/SecKeychain* symbols: $(nm -um "$BIN" 2>/dev/null | grep -cE 'SecItem|SecKeychain')"
  echo
  echo "## 5. Code signature"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
  codesign -dvv "$APP" 2>&1 | grep -E 'Authority=Developer ID Application|TeamIdentifier|Runtime|^Identifier=|flags=' | sed 's/^/  /'
  fi
} > "$OUT"
cat "$OUT"
# A non-allowlisted write match fails the audit (B-14).
[ "$AUDIT_FAIL" -eq 0 ]
