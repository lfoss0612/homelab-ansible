#!/bin/sh
# One line per host: OS, kernel, reboot-required, pending updates, Node, OpenClaw, Zabbix agent.
# Read-only. Run through: scripts/ansible-on-cockpit.sh probe versions [pattern]
os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" )
kernel=$(uname -r)
reboot=no
[ -e /var/run/reboot-required ] && reboot=YES
pending=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
node=$(command -v node >/dev/null 2>&1 && node --version || echo none)
oc=$(command -v openclaw >/dev/null 2>&1 && openclaw --version 2>/dev/null | head -n1 || echo none)
zbx=$(command -v zabbix_agent2 >/dev/null 2>&1 && zabbix_agent2 --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo none)
echo "os=[$os] kernel=$kernel reboot=$reboot pending=$pending node=$node openclaw=[$oc] zabbix_agent2=$zbx"
