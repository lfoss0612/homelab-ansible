#!/usr/bin/env python3
"""Turn the raw output of playbooks/fleet-versions.yml into a markdown report.

Input: a JSON file {"pins": {...}, "hosts": {name: {...collector output...} | {"error": "..."}}}.
Output: markdown on stdout (a table per host, then an "Attention" list of things that need a
decision). Standard library only. Exit code 0 always; the report is information, not a gate.

    scripts/fleet-versions-report.py raw.json > report.md
"""
import json
import re
import sys


def vkey(v):
    return [int(p) if p.isdigit() else p for p in re.split(r"[.\-+~]", v or "0")]


def short_kernel(k):
    return k if not k else k.split("-")[0] + ("-pve" if "pve" in k else "")


def main(path):
    data = json.load(open(path))
    pins = data.get("pins", {})
    hosts = data.get("hosts", {})
    latest_os = pins.get("latest_os", {})
    ignore = [re.compile(p) for p in pins.get("ignore_units", [])]
    oc_pin = pins.get("openclaw_version")
    node_major = str(pins.get("node_major", ""))
    node_min = pins.get("node_min_version")
    oc_latest = pins.get("openclaw_latest_npm")

    server = next((h["zabbix_server"] for h in hosts.values() if h.get("zabbix_server")), None)
    attention = []

    def flag(host, text):
        attention.append((host, text))

    rows = []
    for name in sorted(hosts):
        h = hosts[name]
        if "error" in h:
            rows.append((name, "UNREACHABLE", "", "", "", "", "", "", h["error"][:60]))
            flag(name, "unreachable: " + h["error"][:120])
            continue
        failed = [u for u in h.get("failed_units", []) if not any(p.search(u) for p in ignore)]
        ns = h.get("nodesource") or {}
        zab = h.get("zabbix_agent2") or "-"
        if h.get("zabbix_repo"):
            zab += " (repo " + h["zabbix_repo"] + ")"
        rows.append((
            name,
            h.get("os") or "?",
            h.get("kernel_running") or "?",
            "YES" if h.get("reboot_required") else "no",
            str(h["pending_updates"]) if h.get("pending_updates") is not None else "?",
            h.get("node") or "-",
            h.get("openclaw") or "-",
            zab,
            ", ".join(failed) if failed else "-",
        ))
        # --- attention rules
        osid, osv = h.get("os_id"), h.get("os_version")
        if osid in latest_os and osv and vkey(osv) < vkey(latest_os[osid]):
            flag(name, f"OS {osid} {osv} is behind the latest {latest_os[osid]}")
        if h.get("reboot_required"):
            flag(name, "reboot required")
        if h.get("kernel_newest_installed") and h["kernel_newest_installed"] != h.get("kernel_running"):
            flag(name, f"running kernel {h.get('kernel_running')} but {h['kernel_newest_installed']} is installed (reboot)")
        if h.get("pending_updates"):
            flag(name, f"{h['pending_updates']} package(s) pending, e.g. {', '.join(h.get('pending_sample', [])[:3])}")
        if h.get("pending_updates") is None:
            flag(name, "could not count pending updates (apt problem?)")
        if h.get("openclaw") and oc_pin and h["openclaw"] != oc_pin:
            flag(name, f"OpenClaw {h['openclaw']} differs from the pin {oc_pin}")
        if h.get("node") and node_min and vkey(h["node"]) < vkey(node_min):
            flag(name, f"Node {h['node']} is below the floor {node_min}")
        if h.get("node") and node_major and h["node"].split(".")[0] != node_major:
            flag(name, f"Node major {h['node'].split('.')[0]} differs from the pinned major {node_major}")
        if h.get("openclaw") and not ns:
            flag(name, "no NodeSource repo configured")
        elif ns and ns.get("enabled") is False:
            flag(name, "NodeSource repo is disabled")
        elif ns and node_major and ns.get("major") and ns["major"] != node_major:
            flag(name, f"NodeSource repo is at node_{ns['major']}.x, pin is {node_major}")
        if h.get("zabbix_agent2") and server:
            if ".".join(h["zabbix_agent2"].split(".")[:2]) != ".".join(server.split(".")[:2]):
                flag(name, f"zabbix agent {h['zabbix_agent2']} vs server {server}")
        if h.get("zabbix_agent2") and h.get("zabbix_repo_enabled") is False:
            flag(name, "Zabbix apt repo is disabled")
        if h.get("claude_expected") and not h.get("claude_user"):
            flag(name, "claude user missing")
        if failed:
            flag(name, "failed units: " + ", ".join(failed))

    out = []
    out.append("# Fleet versions")
    out.append("")
    out.append(f"Pins: OpenClaw {oc_pin}, Node major {node_major} (floor {node_min}). "
               f"Latest OpenClaw on npm: {oc_latest or 'unknown'}. Zabbix server: {server or 'unknown'}.")
    if oc_latest and oc_pin and vkey(oc_latest) > vkey(oc_pin):
        out.append(f"A newer OpenClaw exists ({oc_latest}); see the OpenClaw plan before bumping the pin.")
    out.append("")
    head = ["Host", "OS", "Kernel", "Reboot", "Pending", "Node", "OpenClaw", "Zabbix agent", "Failed units"]
    out.append("| " + " | ".join(head) + " |")
    out.append("|" + "---|" * len(head))
    for r in rows:
        out.append("| " + " | ".join(c.replace("|", "/") for c in r) + " |")
    out.append("")
    out.append("## Attention")
    out.append("")
    if not attention:
        out.append("Nothing needs attention.")
    else:
        for host, text in attention:
            out.append(f"- **{host}**: {text}")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
