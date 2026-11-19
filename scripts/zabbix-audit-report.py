#!/usr/bin/env python3
"""Turn the raw output of playbooks/zabbix-audit.yml into a PASS/WARN/FAIL report.

Input: JSON written by the playbook. Output: markdown on stdout. Standard library only.
Exit code is always 0; findings are information. Run by hand against a saved file with
    scripts/zabbix-audit-report.py /var/tmp/zabbix-audit/latest.json
"""
import json
import re
import sys

OS_KEYS = ("os.update.pending.count", "os.update.reboot.required")
OPENCLAW_KEY = "openclaw.version"


def seconds(v):
    """Zabbix time string (30s, 5m, 1h, 1d, 1w or plain seconds) to seconds; 0 if unknown."""
    m = re.fullmatch(r"(\d+)([smhdw]?)", (v or "").strip())
    if not m:
        return 0
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[m.group(2)]


def allowed_age(it, base):
    """How old lastclock may be: the base window, or 1.5x the poll interval or heartbeat if longer.

    An item with "discard unchanged with heartbeat" (preprocessing type 20) only updates
    lastclock when the value changes or the heartbeat elapses, so a daily heartbeat is normal.
    """
    window = seconds(it.get("delay"))
    for p in it.get("preprocessing", []) or []:
        if str(p.get("type")) == "20":
            window = max(window, seconds(p.get("params")))
    return max(base, int(window * 1.5))


def mm(v):
    m = re.match(r"(\d+)\.(\d+)", v or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def main(path):
    d = json.load(open(path))
    now = d["now"]
    stale = d["stale_hours"] * 3600
    findings = []  # (level, subject, text)

    def add(level, subject, text):
        findings.append((level, subject, text))

    hosts = {h["host"]: h for h in d["hosts"]}
    by_id = {h["hostid"]: h["host"] for h in d["hosts"]}
    items = {}
    for it in d["items"]:
        items.setdefault(by_id.get(it["hostid"]), {})[it["key_"]] = it
    server = d.get("server_version", "")
    no_os = set(d.get("no_os_update_items", []))

    for name, inv in sorted(d["inventory"].items()):
        h = hosts.get(name)
        if not h:
            if name not in d.get("optional_hosts", []):
                add("FAIL", name, "not found in Zabbix")
            continue
        if h["status"] != "0":
            add("WARN", name, "host is disabled in Zabbix")
        agent_ifaces = [i for i in h.get("interfaces", []) if i["type"] == "1" and i["main"] == "1"]
        if agent_ifaces and inv["ip"]:
            i = agent_ifaces[0]
            ip = i["ip"] if i["useip"] == "1" else i["dns"]
            if i["useip"] == "1" and ip != inv["ip"] and not (ip == "127.0.0.1" and name in d.get("loopback_ok", [])):
                add("FAIL", name, f"Zabbix agent interface is {ip} but inventory.ini says {inv['ip']}")
            if i.get("available") == "2":
                add("FAIL", name, f"agent interface unavailable: {i.get('error', '')[:100]}")
        if inv["api_managed"]:
            continue
        hi = items.get(name, {})
        want = [OPENCLAW_KEY, "agent.version"] + ([] if name in no_os else list(OS_KEYS))
        for key in want:
            it = hi.get(key)
            if not it:
                add("FAIL", name, f"item {key} is missing")
                continue
            if it["status"] != "0":
                add("WARN", name, f"item {key} is disabled")
                continue
            if it["state"] == "1":
                add("FAIL", name, f"item {key} is not supported: {it.get('error', '')[:100]}")
                continue
            last = int(it["lastclock"] or 0)
            if last == 0:
                add("WARN", name, f"item {key} has never reported")
            elif now - last > allowed_age(it, stale):
                add("WARN", name, f"item {key} last reported {(now - last) // 3600} h ago (poll {it.get('delay')})")
        av = hi.get("agent.version", {}).get("lastvalue")
        if av and mm(av) and mm(server) and mm(av) != mm(server):
            add("WARN", name, f"agent {av} differs from server {server} (major.minor)")

    # Server caches and the trigger that should watch them. Every host that carries the
    # zabbix[...] internal items is reported under its own name.
    cache_by_host = {}
    for it in d.get("cache_items", []):
        if it["hostid"] in by_id:  # ids that are not hosts are templates carrying the same items
            cache_by_host.setdefault(by_id[it["hostid"]], []).append(it)
    if not cache_by_host:
        add("WARN", "Zabbix", "no internal cache items found (is the Zabbix server health template linked?)")
    for host, citems in sorted(cache_by_host.items()):
        hostid = citems[0]["hostid"]
        for it in sorted(citems, key=lambda i: i["key_"]):
            key = it["key_"]
            if it["state"] == "1":
                add("FAIL", host, f"{key} is not supported: {it.get('error', '')[:100]}")
                continue
            try:
                pct = float(it["lastvalue"])
            except (TypeError, ValueError):
                add("WARN", host, f"{key} has no value")
                continue
            level = "FAIL" if pct >= 95 else "WARN" if pct >= d["cache_warn_pct"] else "PASS"
            add(level, host, f"{key} at {pct:.1f}%")
        watched = [t for t in d.get("triggers", [])
                   if "rcache" in t["expression"] and t["status"] == "0"
                   and any(h["hostid"] == hostid for h in t.get("hosts", []))]
        if watched:
            add("PASS", host, "an enabled trigger watches the config cache: " + "; ".join(sorted({t["description"] for t in watched})))
        else:
            add("FAIL", host, "no enabled trigger watches zabbix[rcache,buffer,pused]; an exhausted CacheSize would go unnoticed")

    counts = {k: sum(1 for f in findings if f[0] == k) for k in ("FAIL", "WARN", "PASS")}
    out = ["# Zabbix audit", "",
           f"Server {server}. {len(d['inventory'])} inventory hosts. "
           f"{counts['FAIL']} FAIL, {counts['WARN']} WARN, {counts['PASS']} PASS.", ""]
    problems = [f for f in findings if f[0] != "PASS"]
    out.append("## Findings")
    out.append("")
    if not problems:
        out.append("Nothing to fix.")
    for level, subject, text in sorted(problems, key=lambda f: (f[0] != "FAIL", f[1])):
        out.append(f"- **{level}** {subject}: {text}")
    ok = [f for f in findings if f[0] == "PASS"]
    if ok:
        out += ["", "## Passed", ""] + [f"- {s}: {t}" for _, s, t in ok]
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
