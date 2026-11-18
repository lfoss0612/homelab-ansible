#!/usr/bin/env python3
"""Collect version and update facts from one host and print them as a single JSON line.

Read-only and standard library only, so it runs on any managed host with python3. It is
shipped and run by playbooks/fleet-versions.yml through the script module; run it by hand
with `python3 scripts/fleet-versions-collect.py` to see what a host reports.
"""
import glob
import json
import os
import re
import shutil
import subprocess


def run(cmd, timeout=60):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.returncode, (out.stdout or "").strip(), (out.stderr or "").strip()
    except Exception as exc:  # missing binary, timeout
        return 127, "", str(exc)


def first_line(text):
    return text.splitlines()[0].strip() if text else ""


def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return ""


def os_release():
    info = {}
    for line in read("/etc/os-release").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v.strip().strip('"')
    return info


def version_key(v):
    return [int(p) if p.isdigit() else p for p in re.split(r"[.\-+~]", v)]


def kernels():
    running = os.uname().release
    installed = []
    for path in glob.glob("/boot/vmlinuz-*"):
        installed.append(os.path.basename(path)[len("vmlinuz-"):])
    newest = None
    if installed:
        try:
            newest = sorted(installed, key=version_key)[-1]
        except TypeError:
            newest = sorted(installed)[-1]
    return running, newest


def pending_updates():
    """Packages apt would install now. Phased updates are excluded (they are held back)."""
    rc, out, _ = run(["apt-get", "-s", "-o", "APT::Get::Always-Include-Phased-Updates=false", "upgrade"], 120)
    if rc != 0:
        return None, []
    names = [line.split()[1] for line in out.splitlines() if line.startswith("Inst ")]
    return len(names), names[:5]


def repo_files():
    # apt only reads *.sources and *.list; skip the timestamped backups Ansible leaves behind.
    files = glob.glob("/etc/apt/sources.list.d/*.sources") + glob.glob("/etc/apt/sources.list.d/*.list")
    files.append("/etc/apt/sources.list")
    return {f: read(f) for f in files if os.path.isfile(f)}


def zabbix_repo(repos):
    """Return (release, enabled): the first enabled Zabbix repo, else a disabled one."""
    found = None
    for path, text in sorted(repos.items()):
        m = re.search(r"repo\.zabbix\.com/zabbix/(\d+\.\d+)", text)
        if not m or text.lstrip().startswith("#"):
            continue
        enabled = not re.search(r"^Enabled:\s*no", text, re.M | re.I)
        if enabled:
            return m.group(1), True
        found = found or (m.group(1), False)
    return found if found else (None, None)


def nodesource(repos):
    for path, text in repos.items():
        if "nodesource" in path.lower() or "nodesource.com" in text:
            m = re.search(r"node_(\d+)\.x", text)
            enabled = not re.search(r"^Enabled:\s*no", text, re.M | re.I)
            suite = re.search(r"^Suites:\s*(\S+)", text, re.M)
            return {
                "major": m.group(1) if m else None,
                "enabled": enabled,
                "suite": suite.group(1) if suite else None,
            }
    return None


def version_of(cmd):
    if not shutil.which(cmd[0]):
        return None
    rc, out, err = run(cmd)
    return first_line(out or err) or None


def failed_units():
    rc, out, _ = run(["systemctl", "--failed", "--no-legend", "--plain"])
    return sorted({l.split()[0] for l in out.splitlines() if l.strip()}) if rc == 0 else []


def main():
    osr = os_release()
    running, newest = kernels()
    pending, sample = pending_updates()
    repos = repo_files()
    zrepo, zenabled = zabbix_repo(repos)
    openclaw = version_of(["openclaw", "--version"])
    m = re.search(r"\d{4}\.\d+\.\d+(?:-\d+)?", openclaw or "")
    node = version_of(["node", "--version"])
    agent = version_of(["zabbix_agent2", "--version"])
    ma = re.search(r"\d+\.\d+\.\d+", agent or "")
    server = version_of(["zabbix_server", "--version"])
    ms = re.search(r"\d+\.\d+\.\d+", server or "")
    uptime = None
    try:
        uptime = round(float(read("/proc/uptime").split()[0]) / 86400, 1)
    except (ValueError, IndexError):
        pass
    rc, _, _ = run(["id", "claude"])
    data = {
        "os": osr.get("PRETTY_NAME"),
        "os_id": osr.get("ID"),
        "os_version": osr.get("VERSION_ID"),
        "os_codename": osr.get("VERSION_CODENAME"),
        "kernel_running": running,
        "kernel_newest_installed": newest,
        "reboot_required": os.path.exists("/var/run/reboot-required"),
        "pending_updates": pending,
        "pending_sample": sample,
        "uptime_days": uptime,
        "openclaw": m.group(0) if m else None,
        "node": node.lstrip("v") if node else None,
        "nodesource": nodesource(repos),
        "zabbix_agent2": ma.group(0) if ma else None,
        "zabbix_repo": zrepo,
        "zabbix_repo_enabled": zenabled,
        "zabbix_server": ms.group(0) if ms else None,
        "claude_user": rc == 0,
        "failed_units": failed_units(),
    }
    print(json.dumps(data, sort_keys=True))


if __name__ == "__main__":
    main()
