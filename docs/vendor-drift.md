# Vendor drift check

UsageSwitch never uses a vendor's token itself for Claude and Codex: it runs the vendor's own CLI and
reads what the CLI prints. When a vendor changes that output, a row in the app turns into
"update required". `scripts/vendor-drift.sh` looks for those changes on your Mac before a user does.

```bash
./scripts/vendor-drift.sh
```

It builds the `usageswitch-drift` tool, runs it, prints a Markdown report and keeps a copy in
`docs/private/vendor-drift/` (`latest.md` plus one file per run; the folder is gitignored, and from a
worktree it is the main checkout's). It exits 0 when nothing drifted, 1 when something did, 2 when
the check itself could not run, and 3 when it ran but could not compare what it is for: no tool it
reads is installed or answered, or a Codex CLI could not write its schema, so the protocol was not
compared. The report's first line says which. `--out <folder>` writes the report somewhere else.

## What it checks

| Check | How | Fails when |
|---|---|---|
| Codex app-server protocol | The installed CLI writes its own schema (`codex app-server generate-json-schema`). The part UsageSwitch depends on is compared with the frozen copy in `scripts/vendor-drift/codex-protocol.snapshot.json`. Both the CLI the app runs (Codex.app's own, when installed) and a different `codex` on `PATH` are compared. | A request the app sends, or a field its parser reads, was removed or changed type, or a request type gained a required member. Everything else that changed is listed as information. |
| Text the parsers depend on | The vendor binary is searched for the panel lines, stream fields, flags and error wording the app's parsers and collectors rely on. | One of them is gone from the binary. |
| Claude `/usage` | The app's own `ClaudeUsageCollector` runs `claude -p /usage` with the app's arguments and environment. The panel's `Current …` lines say which limits there are; each takes its numbers from its row in the answer's structured limits (`usage_report.rate_limits.limits[]`), and the rows are read alone when the panel has no such line. Each model limit the app reads is then put to the Guide's own map, `SuggestionHarnessMap`, with the bundled catalog. | The answer carries structured limits the app can't read (it falls back to the panel, or shows nothing), a `Current …` line no longer matches, the panel reports usage without one, the run did more than answer, or the app read a model limit the Guide maps to no model. A panel limit with no structured row is marked `look` (its reset time stays the panel's), and so is a structured limit of a kind the app doesn't know. |
| Claude `/usage` fields the app does not read | The structured `usage_report` holds more than the limits the app reads. All its key names (`rate_limits`, each limit and its scope, `extra_usage`) are compared with the shape kept in `ClaudeUsageReport`. | Never. A key that is new is marked `look`: it may be the limit resets an account holds, which the app can't show for Claude yet. So is an answer with no `usage_report` to compare. |
| Claude `auth status --json` | Run the way `ClaudeProfileUsageCollector` runs it; the app's parser says whether it still understands the shape. | The app's parser rejects the output. |
| Codex `account/rateLimits/read` | The app's own `CodexUsageCollector` asks `codex app-server` in `~/.codex`, the way it does on an account's first read (with reset-credit details); the app's parser reads the answer. | The app's parser rejects the answer, the server no longer knows the method, or the answer carries reset credits the parser can't read. |
| Gemini CLI sign-in client | The app's own finder looks for the client inside the installed CLI package. | It can't be found any more. |

A tool that isn't installed is left out. A read that settles nothing (signed out, timed out, offline)
is marked `look` or `skipped` and does not fail the run, unless nothing at all was compared (exit 3).

Cursor, Grok, Gemini, Antigravity, Devin, OpenCode and Copilot usage are **not** read. The app reads
those with a stored sign-in token, after you connect them; this tool never opens a credential, so it
only lists them as not checked.

## What it never does

- It does not open a credential: no `auth.json`, no Keychain item, no token file. The vendor CLIs use
  their own sign-ins, as they do for the app. `~/.codex/auth.json` is checked for existence only.
- It does not change anything at a vendor. The only Codex request sent is `account/rateLimits/read`,
  in either of the two forms the app uses (with or without reset-credit details); both only read.
  `account/rateLimitResetCredit/consume` is tracked in the snapshot for its shape and is never called —
  it spends a reset credit.
- It does not put account data in a report. Usage numbers, dates, the time zone, plan, emails,
  account or organization ids and reset-credit ids, titles or expiries are never written; what a vendor printed is shown as a shape
  (`Current week (…): N% used · resets Mon N at N:Npm (Zone)`) or as JSON key names and types.
- It writes no file itself. The script creates a temporary folder for the CLIs to start in, removes it
  afterwards, and saves the report.

## When the report says DRIFT

1. Read the finding. Protocol changes marked **read by the app** and missing text name the parser that
   depends on them.
2. Fix the parser or collector in `Sources/SwitcherCore/Usage/`, with a fixture for the new shape in
   `Tests/SwitcherCoreTests/Support/UsageFixtures.swift`.
3. If the change is one the app is fine with, or once the parser handles it, refreeze the snapshot and
   commit it with the fix:

   ```bash
   ./scripts/vendor-drift.sh --update-snapshot
   ```

   That takes the schema from the Codex CLI the app runs; `--codex <path>` takes it from another one.

Structured Claude limits the app can't read are fixed in `ClaudeUsageLimits` (in
`Sources/SwitcherCore/Usage/`). The report lists the key names and JSON types the limits now have;
until the reader handles them the app shows the panel's numbers, whose reset times move by a minute
from run to run, so the run-out forecast for Claude keeps starting over.

A model limit the Guide maps to no model is not a parser problem: the app shows the limit, but the
Guide ranks as if it weren't there, so a model whose limit is used up is still suggested. The report
leaves the limit's name out, like every other name; run `/usage` in Claude Code to see it, then add it
to `SuggestionHarnessMap` (in `Sources/SwitcherCore/Suggestion/`) with the catalog model it limits.

A new field in Claude's `usage_report` is `look`, not drift: nothing the app reads changed. The report
gives the key's name and position, never its value (a name that could be an id is shown as `*`), and
marks a name with `reset`, `grant` or `credit` in it. Run `/usage` with
`--output-format stream-json --verbose` to see what it holds, then add the key to `ClaudeUsageReport`
(in `Sources/VendorDrift/`) so it is reported once.

`CodexAppContract` (in `Sources/VendorDrift/`) lists what the app sends and reads. Its tests build an
answer from exactly those names and check that the app's parser reads every one of them, so the list
and the parser can't drift apart unnoticed. When the parser starts reading a new field, add it there.

## Running it regularly

Nothing schedules this for you, and the script sets nothing up. Vendor CLIs update themselves, so a
weekly run — and one right after a CLI update — catches most changes early. Some ways to do that, all
yours to decide:

- **launchd**: a user agent in `~/Library/LaunchAgents/` with `ProgramArguments` set to the script's
  full path and a `StartCalendarInterval` (for example Monday 09:00). Read `latest.md` afterwards, or
  have the agent notify you when the script exits with anything but 0.
- **cron**: `0 9 * * 1 cd /path/to/usageswitch && ./scripts/vendor-drift.sh >/dev/null 2>&1`
- **A scheduled Claude Code task** that runs the script and summarizes `latest.md` when it exits 1 or 3.

Treat 3 like 1: a run that compared nothing would otherwise pass every week without checking anything.

Either way the run needs your login session: the CLIs read their own sign-ins from your Keychain.
It can't run in CI, which has no vendor CLI and no sign-in.
