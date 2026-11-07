# UsageSwitch

See remaining AI usage. Switch Claude/Codex accounts when you choose.

A local-first macOS menu-bar app: a compact usage list for your detected tools and
registered accounts, plus the existing Claude sign-in switcher and per-account Codex homes.

[한국어](README.ko.md) · Download: [latest release](https://github.com/deximple/usageswitch/releases/latest) · [Privacy](PRIVACY.md) · [Changelog](CHANGELOG.md)

<p><img src="docs/screenshots/usage-quiet-list.png" width="420" alt="UsageSwitch native usage list, demo data"></p>
<sub>Screenshot: development preview, synthetic demo data — no real accounts or quotas shown.</sub>

The app is in English, 한국어, 简体中文, 日本語 and Español (follows the system language;
change it in ⚙︎ › Language). Version 2.1.0.

## Requirements

- macOS 15 or later — Apple silicon and Intel.
- Published releases are signed with a Developer ID and notarized by Apple.
  Development previews are ad-hoc signed and not notarized.
- For account switching: Claude Desktop and/or the Codex desktop app. Usage-only
  environments can use the supported local CLIs without those apps.

## Install

1. Download `UsageSwitch-<version>.dmg` (or `.zip`) from the [latest release](https://github.com/deximple/usageswitch/releases/latest).
2. Open it and drag **UsageSwitch** to **Applications**.
3. Open UsageSwitch — it lives in the menu bar; opening it from Finder also shows its window.

## How it works

The usage list is **environment-first**: it shows only providers that are installed or
have registered accounts — detected CLI executables and `.app` directories, never a fixed
seven-provider catalog. Filesystem-only discovery never runs candidates; the caller's
PATH order wins. With Claude, Codex and Cursor present you see exactly three; a Claude-only
setup shows Claude and its saved accounts. Absent providers run no credential reads or
collection jobs.

The compact 360-pt menu shows the **percent remaining** (not used) of each limit window
with a short reset like `2d 3h`. Up to three trustworthy fresh windows per account;
"More limits" opens the detail window with all of them. The optional **Guide** offers at
most one conservative next-account candidate from comparable subscription windows — it
never switches or launches anything.

**Details** opens a window per account to inspect full limits, reset times, source and
version — no provider or account auth actions happen there. Saved Claude/Codex
**display names** can be edited using the existing account registry; renaming updates
the list and Guide immediately without recollecting usage. A name edit never changes
sign-in, email, or plan, and the CLI snapshot keeps the last collected reading until
the next normal refresh.

Claude CLI quota is never attributed to saved Claude App accounts — they are separate
environments, and App accounts without quota show "not linked" instead of invented numbers.
API profiles stay marked `API` — never treated as subscription balances.

## Providers

| Provider | Read path | Availability |
|---|---|---|
| Claude Code | CLI `/usage` | Current CLI sign-in; refused when managed Claude settings apply |
| Codex | `app-server` → `account/rateLimits/read` | Listed ChatGPT homes; API-key profiles don't report subscription quota |
| Cursor | Current-period usage endpoint (plan total only) | Opt-in; may read its own Keychain entry, else bounded auth file |
| Grok | CLI usage endpoint | Opt-in; **experimental** |
| Gemini | Code Assist project/quota | Opt-in; model/input/output limits kept separate |
| Devin | CLI-compatible user status | Opt-in; requires a supported CLI version |
| OpenCode Go | Go usage endpoint | Opt-in; only the Go plan, not an OpenCode total |

The five optional providers are all **off by default**. Enabling one explains that
UsageSwitch reads that provider's local sign-in and sends read-only usage requests to a
fixed allowlist over HTTPS — no redirects, bounded responses, one request per refresh
(Gemini may make two). Those optional-provider tokens are never saved or
logged by the usage collectors. The newer connectors are **experimental** — private
endpoints may change and live-account compatibility is not yet verified. Usage
collection never signs in or out, refreshes tokens, switches accounts, or runs model
tasks — and there are no costs, balances, or model requests. There is no analytics,
telemetry, or background auto-updater.

## Account actions

- **Claude tab** — save each account's Claude Desktop sign-in once, then switch in one
  click. A switch quits Claude normally (never force-quits), asks first if Code sessions
  are running, then replaces the local sign-in, verifies it in Claude's log, and rolls
  back on any failure. Nothing signs out on the server.
- **Codex tab** — one Codex home per account, each opened in its own window. Sign-in
  always goes through Codex's own CLI; `auth.json` is never copied or swapped between
  homes (Codex refresh tokens are single-use). Removing an added home signs it out, so
  removal is a deliberate action — the standard `~/.codex` can't be removed.
- Both are **user-triggered** actions — UsageSwitch quits/opens apps only when you ask,
  never because of a quota reading.

## Command line (read-only examples)

```bash
APP=/Applications/UsageSwitch.app/Contents/MacOS/UsageSwitch
"$APP" --cli status        # Claude accounts + active account + Code sessions
"$APP" --cli codex status  # Codex homes
"$APP" --cli usage         # last usage read as JSON — reads only the persisted
                           # masked snapshot; no live collection, may lag a
                           # name edit until the next normal refresh
```

Run `"$APP" --cli` with no command for the full list.

## Privacy and safety

Display-only usage: no switches, launches, or sign-ins happen because of a limit.
Optional-provider reads happen only after explicit opt-in and their tokens are never
persisted or logged by the collectors; Claude sign-in snapshots are deliberately stored
encrypted for switching. No raw HTTP or credential values appear in the UI. Full
sources, destinations and write boundaries: [PRIVACY.md](PRIVACY.md).

## Build and contribute

Requires Xcode 16+ (Swift 6) on macOS 15+.

```bash
swift build
./scripts/test.sh              # tests + coverage report
./scripts/bundle.sh            # universal bundle; Developer ID when available,
                                # ad-hoc fallback for local builds
python3 scripts/check-l10n.py  # localization key check
```

`scripts/notarize.sh` submits to Apple's notary service using an existing
`NOTARY_PROFILE` keychain profile — a release cannot use the ad-hoc fallback.

## Limitations

- Switching depends on Claude Desktop's internal files; a Claude update that changes
  them fails safely and rolls back until UsageSwitch is updated.
- A saved Claude sign-in can expire or be revoked and require a fresh sign-in.
- Codex homes that keep sign-in in the Keychain (`cli_auth_credentials_store = "keyring"`)
  may show as signed out.
- Optional provider connectors are experimental; live-account compatibility is unverified.
- No costs, balances, or per-model spending — quota is what each provider reports.

## Uninstall

1. Optional: to sign out of Codex accounts you added, remove them in the Codex tab before quitting.
2. Turn off ⚙︎ › **Open at Login**, quit UsageSwitch and move it to the Trash.
3. Optional: delete its data folder (`~/Library/Application Support/com.jaysong.usageswitch/`)
   — it holds saved sign-ins, settings and the Codex homes added in UsageSwitch, so keep
   anything you need first.

## Acknowledgments

An independent open-source project — not affiliated with or endorsed by Anthropic,
OpenAI, Cursor, xAI, Google, Cognition or Sourcegraph; product names belong to their
owners. Related community switchers: [claudepot-app](https://github.com/xiaolai/claudepot-app),
[claude-desktop-accounts](https://github.com/5eanxlee/claude-desktop-accounts),
[Swivel](https://github.com/jspanji/Swivel), [claude-graft](https://github.com/aaditya-v-more/claude-graft).

## License

MIT — see [LICENSE](LICENSE).
