#!/usr/bin/env python3
"""Redacted summary of `UsageSwitch --cli usage` output for local acceptance.

Reads the CLI's JSON envelope on stdin and prints only provider, per-provider slot number,
state/problem, authentication, window shape and percentages. Account ids, labels,
plans and timestamps are never printed. With --expect, each provider's count of
distinct rows that report at least one fresh window is compared with the expected count.

    UsageSwitch --cli usage | python3 scripts/acceptance-summary.py \
        --expect claude=3,codex=2,opencode=1,gemini=1,cursor=1,devin=1,grok=1

Exit 0 only when the snapshot is present, recent, privacy-clean and every expectation holds.
The email scan covers every script and is stricter than the app's Latin-only masker.
"""
import argparse
import json
import math
import re
import sys
from datetime import datetime, timezone

# Deliberately broader than Privacy.emailPattern: any script, and any address whose local part
# carries no mask bullet counts as unmasked.
EMAIL = re.compile(r"([^\s@]+)@[\w-]+(?:\.[\w-]+)+")
# The shapes Privacy.maskEmail produces: all bullets, or two characters, bullets, three characters.
MASKED_LOCAL = re.compile(r"•+|[^•]{2}•+[^•]{3}")


def is_masked(local):
    return MASKED_LOCAL.fullmatch(re.split(r"[(<\[{\"':,;]", local)[-1]) is not None
FORBIDDEN_KEYS = {"identityKey", "token", "accessToken", "refreshToken", "apiKey", "key",
                  "cookie", "email", "authorization", "body", "tokenAccountId"}
MAX_AGE_SECONDS = 600


def parse_date(value):
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return date.replace(tzinfo=timezone.utc) if date.tzinfo is None else date


def percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and 0 <= value <= 100 else None


def forbidden_keys(value, found):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_KEYS:
                found.add(key)
            forbidden_keys(child, found)
    elif isinstance(value, list):
        for child in value:
            forbidden_keys(child, found)
    return found


def unmasked_strings(value):
    if isinstance(value, str):
        return sum(1 for match in EMAIL.finditer(value) if not is_masked(match.group(1)))
    if isinstance(value, dict):
        return sum(unmasked_strings(k) + unmasked_strings(v) for k, v in value.items())
    if isinstance(value, list):
        return sum(unmasked_strings(v) for v in value)
    return 0


def fresh_windows(account, now):
    read_at = parse_date(account.get("readAt"))
    if account.get("state") != "ok" or read_at is None:
        return []
    if not 0 <= (now - read_at).total_seconds() <= MAX_AGE_SECONDS:
        return []
    out = []
    for window in account.get("windows") or []:
        if not isinstance(window, dict) or percent(window.get("usedPercent")) is None:
            continue
        resets = parse_date(window.get("resetsAt"))
        if resets is not None and resets <= now:
            continue
        out.append(window)
    return out


def shape(window):
    used = percent(window.get("usedPercent"))
    scope = f"/{window['scope']}" if isinstance(window.get("scope"), str) else ""
    shown = f"{round(used, 1)}%used" if used is not None else "invalid"
    return f"{window.get('kind')}{scope}@{window.get('durationMinutes')}m={shown}"


def parse_expect(text):
    expected = {}
    for part in filter(None, (text or "").split(",")):
        provider, _, count = part.partition("=")
        expected[provider.strip()] = int(count)
    return expected


def summarize(doc, expect, now, out):
    if not isinstance(doc, dict) or doc.get("ok") is not True or not isinstance(doc.get("result"), dict):
        code = doc.get("error", {}).get("code") if isinstance(doc, dict) and isinstance(doc.get("error"), dict) else None
        out(f"snapshot: unavailable code={code if isinstance(code, str) and code.isidentifier() else '-'}")
        return 2
    snapshot = doc["result"]
    accounts = [a for a in snapshot.get("accounts") or [] if isinstance(a, dict)]
    leaks = sorted(forbidden_keys(doc, set()))
    unmasked = unmasked_strings(doc)
    generated = parse_date(snapshot.get("generatedAt"))
    age = int((now - generated).total_seconds()) if generated else None
    out(f"snapshot accounts={len(accounts)} generated_age_s={age} "
        f"forbidden_keys={leaks or 'none'} unmasked_strings={unmasked}")

    slots, usable = {}, {}
    for account in accounts:
        provider = str(account.get("provider"))
        slots[provider] = slots.get(provider, 0) + 1
        windows = fresh_windows(account, now)
        if windows:
            usable.setdefault(provider, set()).add(str(account.get("id")))
        all_windows = [w for w in account.get("windows") or [] if isinstance(w, dict)]
        out(f"{provider}#{slots[provider]} state={account.get('state')} "
            f"problem={account.get('problem') or '-'} auth={account.get('authentication') or '-'} "
            f"plan={'yes' if account.get('plan') else 'no'} windows={len(all_windows)} "
            f"fresh={len(windows)} [{';'.join(shape(w) for w in all_windows)}]")

    failures = 0
    if not accounts:
        failures += 1
        out("snapshot: EMPTY")
    if age is None or not 0 <= age <= MAX_AGE_SECONDS:
        failures += 1
        out("snapshot: STALE")
    for provider, count in parse_expect(expect).items():
        got = len(usable.get(provider, ()))
        verdict = "PASS" if got >= count else "OPEN"
        failures += verdict != "PASS"
        out(f"expect {provider}: {got}/{count} distinct rows with fresh windows -> {verdict}")
    if leaks or unmasked:
        failures += 1
        out("privacy: FAIL")
    else:
        out("privacy: PASS")
    return 1 if failures else 0


def self_test():
    now = datetime(2026, 11, 7, tzinfo=timezone.utc)
    def row(**extra):
        base = {"id": "codex:a", "provider": "codex", "label": "al••••••026@example.com", "state": "ok",
                "readAt": "2026-11-06T23:59:00Z", "authentication": "subscription",
                "windows": [{"kind": "weekly", "usedPercent": 31, "durationMinutes": 10080,
                             "resetsAt": "2026-11-10T00:00:00Z"}]}
        base.update(extra)
        return base
    def run(accounts, expect="codex=1", ok=True):
        doc = {"ok": ok, "result": {"generatedAt": "2026-11-06T23:59:30Z", "accounts": accounts}}
        lines = []
        return summarize(doc, expect, now, lines.append), lines
    assert run([row()])[0] == 0, "masked label must pass"
    assert run([row(label="alex@example.com")])[0] == 1, "raw email must fail"
    assert run([row(problem="alex@example.com")])[0] == 1, "email in any field must fail"
    assert run([row(label="김철수@example.com")])[0] == 1, "non-Latin local part must fail"
    assert run([row(label="ḁlex@example.com")])[0] == 1, "Latin Extended Additional must fail"
    assert run([row(label="•••@example.com")])[0] == 0, "fully masked short local part passes"
    assert run([row(label="Team•alex@example.com")])[0] == 1, "a stray bullet is not a mask"
    assert run([row(label="Work (al••••••026@example.com)")])[0] == 0, "masked address in text passes"
    assert run([row(state="failed")])[0] == 1, "failed/retained rows are never fresh"
    assert run([row(readAt="2026-11-06T00:00:00Z")])[0] == 1, "stale read is never fresh"
    assert run([row(windows=[{"kind": "weekly", "usedPercent": True}])])[0] == 1, "bool is not a percent"
    assert run([row(windows=[{"kind": "weekly", "usedPercent": None}])])[0] == 1, "null percent is not fresh"
    assert run([row(), row()], expect="codex=2")[0] == 1, "duplicate rows count once"
    assert run([row(identityKey="x")])[0] == 1, "identityKey must fail"
    assert run([])[0] == 1, "empty snapshot must fail"
    assert summarize({"ok": False, "error": {"code": "no_usage"}}, "", now, lambda _: None) == 2
    assert summarize({"generatedAt": "x", "accounts": []}, "", now, lambda _: None) == 2, "bare snapshot is not the CLI envelope"
    naive = parse_date("2026-11-06T23:59:00")
    assert naive is not None and naive.tzinfo is not None
    print("self-test: PASS")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--expect", default="")
    parser.add_argument("--now", help="ISO-8601 instant used instead of the current time")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    now = parse_date(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        parser.error("--now must be ISO-8601")
    try:
        doc = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("snapshot: unreadable")
        return 2
    return summarize(doc, args.expect, now, print)


if __name__ == "__main__":
    sys.exit(main())
