#!/bin/bash
# Gate 6 audit: secret patterns (counts only, never values), store permissions, writes outside SafeFS,
# preference and Keychain writes, keychain API imports. Writes docs/evidence/audit.txt in the main
# checkout, which outlives a worktree.
set -uo pipefail
cd "$(dirname "$0")/.."
MAIN="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && MAIN="$(dirname "$MAIN")" || MAIN="$PWD"
EVIDENCE="$MAIN/docs/evidence"
OUT="$EVIDENCE/audit.txt"
SOURCE_ONLY=0
for arg in "$@"; do case "$arg" in --source-only) SOURCE_ONLY=1 ;; esac; done
mkdir -p "$EVIDENCE"
# Written next to the report and moved over it at the end, so a run that dies keeps the last report.
TMP_OUT="$(mktemp "$EVIDENCE/.audit.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT
# A grep line is path:line:text; this is true when the text is only a comment.
is_comment() { [[ "$1" =~ ^[^:]+:[0-9]+:[[:space:]]*// ]]; }
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
  echo "docs/evidence (text files): $(count "$EVIDENCE")"
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
  WRITE_RE='\.(createDirectory|removeItem|moveItem|copyItem|createFile|replaceItem|trashItem|createSymbolicLink|setAttributes)\(|\.write\(to(File)?:|FileHandle\(forWritingTo|forUpdating|O_CREAT|O_WRONLY|O_RDWR|\b(chmod|fchmod|ftruncate|truncate|symlink)\(|[^.a-zA-Z_](rename|renamex_np|unlink|rmdir|mkdir)\('
  # Allowlist: <file>:<reason>. Entries are matched as path suffixes.
  # Every allowed match is a write that still goes through SafeFS checks or is a
  # deliberately raw open with O_NOFOLLOW on an allowlisted path.
  allow() {
    case "$1" in
      *CodexAppControl.swift:*trashItem*) return 0 ;;          # own folder to Trash after fs.check
      *Switcher.swift:*O_CREAT*|*Switcher.swift:*lockFile*O_RDWR*) return 0 ;;  # lock file: O_NOFOLLOW
      *LockedStoreFile.swift:*O_CREAT*) return 0 ;;            # same lock pattern
      *SuggestionStorage.swift:*O_CREAT*) return 0 ;;          # append-only suggestion log, O_NOFOLLOW
      *SuggestionStorage.swift:*fchmod*) return 0 ;;           # the same descriptor's 0600
      *SuggestionStorage.swift:*ftruncate*|*SuggestionStorage.swift:*O_WRONLY*O_NOFOLLOW*) return 0 ;;  # undoing that append, O_NOFOLLOW
      *UsageProcessRunner.swift:*\"/dev/null\",\ O_WRONLY*) return 0 ;;  # a child's stderr goes to /dev/null
      */ClaudeSwitcher/App.swift:*png.write*) return 0 ;;      # --snapshot dev PNG dump
      *fs.createDirectory*|*fs.write*|*fs.remove*|*fs.move*|*fs.copy*|*fs.swap*|      *fs.restrictPermissions*|*fs.check*|*fs.isAllowed*|*fs.createSymbolicLink*) return 0 ;;  # fs. goes through SafeFS
      *afterOperation*) return 0 ;;                            # test-seam comment/member in SafeFS users
      *sandbox.fs.*) return 0 ;;
    esac
    return 1
  }
  RAW=$(grep -rnE --include='*.swift' "$WRITE_RE" Sources/ \
        | grep -v 'SafeFS\.swift' | grep -v 'ModelTFSnapshot' | grep -v 'Strings+' \
        | grep -vE 'func (rename|renamex_np|unlink|rmdir|mkdir|chmod|fchmod|ftruncate|truncate|symlink)\s*\(')
  # Collected with real newlines and printed with %s: a backslash in a source line stays as it is.
  UNALLOWED=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    is_comment "$line" && continue
    allow "$line" || UNALLOWED="$UNALLOWED$line"$'\n'
  done <<< "$RAW"
  UNCOUNT=$(printf '%s' "$UNALLOWED" | grep -c . || true)
  echo "unallowed matches: $UNCOUNT (expect 0; any line here is a write outside SafeFS)"
  printf '%s' "$UNALLOWED" | sed 's/^/  /'
  AUDIT_FAIL="$UNCOUNT"
  echo "SQLite read-write opens (must be preceded by fs.check on a store/staged path):"
  grep -nB2 'mode: .readWrite' Sources/SwitcherCore/*.swift | grep -E 'fs.check|readWrite' | sed 's/^/  /'
  echo
  echo "## 3b. Claude launch/URL paths outside SystemClaudeAppControl (all of Sources/, expect 0)"
  # Allowed: the Codex tab opening its sign-in page and "Check for Updates…" opening the releases page (https) in the browser.
  LAUNCHES=$(grep -rnE --include='*.swift' 'NSWorkspace\.shared\.(open|openApplication)|openApplication\(' Sources/ \
             | grep -v 'ClaudeAppControl.swift' | grep -v 'NSWorkspace.shared.open(signInLink)' \
             | grep -v 'NSWorkspace.shared.open(ProductInfo.releasesURL)' | grep -vE '^[^:]+:[0-9]+:\s*//')
  LAUNCHCOUNT=$(printf '%s' "$LAUNCHES" | grep -c . || true)
  echo "matches: $LAUNCHCOUNT"
  printf '%s\n' "$LAUNCHES" | grep . | sed 's/^/  /'
  AUDIT_FAIL=$((AUDIT_FAIL + LAUNCHCOUNT))
  echo "allowed (browser sign-in page): $(grep -nc 'NSWorkspace.shared.open(signInLink)' Sources/ClaudeSwitcher/CodexModel.swift)"
  echo "allowed (releases page, Check for Updates…): $(grep -nc 'NSWorkspace.shared.open(ProductInfo.releasesURL)' Sources/ClaudeSwitcher/SettingsMenu.swift)"
  echo
  echo "## 3c. Preference and Keychain writes (all of Sources/, only those PRIVACY.md lists)"
  allow_saved() {
    case "$1" in
      */ClaudeSwitcher/CodexViews.swift:*UserDefaults.standard.set*tab.rawValue*) return 0 ;;                 # the last tab
      */ClaudeSwitcher/SwitcherModel.swift:*UserDefaults.standard.set*launchAtLoginEnabledAtKey*) return 0 ;; # when Open at Login was turned on
      */ClaudeSwitcher/App.swift:*defaults.set*lastLoginLaunchKey*) return 0 ;;                               # the login a launch stayed in the menu bar for
      */ClaudeSwitcher/App.swift:*setFrameAutosaveName*) return 0 ;;                                          # the window position
      */Usage/APIKeyVault.swift:*SecItemAdd*|*/Usage/APIKeyVault.swift:*SecItemDelete*) return 0 ;;            # the API key vault
    esac
    return 1
  }
  SAVED=$(grep -rnE --include='*.swift' 'UserDefaults(\.standard)?\.(set|removeObject|setValue|register)\(|UserDefaults\(suiteName|[^.a-zA-Z_]defaults\.(set|removeObject|setValue|register)\(|SecItem(Add|Update|Delete)\(|@AppStorage|[Ff]rameAutosaveName' Sources/)
  UNSAVED=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    is_comment "$line" && continue
    allow_saved "$line" || UNSAVED="$UNSAVED$line"$'\n'
  done <<< "$SAVED"
  UNSAVEDCOUNT=$(printf '%s' "$UNSAVED" | grep -c . || true)
  echo "unlisted matches: $UNSAVEDCOUNT (expect 0)"
  printf '%s' "$UNSAVED" | sed 's/^/  /'
  AUDIT_FAIL=$((AUDIT_FAIL + UNSAVEDCOUNT))
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
} > "$TMP_OUT"
chmod 644 "$TMP_OUT"
mv -f "$TMP_OUT" "$OUT"
cat "$OUT"
# A write, launch or saved value outside its allowlist fails the audit (B-14, S-3).
[ "$AUDIT_FAIL" -eq 0 ]
