# Changelog

## 2.1.0 — environment-first usage, details and consent

**Quiet List:**
- The usage list is environment-first: detected installations and registered accounts
  only, never a fixed catalog — absent providers run no reads or jobs.
- Two-line identity rows (name, lock, CLI/App badge, plan/API tag, masked email) with a
  per-account Details window for full limits, resets, source and version.
- Compact list shows at most three trustworthy fresh windows per account; "More limits"
  opens the full set in Details.
- Saved Claude/Codex display names are editable in Details through the existing account
  registry — updates propagate without recollecting usage.
- Appearance: System / Light / Dark; five languages.

**Consent-gated optional providers (all off by default):**
- Grok, Gemini, Devin and OpenCode Go read a local sign-in only after explicit opt-in,
  then send bounded read-only HTTPS to a fixed allowlist. Experimental — private
  endpoints may change and live-account compatibility is unverified. Cursor keeps its
  own opt-in flag.

**Guide, pace, alerts:**
- The optional Guide offers at most one conservative next-account candidate.
- Pace marks a window draining fast enough to run dry before its reset.
- macOS notification when a window crosses the warn level; threshold is configurable.
- `--cli usage` prints the last read as JSON — reads only the persisted masked snapshot.

**CLI detection:**
- The caller's PATH order wins; npm, bun and Volta user directories are searched;
  discovery never executes a candidate.

**Refinement (unslop polish):**
- Consistent spacing scale, aligned provider headings and a neutral secondary
  Details action in the compact list.

**Accessibility and fixes:**
- Account-scoped accessibility labels on every Details and More-limits control.
- Gemini model/input/output limits are labelled distinctly in compact rows.

## 2.0.0 — usage

**Usage tab (new first tab):**
- One view for every account's usage: a Priority list (Pinned, Running Out, Used Up) and
  All Usage, one card per account with a bar per window.
- Right-click any row to pin it to Priority; pins are saved.
- The menu bar can show the most constrained window (e.g. "Weekly 75%") — ⚙︎ › Show Usage in Menu Bar.
- Refreshes every 5 minutes, on demand, and right after a window resets.

**Channels (all read-only, all through the vendors' own tools):**
- Claude Code: the `claude` CLI's `/usage`, for the default CLI sign-in. Nothing is read when the
  machine has managed Claude settings.
- Codex: `codex app-server` per listed ChatGPT sign-in (API-key accounts don't report usage).
- Cursor: opt-in only (⚙︎ › Cursor Usage…). Reads Cursor's sign-in and calls Cursor's API once per
  refresh; the token is never saved.
- Usage is display-only: nothing switches, launches or signs out because of a limit.

## 1.5.0 — first public release

**Claude tab:**
- Save each account's Claude Desktop sign-in once, then switch between them.
- Each switch is journaled, verified in Claude's log and rolled back on failure.
- Running Code sessions are detected before a switch, and UsageSwitch asks first.
- Auto-relaunch LaunchAgents are paused during a switch and restored afterwards.

**Codex tab:**
- One Codex home per account, each opened in its own window.
- Add, sign in again, rename and remove accounts. Sign-in always goes through Codex's own CLI.
- Existing Codex homes found on this Mac are suggested, never used until you add them.

**Everywhere:**
- Account names you can edit; masked emails, revealed by click or by a setting.
- Settings menu (⚙︎) with:
  - language: English, 한국어, 简体中文, 日本語, Español;
  - Open at Login;
  - menu bar title options;
  - Check for Updates….
- JSON command-line interface and a `usageswitch://switch` link.
- Universal app (Apple silicon and Intel), signed with a Developer ID and notarized by Apple.
- Finds Claude and Codex in `/Applications` or `~/Applications`.
