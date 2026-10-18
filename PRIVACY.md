# Privacy

UsageSwitch runs entirely on your Mac.

## Network

UsageSwitch makes no network connections of its own. It has no analytics, telemetry, crash reporting, or update checks running in the background.

Your browser goes online in two cases, and only when you ask:
- **⚙︎ › Check for Updates…** opens the GitHub releases page in your browser.
- **Codex sign-in** runs Codex's own `codex login`, which opens OpenAI's sign-in page in your browser. The Codex app and CLI talk to OpenAI as they normally do.

Claude Desktop and Codex keep talking to Anthropic and OpenAI as they normally do. UsageSwitch only decides which saved sign-in they start with.

## What UsageSwitch stores

All data stays in `~/Library/Application Support/com.jaysong.usageswitch/`. UsageSwitch's own folders and files there are readable only by you (0700 and 0600). Files that Codex writes inside the Codex folders keep the permissions Codex gives them.

**Claude tab:**

| What | Contents |
|---|---|
| Saved sign-ins (`snapshots/`) | For each account, a copy of Claude Desktop's cookie database. Cookie values stay encrypted exactly as Claude stores them. Alongside it: the account and organization IDs, the email and display name when known, the session's expiry date, and file checksums. |
| Original backup (`backups/`) | A one-time copy, made before the first switch and never restored automatically, of: <ul><li>Claude's cookie database;</li><li>`config.json`, with cached tokens removed;</li><li>its web storage folders (`Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`);</li><li>its settings files: `claude_desktop_config.json` (your MCP server settings, including any API keys you put there), `ccd-session-presets.json`, `bridge-state.json`, `ant-device-registry.json` and `mcp-user-tool-toggles.json`.</li></ul> |
| Displaced sign-ins (`displaced/`) | If an account wasn't saved when you switched away from it, its cookie database and `config.json` (cached tokens removed) are kept here rather than deleted. |
| `account-names.json` | Names you gave your accounts. |
| Switch journal and lock | Used to recover an interrupted switch. |

**Codex tab:**

| What | Contents |
|---|---|
| `codex/` | One folder per account added with **Add Codex account**. Each holds: <ul><li>`home`, its Codex home. Codex's own CLI writes the account's `auth.json` there, as it does in `~/.codex`.</li><li>`app-data`, the Codex app's data for that account.</li></ul> |
| `codex-app-data/` | The Codex app's data for homes added from **Found on this Mac**. A home that already has its own Codex app-data folder in `~/Library/Application Support` keeps using that one instead. |
| `codex-accounts.json` | Names, the homes you added from this Mac, and the homes you hid. |

**Settings:** `settings.json` holds the language and display options. The window position and a few launch details are kept in macOS preferences (`com.jaysong.usageswitch`).

## What UsageSwitch reads

- **Claude Desktop:**
  - its `config.json`, for the signed-in account ID;
  - its log, to confirm which account loaded;
  - its cookie database's table layout and the session cookie's expiry date, never cookie values.
- **Processes:** the process list, to see whether Claude, its Code sessions and Codex are running. From the environment of those processes it reads only:
  - for Code sessions, the account ID and email variables;
  - for Codex, `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH`, to tell which window belongs to which account.
- **Your user LaunchAgents:** to find any agent that would relaunch Claude in the middle of a switch.
- **Codex:** each Codex home's `auth.json`, to show which account a home belongs to. It reads only:
  - the claims in the ID token: email, name, plan and account ID;
  - whether an API key is set, without reading the key itself.

  Tokens are never stored elsewhere, copied or printed.

## What UsageSwitch never does

- Decrypt cookies, or read or write the Keychain.
- Print, log, or send credentials anywhere.
- Write to `~/.claude`, to other apps' data, or to Codex homes it didn't create. Those homes change only when you sign in or out, and Codex's CLI makes the change.
- Sign you out on the server.

## Your responsibility

Saved sign-ins are as sensitive as Claude Desktop's own files. Anyone who can read your user files and unlock your login keychain could use them. Time Machine and other backups include the data folder.

To delete everything UsageSwitch stores, follow **Uninstall** in the [README](README.md#uninstall).

## Contact

Questions or concerns: [open an issue](https://github.com/deximple/usageswitch/issues). For security problems, see [SECURITY.md](SECURITY.md).
