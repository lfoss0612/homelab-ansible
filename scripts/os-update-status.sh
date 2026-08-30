#!/bin/sh
#
# Report OS patch status for Zabbix UserParameter items:
#   os-update-status pending             -> count of packages a dist-upgrade would install
#   os-update-status reboot [hostfs-prefix] -> 0 = no reboot needed, 1 = needed, 2 = n/a (container)
#
# POSIX /bin/sh on purpose, not bash: this same file has to run two ways --
# natively via a normal Zabbix agent2 UserParameter on 11 hosts, and invoked as
# `sh /hostfs/root/usr/local/bin/os-update-status reboot /hostfs/root` from
# inside the cattle-monitoring-system zabbix-agent DaemonSet pod on the 3 k8s
# nodes, whose image (zabbix/zabbix-agent2:alpine-7.4.1) only has busybox sh.
#
# The optional hostfs-prefix argument is what makes the second mode possible.
# Verified live 2026-08-30: that pod runs as uid 1997 (zabbix), non-root, no
# added capabilities, and has neither apt/dpkg (Alpine base) nor a way to enter
# the host's real mount namespace -- both `chroot /hostfs/root` and
# `nsenter --target 1 ...` fail there with "Operation not permitted" /
# "Permission denied" despite hostPID: true and a read-only /hostfs/root bind
# mount of the whole node filesystem. So `pending` (which needs apt-get/dpkg)
# cannot work in that pod at all without a security-posture change to the
# DaemonSet -- not something this script or the playbook deploying it decides
# unilaterally. `reboot` DOES work there with zero extra privilege: uname -r
# inside any container always reports the REAL host kernel (there is only one
# kernel, shared unconditionally, regardless of PID/mount namespace), and the
# newest installed kernel is a plain file read through the existing read-only
# hostfs mount -- no chroot/nsenter needed at all.
#
# Deliberately NOT `set -e`, same reasoning as scripts/smart-monitor.sh and
# scripts/oom-kill-monitor.sh: a monitor must never exit early on the very
# condition it exists to report. `grep -c` in particular exits non-zero on a
# zero-match count even though the "0" it printed is a perfectly good, correct
# answer -- `set -e` would silently turn that into a missing/unsupported item
# instead of a healthy "0 pending" result.

action="${1:-}"
prefix="${2:-}"

case "$action" in
  pending)
    apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst '
    ;;
  reboot)
    running=$(uname -r)
    newest=$(ls -1 "${prefix}/boot/vmlinuz-"* 2>/dev/null | sed "s|.*/vmlinuz-||" | sort -V | tail -1)
    result=0

    if [ -z "$prefix" ]; then
      # Native mode only: an LXC container's uname -r reports the HOST's
      # kernel (same reasoning as above, one shared kernel), which can never
      # match "the newest kernel this guest could boot" -- it isn't the one
      # booting anything. Reported distinctly (2) rather than folded into
      # "no reboot needed" (0), which would be a real answer to a different
      # question. Same false-positive playbooks/os-update.yml already fixed
      # once for pdm.home.lan.
      virt=$(systemd-detect-virt 2>/dev/null)
      [ -z "$virt" ] && virt=none
      case "$virt" in
        lxc | container-other | systemd-nspawn | docker)
          echo 2
          exit 0
          ;;
      esac

      if [ -f /var/run/reboot-required ]; then
        result=1
      fi
    fi

    if [ -n "$newest" ] && [ "$newest" != "$running" ]; then
      result=1
    fi

    echo "$result"
    ;;
  *)
    echo "usage: $0 {pending|reboot} [hostfs-prefix]" >&2
    exit 1
    ;;
esac
exit 0
