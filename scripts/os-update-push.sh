#!/bin/sh
#
# Push the pending-package count to Zabbix as a trapper value (os.update.pending.count).
#
# For the 3 k8s nodes only: their Zabbix agent is a DaemonSet pod with no apt/dpkg and no way
# into the host's package state (see playbooks/os-update-status-monitor.yml), so the passive
# UserParameter used on the other 11 hosts cannot run there. This runs on the host itself, from a
# systemd timer, and pushes the same number with zabbix_sender. The count is the same as
# `os-update-status.sh pending`: packages a dist-upgrade would install.
#
# Environment (set by the systemd unit, see playbooks/os-update-status-push.yml):
#   ZABBIX_SERVER  where to send: the Zabbix server, or for a proxy-monitored host (k8s-master) the
#                  proxy, because the server refuses trapper data for a host a proxy monitors
#   ZABBIX_PORT    trapper port, 10051
#   ZABBIX_HOST    the Zabbix host name this value belongs to
#
# Not `set -e`, like the other monitors: an apt hiccup must still end in a clear log line, not a
# silent exit. A failed count is never sent as 0 (that would read as "fully patched").

ZABBIX_SERVER="${ZABBIX_SERVER:?ZABBIX_SERVER not set}"
ZABBIX_PORT="${ZABBIX_PORT:-10051}"
ZABBIX_HOST="${ZABBIX_HOST:?ZABBIX_HOST not set}"

log() { echo "os-update-push: $*"; }

command -v zabbix_sender >/dev/null 2>&1 || { log "zabbix_sender not installed"; exit 1; }

out=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  log "apt-get simulation failed (rc=$rc), nothing sent: $(echo "$out" | tail -1)"
  exit 1
fi
count=$(echo "$out" | grep -c '^Inst ')

log "pending packages on $ZABBIX_HOST: $count (sending to $ZABBIX_SERVER:$ZABBIX_PORT)"
res=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$ZABBIX_HOST" -k os.update.pending.count -o "$count" 2>&1)
log "zabbix_sender: $(echo "$res" | grep -E 'processed|failed|Sending' | tr '\n' ' ')"
case "$res" in
  *"processed: 1;"*) exit 0 ;;
  *)
    # Exit 0 on purpose: a refusal is usually temporary (a proxy applies a new item only at its next
    # config sync, up to an hour) and must not leave a failed unit that post-release-upgrade-check
    # reports as a problem. The warning is in the journal, and the dashboard shows "No data" if it persists.
    # Local failures (no zabbix_sender, apt simulation failing) still exit 1.
    log "WARNING: Zabbix did not accept the value. Check that the trapper item exists on host '$ZABBIX_HOST'"
    log "         (playbooks/os-update-status-zabbix-setup.yml) and, for a proxy-monitored host, that ZABBIX_SERVER is the proxy."
    exit 0
    ;;
esac
