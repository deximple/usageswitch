# Changelog

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
