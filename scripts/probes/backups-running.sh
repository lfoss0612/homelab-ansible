#!/bin/sh
# Prints "none" when no backup work is running on this host, otherwise what is. Read-only.
#   PBS host:      running backup, verify, prune and garbage-collection tasks (`proxmox-backup-manager task list`
#                  lists only running tasks)
#   Proxmox host:  running vzdump jobs (`pvesh ... --source active --typefilter vzdump`)
# Other hosts always print "none". Run it on pbs and the proxmox_hosts before patching or rebooting anything
# that a backup might be reading: `scripts/ansible-on-cockpit.sh probe backups-running`.
out=""
if command -v proxmox-backup-manager >/dev/null 2>&1; then
  tasks=$(proxmox-backup-manager task list 2>/dev/null | grep -v '^$' | grep -ci 'running\|backup\|verif\|prune\|garbage')
  [ "${tasks:-0}" -gt 0 ] && out="pbs-tasks=$(proxmox-backup-manager task list 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
fi
if command -v pvesh >/dev/null 2>&1; then
  node=$(hostname)
  v=$(pvesh get "/nodes/$node/tasks" --source active --typefilter vzdump --output-format json 2>/dev/null | tr -d '\n ')
  case "$v" in ''|'[]') ;; *) out="$out vzdump-running=$v" ;; esac
fi
echo "${out:-none}"
