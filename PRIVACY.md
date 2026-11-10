# Privacy

UsageSwitch stores its account-switching data on your Mac. Optional usage connections contact the corresponding provider.

## Network

UsageSwitch has no analytics, telemetry, crash reporting, or background update checks.

**Settings > Usage Connections** offers only detected or previously connected providers. Cursor, Grok, Gemini, Antigravity, Devin and OpenCode usage connections are off by default. Enabling one explains the local sign-in read and read-only HTTPS requests. Disabling it cancels further collection and removes its displayed quota; an already-authorized request may finish, but its obsolete result is discarded.

Saved Claude Desktop accounts have a separate, default-off **Connect usage via CLI profile…** action in that account's details. The user chooses a profile directory they signed in to themselves, and an explicit Enable confirmation creates that account's binding. This does not use or grant the default `claude` CLI row or another provider's consent. Disconnect removes the binding and its displayed reading; it does not delete, sign out of, or modify the profile. A read runs the official Claude CLI's `claude auth status --json` and `/usage` with `CLAUDE_CONFIG_DIR` set to the selected profile. The CLI reads its own saved sign-in for that profile, which may involve the macOS Keychain, and may refresh its own token or update its own config files. UsageSwitch never runs a task or model request, signs in or out, or switches accounts. The same account and organization must be confirmed from both profile identity and CLI auth status before and after `/usage`; otherwise no quota is shown.

| Connection | Local sign-in source | Allowed HTTPS host |
|---|---|---|
| Cursor | Cursor's Keychain entry, then its bounded `auth.json` fallback | `api2.cursor.sh` |
| Grok | The Grok CLI sign-in file | `cli-chat-proxy.grok.com` |
| Gemini | Gemini CLI Keychain item (`gemini-cli-oauth` / `main-account`), then bounded flat `~/.gemini/oauth_creds.json`; access token and expiry, plus the refresh token only under the refresh disclosure | `cloudcode-pa.googleapis.com`, `oauth2.googleapis.com` (token exchange) |
| Antigravity | Hidden `agy` PTY `/usage` screen; read-only quota API uses agy's Keychain item (`gemini` / `antigravity-acp`), or the old jetski access-token file when that item is absent | `oauth2.googleapis.com`, `cloudcode-pa.googleapis.com` |
| Devin | Devin CLI credentials and a local CLI version probe | `server.codeium.com` |
| OpenCode Go | The `opencode-go` entry in OpenCode's `auth.json` | `opencode.ai` |

Suggestion model data is bundled with the app as a frozen snapshot; it is not fetched at runtime.

Credentials stay in memory and are not logged or saved by the collectors. Requests use an ephemeral session, reject redirects, and bound response bodies to 1 MiB. Gemini may make up to three HTTPS requests (one memory-only token exchange plus two quota requests); Antigravity may make a token exchange and two quota requests; the others make one. Gemini's forced encrypted-file storage mode is unsupported and is treated as no sign-in. Its legacy OAuth file is used when the Keychain lookup fails or returns no item; only `access_token` and `expiry_date` are read, and expired credentials are reported as an expired sign-in — unless the Gemini connection was granted under the refresh disclosure, in which case the stored refresh token and the installed Gemini CLI's own sign-in client (read from its package) are exchanged for a temporary access token held only in memory until 60 seconds before expiry; nothing is written back, any response refresh token is ignored, and without that grant an expired token stays an expired sign-in. Cursor's stored cursor-agent token is a JWT; when its `exp` has passed, UsageSwitch sends no request and shows an expired sign-in (`cursor-agent login`). It never refreshes or stores the token. A browser `cursor-agent login` session lasts about 60 days; API-key sign-ins about an hour. For Antigravity, the app runs `agy` from the user's home folder in a hidden PTY to parse `/usage`, at most once every 9 minutes. `agy` starts with its normal configuration, which may include MCP servers configured by the user. UsageSwitch never answers agy's prompts, including the folder-trust prompt; if agy asks, it sends no input. On every refresh, whether or not agy's screen was read, it also reads agy's `gemini` / `antigravity-acp` Keychain item to notice an account change and uses its refresh token to obtain a short-lived access token kept in memory and cached only until 60 seconds before expiry (any refresh token in the response is ignored), then calls the read-only quota API. When the screen can't be read, the numbers from that API are shown instead. The token is not saved, and UsageSwitch does not write to agy's configuration. macOS may show a Keychain “allow” prompt for the Keychain item. No model requests or tasks are sent. Cursor displays the monthly included total plus the dashboard pools “Cursor Models” (`autoPercentUsed`) and “Other Models” (`apiPercentUsed`) from its current-period usage response; Grok Bot and on-demand spending are not read, and no plan-details request is made. The collectors do not sign in or out, switch accounts, or submit model-generation tasks.

These provider-specific usage endpoints are experimental integration paths, not a promise of stable public APIs. Antigravity's screen and quota flow are based on owner-verified agy 1.5.x behavior; private API details may change. 2.1.x releases were checked against the maintainer's own accounts before shipping; a different plan, CLI version or region can still behave differently. Missing usage credentials do not prove that a CLI is logged out: it may use an authentication mode whose quota is not supported.

Your browser goes online in two cases, and only when you ask:
- **⚙︎ › Check for Updates…** opens the GitHub releases page in your browser.
- **Codex sign-in** runs Codex's own `codex login`, which opens OpenAI's sign-in page in your browser. The Codex app and CLI talk to OpenAI as they normally do.

Claude Desktop and Codex keep talking to Anthropic and OpenAI as they normally do. UsageSwitch only decides which saved sign-in they start with.

## What UsageSwitch stores

All data stays in `~/Library/Application Support/com.jaysong.usageswitch/`, with two exceptions: API keys you put in the API key vault are stored in the macOS Keychain, and the app's macOS preferences hold a few interface details (the window position, the last open tab, and when launch-at-login was turned on). UsageSwitch's own folders and files there are readable only by you (0700 and 0600). Files that Codex writes inside the Codex folders keep the permissions Codex gives them.

**Claude tab:**

| What | Contents |
|---|---|
| Saved sign-ins (`snapshots/`) | For each account, a copy of Claude Desktop's cookie database. Cookie values stay encrypted exactly as Claude stores them. Alongside it: the account and organization IDs, the email and display name when known, the session's expiry date, and file checksums. |
| Original backup (`backups/`) | A one-time copy, made before the first switch and never restored automatically, of: <ul><li>Claude's cookie database;</li><li>`config.json`, with cached tokens removed;</li><li>its web storage folders (`Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`);</li><li>its settings files: `claude_desktop_config.json` (your MCP server settings, including any API keys you put there), `ccd-session-presets.json`, `bridge-state.json`, `ant-device-registry.json` and `mcp-user-tool-toggles.json`.</li></ul> |
| Displaced sign-ins (`displaced/`) | If an account wasn't saved when you switched away from it, its cookie database and `config.json` (cached tokens removed) are kept here rather than deleted. |
| `account-names.json` | Names you gave your accounts. |
| `cli-workdir/` | Two empty folders (`claude/`, `codex/`). UsageSwitch starts the vendor CLIs there when it reads usage, so a CLI that records its working directory records one fixed entry. |
| `usage-alerts.json` | The usage limits you were already warned about, as opaque row keys (for example `codex:m-1a2b3c4d/weekly/`) with the warning level and the reset time of each warned limit, so a restart does not repeat a warning. Limits without a reset time are remembered only until the app quits. No name or email. |
| Switch journal and lock | Used to recover an interrupted switch. |

**Codex tab:**

| What | Contents |
|---|---|
| `codex/` | One folder per account added with **Add Codex account**. Each holds: <ul><li>`home`, its Codex home. Codex's own CLI writes the account's `auth.json` there, as it does in `~/.codex`.</li><li>`app-data`, the Codex app's data for that account.</li></ul> |
| `codex-app-data/` | The Codex app's data for homes added from **Found on this Mac**. A home that already has its own Codex app-data folder in `~/Library/Application Support` keeps using that one instead. |
| `codex-accounts.json` | Names, the homes you added from this Mac, and the homes you hid. |

**Settings:** `settings.json` holds the language, display options, usage-connection grants, and any explicitly enabled saved-Claude-account profile bindings (account/organization IDs and the canonical profile path), not provider tokens. The profile path is not included in the usage snapshot. The window position and a few launch details are kept in macOS preferences (`com.jaysong.usageswitch`).

## What UsageSwitch reads

- **Claude Desktop:**
  - its `config.json`, for the signed-in account ID;
  - its log, to confirm which account loaded;
  - its cookie database's table layout and the session cookie's expiry date, never cookie values.
- **Processes:** the process list, to see whether Claude, its Code sessions and Codex are running. From the environment of those processes it reads only:
  - for Code sessions, the account ID and email variables;
  - for Codex, `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH`, to tell which window belongs to which account.
- **Your user LaunchAgents:** each plist (up to 1 MiB) and any script it points at (text files under 64 KiB), to find any agent that would relaunch Claude in the middle of a switch. During a switch such an agent is paused with `launchctl bootout` and restored with `launchctl bootstrap`; the plists themselves are never edited.
- **Codex:** each Codex home's `auth.json`, to show which account a home belongs to. It reads only:
  - the claims in the ID token: email, name, plan and account ID;
  - whether an API key is set, without reading the key itself.

  These identity reads do not write tokens elsewhere or print them.
- **Usage reads:** Claude's default row uses CLI `/usage`. A saved Claude account can separately use an explicitly enabled CLI profile: UsageSwitch reads only the account and organization IDs from that profile's `.claude.json`, then runs `claude auth status --json` and `/usage` with `CLAUDE_CONFIG_DIR` set to the profile. The profile identity and CLI auth status are checked before and after `/usage`, and the profile directory is revalidated; any identity, organization, auth-status, or directory change suppresses quota. `.claude.json` is rewritten by Claude CLI, so identity fields—not a whole-file fingerprint—are compared. The vendor CLI reads its own saved sign-in (possibly through macOS Keychain) and may refresh its own token or update its own config files. Codex uses `codex app-server` for listed ChatGPT sign-ins, in the vendor's own home. Optional connections use the read paths listed above. Antigravity's PTY output is parsed in memory; the account line and raw screen are not stored. The latest reading in `usage-snapshot.json` includes opaque provider/account references, quota windows, plan, state, timestamps and tool version. Account-backed IDs and references are presentation-order ordinals, and UUID-shaped values in free-text fields are redacted. Labels are email-masked on write and load regardless of the app's show-emails setting. It contains no profile path, provider credential, raw HTTP body or opaque login identity marker; the marker used for safe in-memory comparisons is never persisted. `UsageSwitch --cli usage` prints that last-collected snapshot without running vendor tools. Editing a display name updates the account registry and current UI, not the snapshot or its collection timestamp; the next normal refresh picks up the new name.
- **Claude and Codex usage logs:** From `~/.claude/projects/*/*.jsonl` and the saved Claude profile project directories, UsageSwitch reads only Claude's top-level `type`, `timestamp`, `effort`, `perTurnEffort`, and `version`; `message.id` (for deduplication; only its SHA-256 is kept, in `log-cursors.json`, until the next read — the ID itself is never stored); `message.model`; and `message.usage.input_tokens`, `message.usage.output_tokens`, `message.usage.cache_read_input_tokens`, and `message.usage.cache_creation_input_tokens`. From `~/.codex/sessions/**/rollout-*.jsonl` and the Codex profile homes already known to the app, it reads only `type`; `timestamp`; `payload.rate_limits.plan_type` (only to tell a subscription session from an API-key one, stored as yes or no); `payload.model`, `payload.effort`, `payload.collaboration_mode.settings.model`, `payload.collaboration_mode.settings.reasoning_effort`, `payload.type`, `payload.info.last_token_usage.input_tokens`, `payload.info.last_token_usage.cached_input_tokens`, `payload.info.last_token_usage.output_tokens`, `payload.info.last_token_usage.reasoning_output_tokens`, and `payload.cli_version`. Conversation content is never read or stored. What is kept from these logs is `log-usage-*` (per day: model, effort, token counts, tool version and last-used time, under a salted account key) and `log-cursors.json` (for each log file: the SHA-256 of its path, its inode and how far it has been read; entries are dropped 45 days after the file was last read). If `log-cursors.json` cannot be read, it is set aside as `log-cursors.json.unreadable-*` and the stored usage is rebuilt from the logs.
- **Suggestion learning:** bounded local JSONL and snapshot files contain salted HMAC account keys, provider/window identifiers, usage percentages and reset times, mode/task changes, and Guide events. They never contain account labels, emails, raw account references, or tokens. Raw files are retained for 14 days, then archived; archives are compressed after 30 days and deleted after 180 days. “Flush learning data” removes these files and rotates the salt while keeping mode and task preferences.
- **API tab:** budgets and optional API-key nicknames/creation metadata stay local. API keys are stored only in macOS Keychain; they are never sent anywhere because no verified read-only balance endpoint exists. Spend estimates use token counts from local CLI logs only for accounts marked as API-key authentication, priced from the bundled model snapshot. A Codex session whose log carries a ChatGPT plan marker is excluded, so sessions from before a switch to an API key do not count. They are labeled estimates and do not query providers for balances.
- **Usage alerts:** when enabled, a trustworthy window crossing the warning level may post a macOS notification with the masked label and percentage. Unknown or stale readings are not presented as healthy quota.

## What UsageSwitch never does

- Decrypt cookies.
- Read or write the Keychain, except for enabled usage connections (Cursor, Gemini CLI, and Antigravity's agy item) and API keys you store or manage in the API key vault.
- Print or log usage credentials, or forward them to unrelated services. An enabled usage connection sends its credential only to the corresponding allowlisted provider host.
- Send API keys anywhere. There is no verified read-only balance endpoint, so API keys are never used for network requests.
- Write to `~/.claude`, to Claude CLI profiles, to other apps' data, or to Codex homes it didn't create. Those Codex homes change only when you sign in or out, and Codex's CLI makes the change. For an explicitly connected Claude profile, the official Claude CLI itself may refresh its token or update its own config files as described above.
- Sign you out on the server.

## Your responsibility

Saved sign-ins are as sensitive as Claude Desktop's own files. Anyone who can read your user files and unlock your login keychain could use them. Time Machine and other backups include the data folder.

To delete everything UsageSwitch stores, follow **Uninstall** in the [README](README.md#uninstall).

## Contact

Questions or concerns: [open an issue](https://github.com/deximple/usageswitch/issues). For security problems, see [SECURITY.md](SECURITY.md).
