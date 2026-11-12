# Changelog

## Unreleased

**A failed read no longer erases a saved account's numbers.** When a saved Claude
account's linked CLI profile (or a Codex sign-in) can't be read — signed out, a
temporary refusal, a schema change — the row keeps the last successful reading,
greyed, with the time it was seen. A window whose reset already passed shows
"Reset since last read" instead of a number, and the value is dropped on the next
refresh. These greyed values are never used for suggestions, the menu bar title,
or alerts, and are kept in memory only — nothing is restored after a restart.

**Clearer way back in.** A saved Claude account whose CLI profile is signed out
now says so, and **Details** shows the exact `claude auth login` command for that
profile with a **Copy Command** button — UsageSwitch never signs in for you. The
expired saved-login lock icon now points at the Claude tab's Sign in again.

## 2.2.2 — last items from the 2026-11 audit

**Cursor refreshes itself.** An expired Cursor sign-in used to show "sign-in expired" until
you ran `cursor-agent status` yourself. Now the app runs it once — a live browser session
renews the stored token — and only reports expired when the session really is.

**Switching survives more bad luck:**
- If macOS can't list processes, the app now refuses a switch instead of guessing Claude is
  quit — and a switch interrupted at the worst moment retries the quit and rolls back under
  the lock.
- A rollback resumed after Claude rewrote a file swaps back the right copy instead of a
  stale one.
- Half-written snapshot and backup folders are cleaned up, generation numbering can't be
  fooled by a damaged manifest, and a switch installs exactly the files the snapshot
  recorded — verified by checksum.
- A commit that fails mid-finish is reported in the result instead of being silently
  dropped, and a failed launch reports how the rollback went.
- Deleting a Codex account while its helper processes are running is stopped first;
  when the process list can't be read it refuses rather than deleting under them.

**Everything the app runs is tighter:**
- Tools the app launches (usage readers, `codex login`) start in their own process group,
  so stopping one ends the whole tree — no leftover grandchildren.
- A `launchctl` call macOS wedges on can no longer hang a switch; it gives up after 10 s.
- Lock files are opened so a planted fake can neither hang the app nor pass as real.
- An executable that other software could overwrite (group/world-writable, wrong owner)
  is never run and never shown as installed.
- Antigravity's hidden terminal starts with the same minimal environment as the other
  readers instead of inheriting the app's.
- Quitting the app now ends every vendor command still running, not just a Codex sign-in.

## 2.2.1 — fixes 2.2.0 hanging at launch

- 2.2.0 used a full CPU core right after launch and kept growing in memory, and its menu
  never opened. The menu bar title was wrapped in a periodic timeline, which made macOS
  redraw the status item without end. The title is back to how 2.1.6 drew it.
- Everything else from 2.2.0 is unchanged.

## 2.2.0 — finishing the 2026-11 audit

**Breaking (command line):**
- `--cli remove` and `--cli codex remove` now require `--yes`. Without it they exit with
  code 3 and change nothing.

**Usage:**
- Command-line tools installed with npm, bun or Volta (for example `~/.npm-global/bin/codex`)
  now run when usage is read. Before, they couldn't find `node` and showed "Usage read was
  refused".
- "May run out in …" needs real evidence: at least 2 points over 10 minutes, or one jump of
  5 points. Before, a single 1-point step in Codex's whole-number percentages projected a run-out.
- Antigravity's hidden terminal is hardened: unusual control sequences can't crash it or make
  it press Enter in the wrong place, and a Keychain timeout no longer shows the previous
  account's numbers. Pins and warnings saved under the API's spelling of a limit keep matching.
- A Cursor percentage outside 0–100 is reported as a changed response instead of being
  clamped. An Antigravity limit of an unknown kind is shown instead of dropped.
- Turning a connection off removes its numbers from `usage-snapshot.json` at once.
- A linked Claude CLI profile is also checked against the saved account's email.

**Claude and Codex accounts:**
- A switch link opened while UsageSwitch is quit opens the confirmation once the app is ready.
  A link that can't be handled says so instead of disappearing.
- If `codex-accounts.json` can't be read, the Codex tab says so and hidden homes stay hidden.
- Removing a Codex account checks its folder before anything is logged out or moved to the
  Trash. An account whose folder is already gone can still be removed.
- Codex homes that were only found on this Mac (not added) are no longer read for the Guide.

**API tab:**
- The Standard/Strong vault setting is gone. Both behaved the same; adding, showing and
  deleting a key always asks for Touch ID or your password.
- A shown key hides itself after 60 seconds or when the window closes. A key whose details
  can't be read is listed so you can delete it.
- The daily rate counts the days the logs actually cover. Anthropic, Google and xAI say their
  spend can't be estimated from local logs.

**Everyday polish:**
- No more "80% left remaining", "Next update in now" or "≈1 days left". A limit at 99.5% or
  more shows as used up, and a run-out under a minute says so.
- Account names can't contain invisible or direction-changing characters (emoji such as 👩‍💻
  still work).
- With no window or menu open, status is checked every 30 seconds instead of every 6.
- The Guide no longer writes daily observation files that nothing read, and a damaged
  learning salt resets the learning data instead of turning learning off.
- Cursor's API address can no longer be changed through an environment variable.

**Behind the scenes:**
- New tests for the network guard, every crash point of a real switch, CLI exit codes and the
  1 MiB response limit. CI adds a weekly ThreadSanitizer run, a universal release build,
  per-file coverage floors, Dependabot and actions pinned to commits.
- `scripts/audit.sh` checks all sources for writes outside the store guard, plus more secret
  patterns.
- PRIVACY.md and the READMEs now list every file UsageSwitch writes and every value it reads.

## 2.1.6 — no more constant redrawing, safer rare switch failures

- With the main window open, CPU use no longer climbs after each usage refresh. The refresh
  button's spinning animation never stopped, so the window was redrawn every frame (about
  14 seconds of CPU per minute after a few refreshes on the owner Mac). The button now
  shows a small progress indicator while a read runs.
- Switching Claude accounts is safer in rare failure cases:
  - If UsageSwitch stops right after replacing Claude's files, a sign-in that wasn't saved
    is still kept in `displaced/`.
  - If Claude's cookie database can't be read, it is treated as unknown, never as signed
    out: a switch keeps it aside, and saving a new sign-in is refused.
  - A damaged switch record now stops a switch before Claude is quit. Before, Claude was
    quit and left off on every attempt.
- A damaged switch record can be set aside, with the button under its warning in the main
  window or with `UsageSwitch --cli recover --set-aside --yes`. The record and the files it
  kept move to `displaced/journal-<date>`; nothing is deleted.

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
