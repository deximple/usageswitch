# Changelog

## 2.1.5 — lighter, quieter, and more accurate

- Claude account switching and saving work with a Japanese, Buddhist, ROC, Persian or
  Islamic system calendar. Before, they timed out and rolled back, or skipped the
  20-second check after Claude started.
- Much less background work. LaunchAgents and Claude's log are read again only when they
  change, at most 64 KiB is read from each file a LaunchAgent points to, and status checks
  never overlap.
- Usage reads start the Claude and Codex CLIs in one fixed, empty folder (`cli-workdir/` in
  the app's store). Before, every read left a new folder in `~/.claude/projects` (and in a
  linked profile's `projects` folder). To remove the ones earlier versions left, run this
  once; it deletes only folders that are empty:

  ```bash
  find ~/.claude/projects -mindepth 1 -maxdepth 2 -type d -path '*-T-usageswitch-claude-*' -empty -delete
  ```

  For a linked Claude CLI profile, run it again with that profile's `projects` folder.
- Each Connect dialog now says what is read, what is run and which hosts are contacted.
  Antigravity's and Gemini's dialogs now describe what happens on every refresh, so **those
  two connections ask to be allowed once more** after the update.
- The Guide and the API tab get their first usage-log reading right after launch, instead of
  about 10 minutes later.
- A usage warning is not repeated after a failed read, a restart, or "Flush learning data".
  A new limit period or another account still warns. Warned limits are kept in
  `usage-alerts.json` as opaque keys with their reset times.
- The usage-log reader catches up faster: it reads API-key accounts' logs and the newest
  files first, with a larger budget. `log-cursors.json` no longer grows without limit. While
  logs are still being read, the API tab says so instead of showing a partial spend as
  complete.

## 2.1.4 — clearer sign-in messages

- Rejected sign-ins (Cursor, Gemini, Grok, Antigravity's quota API, Devin, OpenCode Go)
  now say "Sign-in not accepted — run <command> once in Terminal" instead of
  "Usage read was refused".
- Sign-in hints use each tool's own login command: `claude auth login`, `codex login`,
  `cursor-agent login`, `grok login`, `gemini`, `agy`, `devin auth login`,
  `opencode auth login`.
- The main window shows full limit names such as "Monthly · Cursor Models".
- The README is rewritten in five languages with screenshots and a demo.

## 2.1.3 — Cursor sign-in guidance, corrected

- 2.1.2's `cursor-agent status` renewal is removed. On the owner Mac it never renewed an
  expired cursor-agent token, so it only ran a process every 10 minutes for nothing.
- An expired Cursor sign-in again says `cursor-agent login`. A browser `cursor-agent login`
  session lasts about 60 days; an API-key sign-in lasts about an hour.
- Cursor's Connect dialog keeps its own text, which says what Cursor reads and sends.

## 2.1.2 — Cursor stays readable

- When the cursor-agent sign-in has expired, UsageSwitch runs `cursor-agent status` at most
  every 10 minutes so cursor-agent renews its own sign-in, then reads Cursor usage. This
  happens only after Cursor was turned on with the dialog that says so; UsageSwitch never
  refreshes or stores the token itself.
- The expired-sign-in hint for Cursor now says `cursor-agent status`.
- Antigravity terminal tests run serially with more headroom.

## 2.1.1 — per-account usage, Suggestion and the API tab

**Usage, per account:**
- Saved Claude accounts can show their own usage: in Details, connect a Claude CLI profile
  you signed in to yourself (off by default). The profile's identity and sign-in are checked
  before and after every read; disconnecting removes the reading. "Not linked to CLI quota"
  appears only on saved accounts without a profile.
- Codex readings are attributed to the account that answered; a reading that names another
  account is dropped.
- Antigravity is a new provider: the hidden `agy /usage` screen, with the read-only quota API
  as fallback. Gemini is listed only for the official Google Gemini CLI.
- Cursor windows use the dashboard's pool names (Cursor Models, Other Models) next to the
  monthly included total; existing Auto/API pins keep working.
- Gemini can exchange its stored refresh token for an access token kept only in memory, when
  its Connect dialog allowed it; nothing is written back.
- An expired sign-in (Gemini, Grok, Antigravity, Cursor) names the CLI command to run; a
  missing sign-in names the provider to sign in to; a rejected one reads as refused.
- Status and usage no longer stall when a folder such as `~/Documents` hangs; a stuck refresh
  restarts after 10 minutes.
- `--cli usage` account ids are opaque; emails stay masked.

**Suggestion and API tab:**
- Guide mode dial (power saving, balanced, focus, urgent) and task selector, ranked with a
  model catalog bundled in the app and never fetched at runtime.
- Learning data stays in the app's store with salted account keys only (no labels, emails or
  content), is archived and deleted after 180 days, and can be flushed in Settings.
- API tab: per-vendor budgets, spend estimated from local API-key logs (Codex subscription
  sessions excluded), and a Keychain key vault that asks for device-owner authentication.
  Keys are never sent anywhere.

**Fixes:**
- A Gemini account that Google no longer serves through the Gemini CLI (individual accounts
  moved to Antigravity) says so instead of "response changed".
- UI fixtures never write to the real store.
- Flaky Antigravity terminal tests fixed.

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
