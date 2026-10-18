#!/usr/bin/env python3
"""Checks every Strings+<lang>.swift table against L10nKey and the English placeholders.
Usage: scripts/check-l10n.py [lang ...]   (default: all)"""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "Sources/SwitcherCore/Localization"
keys = re.findall(r'case (\w+) = "', (root / "L10nKey.swift").read_text())
ph = re.compile(r'%(?:\d+\$)?[@d]')

def table(name):
    text = (root / f"Strings+{name}.swift").read_text()
    entries = {}
    # multi-line string literals first, then single-line
    for m in re.finditer(r'\.(\w+):\s*"""\n(.*?)\n\s*"""', text, re.S):
        entries[m.group(1)] = m.group(2)
    for m in re.finditer(r'^\s*\.(\w+):\s*"((?:[^"\\]|\\.)*)",?\s*$', text, re.M):
        entries.setdefault(m.group(1), m.group(2))
    return entries

def norm(placeholders):
    # positional and plain forms are equivalent as long as the multiset of types matches in order of position
    out = []
    for i, p in enumerate(placeholders, 1):
        m = re.match(r'%(?:(\d+)\$)?([@d])', p)
        out.append((int(m.group(1)) if m.group(1) else i, m.group(2)))
    return sorted(out)

en = table("en")
langs = sys.argv[1:] or ["ko", "zh-Hans", "ja", "en", "es"]
ok = True
for lang in langs:
    t = table(lang)
    missing = [k for k in keys if k not in t]
    extra = [k for k in t if k not in keys]
    bad = [k for k in keys if k in t and k in en and norm(ph.findall(t[k])) != norm(ph.findall(en[k]))]
    print(f"{lang}: {len(t)}/{len(keys)} keys, missing={len(missing)}, extra={len(extra)}, placeholder-mismatch={len(bad)}")
    for k in missing[:20]: print("   missing:", k)
    for k in extra[:20]: print("   extra:", k)
    for k in bad[:20]: print("   placeholders differ:", k, ph.findall(t[k]), "vs en", ph.findall(en[k]))
    ok &= not (missing or extra or bad)
sys.exit(0 if ok else 1)
