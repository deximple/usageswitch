# Changelog

## 2.1.0 — usage guide, alerts, CLI

**Guide (new section in Priority):**
- Which account is best placed for each kind of work — long work (weekly/monthly windows),
  heavy bursts (session windows) and dedicated pools (model-scoped windows like Fable or Auto) —
  from each account's tightest fresh window.
- A "best for …" badge on the winning account's card in All Usage (hidden under 25% left),
  and a "weekly is tight — keep it to bursts" hint when the long-work pool is nearly out.

**Pace:**
- Compares each fresh read with the previous one; a window draining fast enough to run dry
  before its reset shows the projected exhaustion instead of the reset countdown.

**Alerts and threshold:**
- macOS notification when a window crosses the warn level — ⚙︎ › Usage Alerts (on by default).
- The "Running Out" level is configurable (70/80/90%) — ⚙︎ › next to it.

**CLI:**
- `UsageSwitch --cli usage` prints the app's last read as JSON, for scripts and agents.
  It only reads the snapshot file the app writes per refresh — never a vendor tool, the
  Keychain or the network.

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
