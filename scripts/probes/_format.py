#!/usr/bin/env python3
"""Turn ansible one-line output into 'host: last line of stdout' rows.

Reads ansible -o output on stdin. Noise before the probe's own line (for example sudo
warnings) is ignored by taking the last non-empty stdout line. Hosts that failed or were
unreachable print their status and message instead. Exit code 1 if any host failed.
"""
import json
import re
import sys

rows, bad = [], 0
for line in sys.stdin:
    m = re.match(r"^(\S+) \| (\w+)!? => (\{.*\})\s*$", line.strip())
    if not m:
        m2 = re.match(r"^(\S+) \| (\w+)", line.strip())
        if m2:
            rows.append((m2.group(1), line.strip()[len(m2.group(1)) + 3:]))
            bad += 1
        elif line.strip() and "DEPRECAT" not in line and "Deprecation warnings" not in line:
            print(line.rstrip(), file=sys.stderr)
        continue
    host, status, body = m.groups()
    try:
        data = json.loads(body)
    except ValueError:
        rows.append((host, line.strip()))
        bad += 1
        continue
    if status in ("FAILED", "UNREACHABLE") or data.get("failed"):
        bad += 1
        rows.append((host, f"{status}: {data.get('msg') or data.get('stderr') or ''}".strip()))
        continue
    out = [l for l in (data.get("stdout") or "").splitlines() if l.strip()]
    rows.append((host, out[-1] if out else "(no output)"))

width = max((len(h) for h, _ in rows), default=0)
for host, text in sorted(rows):
    print(f"{host:<{width}}  {text}")
sys.exit(1 if bad else 0)
