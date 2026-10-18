# Security

UsageSwitch handles saved sign-ins, so security reports are welcome.

## Reporting a vulnerability

Please don't open a public issue. Instead, report it privately:
1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

Include:
- what an attacker could do;
- the steps to reproduce;
- the UsageSwitch, macOS and Claude Desktop or Codex versions.

Never include real cookies, tokens, `auth.json` contents or other credentials. Redact them, or use a throwaway account.

You'll get a reply within a week. Fixes ship as a new release, and the advisory credits you unless you'd rather it didn't.

## Scope

**In scope:**
- anything that could expose, corrupt or lose a saved sign-in;
- anything that makes UsageSwitch write outside the locations listed in [PRIVACY.md](PRIVACY.md);
- anything that lets a link (`usageswitch://`) or another app switch accounts without your confirmation.

**Out of scope:** problems in Claude Desktop, Codex, or macOS itself. Please report those to Anthropic, OpenAI or Apple.
